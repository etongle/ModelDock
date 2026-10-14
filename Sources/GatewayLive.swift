import Foundation

enum GatewayLive {
    @MainActor static func run() async throws {
        let fm = FileManager.default
        let report = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-gateway-live").resolvingSymlinksInPath()
        try ConnectionFiles.privateDirectory(report)
        let state = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModelManager")
        let store = AppStore(stateDirectory: state)
        let before = store.services.records
        store.scan()
        for _ in 0..<160 {
            if store.inventory != nil && !store.scanning { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard store.inventory != nil else { throw LaunchError.message("模型扫描未完成") }
        await store.services.refresh()
        store.synchronizeGateway()
        await store.gateway.poll()
        if !store.gateway.ready { store.gateway.start(store: store) }
        for _ in 0..<100 {
            if store.gateway.ready && !store.gateway.busy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard store.gateway.ready else { throw LaunchError.message(store.gateway.error ?? "网关未能就绪") }
        let port = Int(argumentValue("--live-connection-port") ?? "8000") ?? 8000
        guard let source = store.directConnectionTargets.first(where: { $0.port == port }),
              let target = store.gatewayConnectionTargets.first(where: { $0.sourceID == source.sourceID && $0.model.hasSuffix("/" + source.model) }),
              let context = target.context else { throw LaunchError.message("未找到实际模型的网关路由或上下文") }
        let installations: [ClientInstallation] = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: ClientInstallation.discover()) }
        }
        let project = report.appendingPathComponent("project")
        try ConnectionFiles.privateDirectory(project)
        var exports: [ClientConnection] = []
        for client in [CodingClient.opencode, .pi] {
            guard client.contextRequirement(context) == nil,
                  let installation = installations.first(where: { $0.id == client }), let executable = installation.executable else { continue }
            let connection = try ConnectionFiles.prepare(client: client, target: target, context: context,
                executable: executable, project: project.path, root: report.appendingPathComponent("profiles"), clientVersion: installation.version)
            try await ConnectionFiles.validateLaunch(URL(fileURLWithPath: connection.script + ".json"))
            exports.append(connection)
        }
        try ConnectionChecks.require(exports.count == 2, "真实网关的 OpenCode、pi 配置未能生成")
        for original in before where original.pid != nil {
            try ConnectionChecks.require(original.pid.map { processStartTime($0) == original.processStart } == true,
                "真实模型进程发生变化")
        }
        try ConnectionChecks.require(Set(before.map(\.id)) == Set(store.services.records.map(\.id)), "模型服务配置发生变化")
        try ConnectionFiles.write(try JSONEncoder().encode(exports), to: report.appendingPathComponent("live-exports.json"))
        let result: [String: Any] = ["result": "ready", "endpoint": store.gateway.endpoint,
            "alias": target.model, "sourceModel": source.model, "sourcePort": port, "context": context,
            "gatewayPID": store.gateway.process?.pid ?? 0, "gatewayBirth": store.gateway.process?.birth ?? 0,
            "servicesPreserved": true, "leftRunning": true, "clients": exports.map { $0.client.rawValue }]
        let data = try ConnectionFiles.json(result)
        try data.write(to: report.appendingPathComponent("ready.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
