import Foundation

enum ConnectionLive {
    @MainActor static func run(repairPort: Int?) async throws {
        let fm = FileManager.default
        let report = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-context-check")
        try ConnectionFiles.privateDirectory(report)
        let state = repairPort == nil ? report.appendingPathComponent("test-state") :
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModelManager")
        let store = AppStore(stateDirectory: state)
        store.scan()
        for _ in 0..<160 {
            if store.inventory != nil && !store.scanning { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard store.inventory != nil else { throw LaunchError.message("模型扫描未完成") }
        await store.services.refresh()
        var temporary: ServiceSpec?
        var result: [String: Any] = [:]
        do {
            let spec: ServiceSpec
            if let port = repairPort {
                guard let original = store.services.records.first(where: { $0.port == port && $0.pid != nil }) else { throw LaunchError.message("未找到待修复服务") }
                let others = store.services.records.filter { $0.port != port && $0.pid != nil }
                spec = try await store.connections.expandContext(store: store, port: port, context: 32768)
                for other in others {
                    guard let pid = other.pid, let birth = other.processStart, processStartTime(pid) == birth,
                          (await NetworkProbe.models(port: other.port)).ready else { throw LaunchError.message("其他服务状态发生改变") }
                }
                result = ["port": port, "previousContext": original.context, "context": spec.context,
                    "previousPID": original.pid ?? 0, "pid": spec.pid ?? 0, "otherServicesPreserved": true]
            } else {
                guard let engine = store.engines.first(where: { $0.kind == .splash }),
                      let model = store.models.first(where: { $0.kind == .language && $0.compatible(with: engine) }),
                      let port = (19060...19080).first(where: { !NetworkProbe.portOccupied($0) }) else { throw LaunchError.message("测试引擎、模型或空闲端口不可用") }
                temporary = try store.services.start(engine: engine, model: model, port: port, context: 32768)
                for _ in 0..<120 {
                    await store.services.refresh()
                    if store.services.status(temporary!) == .running { break }
                    if store.services.status(temporary!) == .failed { throw LaunchError.message(store.services.log(temporary!.id)) }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard store.services.status(temporary!) == .running, let active = store.services.records.first(where: { $0.id == temporary?.id }) else { throw LaunchError.message("测试服务未能就绪") }
                spec = active
                result = ["port": port, "context": spec.context, "pid": spec.pid ?? 0, "temporary": true]
            }
            guard let target = store.connectionTargets.first(where: { $0.port == spec.port }) else { throw LaunchError.message("未找到真实 API 模型") }
            let installations: [ClientInstallation] = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: ClientInstallation.discover()) }
            }
            let project = repairPort == nil ? report.appendingPathComponent("project").path : store.connections.project
            if repairPort == nil {
                try ConnectionFiles.privateDirectory(URL(fileURLWithPath: project))
                try Data("MODEL_MANAGER_CONTEXT_READ_FIXTURE\n".utf8).write(to: URL(fileURLWithPath: project).appendingPathComponent("fixture.txt"))
            }
            var exports: [ClientConnection] = []
            for client in [CodingClient.opencode, .pi] {
                guard let installation = installations.first(where: { $0.id == client }), let executable = installation.executable else { continue }
                exports.append(try ConnectionFiles.prepare(client: client, target: target, context: spec.context,
                    executable: executable, project: project, root: store.connections.root, clientVersion: installation.version))
            }
            try JSONEncoder().encode(exports).write(to: report.appendingPathComponent("live-exports.json"))
            result["result"] = "ready"; result["model"] = target.model
            try ConnectionFiles.json(result).write(to: report.appendingPathComponent("ready.json"))
            print(String(decoding: try ConnectionFiles.json(result), as: UTF8.self)); fflush(stdout)
            if temporary != nil {
                for _ in 0..<900 {
                    if fm.fileExists(atPath: report.appendingPathComponent("finish").path) { break }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if let temporary { try store.services.stop(temporary) }
                for _ in 0..<40 { await store.services.refresh(); if !NetworkProbe.portOccupied(spec.port) { break }; try await Task.sleep(nanoseconds: 250_000_000) }
                guard !NetworkProbe.portOccupied(spec.port) else { throw LaunchError.message("测试服务未能退出") }
                result["result"] = "passed"; result["temporaryServiceStopped"] = true
            } else { result["result"] = "passed"; result["leftRunning"] = true }
            try ConnectionFiles.json(result).write(to: report.appendingPathComponent("result.json"))
        } catch {
            if let temporary { try? store.services.stop(temporary) }
            try? ConnectionFiles.json(["result": "failed", "error": error.localizedDescription]).write(to: report.appendingPathComponent("result.json"))
            throw error
        }
    }
}
