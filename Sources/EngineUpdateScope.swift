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
    func performInstall(_ plan: EngineInstallPlan) {
        guard !preparingInstall && !installation.running else { return }
        preparingInstall = true
        Task {
            await services.refresh()
            preparingInstall = false
            installation.perform(plan, blockers: installBlockers(plan.engine)) { self.scan() }
        }
    }
}
