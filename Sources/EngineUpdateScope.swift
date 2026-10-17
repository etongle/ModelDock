import Foundation

struct EngineRuntimeProcess: Identifiable, Sendable {
    var id: Int32 { pid }
    var pid: Int32
    var birth: UInt64
    var engineID: String
}

enum EngineUpdateScope {
    static func snapshot() async -> [EngineRuntimeProcess] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let pids = runText("/bin/ps", ["-axo", "pid="]).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                let processes = pids.compactMap { pid -> EngineRuntimeProcess? in
                    let birth = processStartTime(pid)
                    guard birth > 0, let engineID = PortIdentity.engineID(executable: PortIdentity.executable(pid), arguments: PortIdentity.arguments(pid)),
                          processStartTime(pid) == birth else { return nil }
                    return .init(pid: pid, birth: birth, engineID: engineID)
                }
                continuation.resume(returning: processes)
            }
        }
    }
}

@MainActor
extension AppStore {
    func updateProcesses(_ engine: Engine) -> [EngineRuntimeProcess] {
        services.engineProcesses.filter { $0.engineID == engine.id && processStartTime($0.pid) == $0.birth }
    }
    func showEngineServices(_ id: String) {
        gatewaySelected = false
        serviceEngineFilter = id
        selectedServiceID = engineServices(id).first?.id
        selectedExternal = selectedServiceID == nil ? externalEngineServices(id).first?.port : nil
        tab = .services
    }
    func showEngineModels(_ id: String) {
        modelEngineFilter = id; search = ""; modelFilter = "全部"
        selectVisibleFile(); tab = .models
    }
    /// Stops this engine's managed services, installs the update, rescans, then restarts the same services on the new version.
    /// A failed update restarts them on the version that is still installed.
    func performInstall(_ plan: EngineInstallPlan) {
        guard !preparingInstall && !installation.running else { return }
        preparingInstall = true
        Task {
            await services.refresh()
            // Check every other blocker first, so nothing is stopped for an update that cannot run.
            guard plan.blockers.isEmpty && installBlockers(plan.engine).isEmpty else {
                preparingInstall = false; installation.perform(plan, blockers: installBlockers(plan.engine)) {}; return
            }
            let running = restartableServices(plan.engine)
            var stopped: [ServiceSpec] = []
            do {
                for spec in running { try services.stop(spec); stopped.append(spec) }
                for spec in stopped { try await services.waitForRelease(port: spec.port) }
            } catch {
                preparingInstall = false
                installation.message = "无法停止运行中的服务，已取消更新：" + error.localizedDescription
                await restartServices(stopped, log: false); return
            }
            preparingInstall = false
            let started = installation.perform(plan, blockers: installBlockers(plan.engine)) {
                self.scan()
                Task { await self.restartServices(stopped, log: true) }
            }
            if !started { await restartServices(stopped, log: false) }
            else if !stopped.isEmpty { installation.log += "已停止 \(stopped.count) 个运行中的服务，完成后自动重新启动。\n" }
        }
    }

    private func restartServices(_ stopped: [ServiceSpec], log: Bool) async {
        guard !stopped.isEmpty else { return }
        // Wait for the rescan so the restart picks up the updated executable and version.
        while scanning { try? await Task.sleep(nanoseconds: 200_000_000) }
        var failures: [String] = []
        for saved in stopped {
            let spec = services.records.first { $0.id == saved.id } ?? saved
            guard spec.pid == nil else { continue }
            do {
                _ = try startSaved(spec)
                if log { installation.log += "已重新启动 · 端口 \(spec.port) · \(spec.modelName)\n" }
            } catch { failures.append("端口 \(spec.port) · \(spec.modelName)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { message = "以下服务未能自动重新启动，请在模型服务页面处理：\n" + failures.joined(separator: "\n") }
    }
}
