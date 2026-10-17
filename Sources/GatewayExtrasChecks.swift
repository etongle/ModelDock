import Foundation
import Darwin

/// 网关扩展：请求日志与活动记录、空闲停止后经网关唤醒、局域网监听。
enum GatewayExtrasChecks {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-gateway-extras").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        let script = root.appendingPathComponent("llama-server")
        try ConnectionFiles.write(Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Tests/gateway_fixture.py")), to: script, executable: true)
        let weight = root.appendingPathComponent("fixture.gguf"); try Data("GGUF".utf8).write(to: weight)
        let model = LocalModel(id: "extras-fixture", name: "fixture", format: "GGUF", path: weight.path, kind: .language, bytes: 4, complete: true, verification: "fixture", missingFiles: [], removalPath: weight.path)
        let engine = Engine(kind: .llama, name: "Llama", version: "fixture", path: script.path, installed: true, canServe: true, installation: "fixture", description: "fixture", defaultPort: 29940, symbol: "terminal")
        store.inventory = .init(engines: [engine], models: [model], storageBytes: 4, memoryBytes: 0, chip: "fixture", roots: [root.path], warnings: [], scannedAt: Date())
        let ports = try MultiModelPlanner.availablePorts(base: 29940, count: 2, occupied: NetworkProbe.portOccupied)
        func ready(_ spec: ServiceSpec) async throws {
            for _ in 0..<80 { await store.services.refresh(); if store.services.status(spec) == .running { return }; try await Task.sleep(nanoseconds: 150_000_000) }
            throw LaunchError.message("Fixture service did not become ready")
        }
        func chat(_ alias: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(ports[1])/v1/chat/completions")!); request.httpMethod = "POST"; request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer " + store.gateway.settings.apiKey, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": alias, "messages": [["role": "user", "content": "hi"]]])
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        func waitGateway() async throws {
            for _ in 0..<80 { if store.gateway.ready && !store.gateway.busy { return }; await store.gateway.poll(); try await Task.sleep(nanoseconds: 100_000_000) }
            throw LaunchError.message("Gateway did not start: \(store.gateway.error ?? "")")
        }
        var spec = try store.services.start(engine: engine, model: model, port: ports[0], context: 32768)
        do {
            try await ready(spec)
            store.gateway.portText = String(ports[1]); store.gateway.start(store: store); try await waitGateway()
            store.synchronizeGateway()
            guard let alias = store.gateway.routes.first(where: { $0.sourceID == spec.id })?.alias else { throw LaunchError.message("Gateway route missing") }
            // 1. 请求日志与活动记录。
            let first = try await chat(alias)
            try ConnectionChecks.require(first == 200, "Gateway request failed: \(first)")
            let entries = GatewayRequestLog.read(store.gateway.requestLogURL)
            try ConnectionChecks.require(entries.first?.status == 200 && entries.first?.model == alias && entries.first?.promptTokens == 1 && entries.first?.completionTokens == 1 && entries.first?.client == "local", "Request log wrong: \(entries)")
            let log = try String(contentsOf: store.gateway.requestLogURL, encoding: .utf8)
            try ConnectionChecks.require(!log.contains("\"hi\"") && !log.contains("OK"), "Request log must not contain payloads")
            let activity = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: store.gateway.activityURL))
            try ConnectionChecks.require(activity[spec.id] != nil, "Activity not recorded for service")
            try ConnectionChecks.require(GatewayRequestLog.usage(entries).first?.requests == 1, "Usage summary wrong")
            // 2. 空闲停止：最近活动早于阈值。
            store.services.updateBehavior(spec.id, idleMinutes: .some(1))
            if let index = store.services.records.firstIndex(where: { $0.id == spec.id }) { store.services.records[index].startedAt = Date(timeIntervalSinceNow: -3600) }
            try JSONEncoder().encode([spec.id: Date().timeIntervalSince1970 - 3600]).write(to: store.gateway.activityURL)
            store.idleTick()
            for _ in 0..<60 { await store.services.refresh(); if store.services.records.first(where: { $0.id == spec.id })?.pid == nil { break }; try await Task.sleep(nanoseconds: 150_000_000) }
            guard let slept = store.services.records.first(where: { $0.id == spec.id }) else { throw LaunchError.message("Service missing") }
            try ConnectionChecks.require(slept.pid == nil && slept.sleeping == true, "Idle service was not stopped and marked sleeping")
            store.synchronizeGateway()
            try ConnectionChecks.require(store.gateway.routes.first(where: { $0.alias == alias })?.sleeping == true, "Sleeping route not kept with the same alias")
            // 3. 经网关请求唤醒：网关写唤醒请求，App 启动服务后转发。
            let pending = Task { try await chat(alias) }
            var status = 0
            for _ in 0..<300 {
                store.idleTick(); await store.services.refresh(); store.synchronizeGateway()
                if let current = store.services.records.first(where: { $0.id == spec.id }), current.pid != nil, store.services.status(current) == .running { spec = current }
                try await Task.sleep(nanoseconds: 200_000_000)
                if !store.gateway.routes.contains(where: { $0.alias == alias && $0.sleeping == true }) && spec.pid != nil { break }
            }
            status = try await pending.value
            try ConnectionChecks.require(status == 200 && spec.pid != nil && store.services.records.first(where: { $0.id == spec.id })?.sleeping == nil, "Wake through gateway failed: \(status)")
            // 4. 局域网监听：重启后监听所有网卡，本机请求照常可用。
            store.services.updateBehavior(spec.id, idleMinutes: .some(nil))
            store.gateway.settings.lanEnabled = true; try store.gateway.save()
            store.gateway.stop(); for _ in 0..<60 where store.gateway.busy || store.gateway.process != nil { try await Task.sleep(nanoseconds: 100_000_000) }
            store.gateway.start(store: store); try await waitGateway(); store.synchronizeGateway()
            let lsof = Process(); lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); lsof.arguments = ["-nP", "-a", "-i4TCP:\(ports[1])", "-sTCP:LISTEN"]
            let pipe = Pipe(); lsof.standardOutput = pipe; try lsof.run(); lsof.waitUntilExit()
            let listening = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try ConnectionChecks.require(listening.contains("*:\(ports[1])"), "Gateway is not listening on all interfaces: \(listening)")
            let local = try await chat(alias)
            try ConnectionChecks.require(local == 200, "Local request failed in LAN mode: \(local)")
            store.gateway.settings.lanEnabled = nil; try store.gateway.save()
        } catch {
            store.gateway.stop(); for spec in store.services.records where spec.pid != nil { try? store.services.stop(spec) }
            try? await Task.sleep(nanoseconds: 2_000_000_000); throw error
        }
        store.gateway.stop()
        for spec in store.services.records where spec.pid != nil { try store.services.stop(spec) }
        for _ in 0..<40 { await store.services.refresh(); if ports.allSatisfy({ !NetworkProbe.portOccupied($0) }) { break }; try await Task.sleep(nanoseconds: 250_000_000) }
        let report = try ConnectionFiles.json(["result": "passed", "checks": ["Request metadata and token usage logged without payloads", "Activity recorded per service", "Idle service stopped and route kept as sleeping",
            "Gateway request wakes the service and is forwarded", "LAN mode listens on all interfaces"]])
        try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
    }
}
