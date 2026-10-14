import Foundation

enum EngineServiceChecks {
    struct Fixture { var first: ServiceSpec; var second: ServiceSpec; var model: LocalModel; var root: URL }

    @MainActor static func prepare(store: AppStore, root: URL) async throws -> Fixture {
        try ConnectionFiles.privateDirectory(root)
        let script = root.appendingPathComponent("llama-server")
        let python = """
        #!/usr/bin/python3
        import json,argparse
        from http.server import HTTPServer,BaseHTTPRequestHandler
        p=argparse.ArgumentParser();p.add_argument('--port',type=int);a,rest=p.parse_known_args()
        class H(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                data=json.dumps({'data':[{'id':'fixture'}]}).encode()
                self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        HTTPServer(('127.0.0.1',a.port),H).serve_forever()
        """
        try ConnectionFiles.write(Data(python.utf8), to: script, executable: true)
        let weight = root.appendingPathComponent("fixture.gguf"); try Data("GGUF".utf8).write(to: weight)
        let model = LocalModel(id: "instance-fixture", name: "Qwen · 服务列表测试", format: "GGUF Q4_K_M", path: weight.path, kind: .language,
            bytes: 4, complete: true, verification: "测试模型", missingFiles: [], removalPath: weight.path)
        let engine = Engine(kind: .llama, name: "Llama", version: "测试", path: script.path, installed: true, canServe: true,
            installation: "测试服务", description: "同一基座 · 两个独立服务", defaultPort: 29760, symbol: "terminal")
        var engines = store.inventory?.engines ?? [engine]
        if let index = engines.firstIndex(where: { $0.id == engine.id }) { engines[index] = engine }
        else { engines.append(engine) }
        store.inventory = .init(engines: engines, models: [model], storageBytes: 4, memoryBytes: 0, chip: "测试环境", roots: [root.path], warnings: [], scannedAt: Date())
        store.engineID = engine.id; store.selectedModels[engine.id] = model.id
        let ports = try MultiModelPlanner.availablePorts(base: 29760, count: 2, occupied: NetworkProbe.portOccupied)
        let first = try store.services.start(engine: engine, model: model, port: ports[0], context: 8192)
        do {
            let second = try store.services.start(engine: engine, model: model, port: ports[1], context: 32768)
            for _ in 0..<50 {
                await store.services.refresh()
                if store.services.status(first) == .running && store.services.status(second) == .running { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try ConnectionChecks.require(store.services.status(first) == .running && store.services.status(second) == .running, "Two fixture services did not become ready")
            return .init(first: first, second: second, model: model, root: root)
        } catch { try? store.services.stop(first); throw error }
    }

    @MainActor static func stopAndWait(_ spec: ServiceSpec, store: AppStore) async throws {
        try store.services.stop(spec)
        try ConnectionChecks.require(!store.services.canRemoveConfiguration(spec), "Stopping service became deletable too early")
        for _ in 0..<50 {
            await store.services.refresh()
            if store.services.records.first(where: { $0.id == spec.id })?.pid == nil && !NetworkProbe.portOccupied(spec.port) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LaunchError.message("Fixture service did not stop")
    }

    @MainActor static func cleanup(store: AppStore) async {
        for spec in store.services.records where spec.pid != nil { try? store.services.stop(spec) }
        for _ in 0..<50 {
            await store.services.refresh()
            if store.services.records.allSatisfy({ $0.pid == nil }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor static func exercise(store: AppStore, fixture: Fixture, capture: ((String) async throws -> Void)? = nil) async throws {
        let first = fixture.first, second = fixture.second
        try ConnectionChecks.require(store.engineServices("llama").map(\.id) == [first.id, second.id], "Same-model instances were collapsed or omitted")
        store.selectedModels["llama"] = "another-model"
        store.port = String(first.port)
        let externalCount = store.externalEngineServices("llama").count
        try ConnectionChecks.require(store.engineServiceCount("llama") == 2 + externalCount, "Service list depends on selected model/port")
        store.services.external.append(.init(port: 29990, engineName: "MLX-LM", models: ["external"], ready: true, statusCode: 200, engineID: "mlx"))
        store.services.external.append(.init(port: 29991, engineName: "Llama", models: ["external"], ready: true, statusCode: 200, engineID: "llama"))
        store.services.external.append(.init(port: 29992, engineName: "未知", models: ["llama-model-name"], ready: true, statusCode: 200))
        try ConnectionChecks.require(store.engineServiceCount("llama") == 3 + externalCount && store.externalEngineServices("llama").filter { (29990...29992).contains($0.port) }.map(\.port) == [29991], "External service engine identity was not respected")
        store.services.external.removeAll { (29990...29992).contains($0.port) }
        store.configureService(second)
        try ConnectionChecks.require(store.port == String(second.port) && store.context == 32768 && store.selectedModels["llama"] == second.modelID, "Second instance configuration was not restored")
        store.tab = .engines
        try await capture?("engine-two-running")
        store.showService(second)
        try ConnectionChecks.require(store.selectedServiceID == second.id && store.selectedExternal == nil && store.tab == .services, "Instance detail selected the wrong service")
        try await capture?("service-second-running")
        var stale = first; stale.pid = nil
        do { try store.services.removeConfiguration(stale); throw LaunchError.message("Stale stopped record deleted a running instance") }
        catch LaunchError.message(let text) where text == "先停止服务，再删除配置" { }
        try await stopAndWait(first, store: store)
        try ConnectionChecks.require(second.pid.map { processStartTime($0) == second.processStart } == true && NetworkProbe.portOccupied(second.port), "Stopping first instance affected second")
        try ConnectionChecks.require(store.services.canRemoveConfiguration(first), "Stopped instance remained undeletable")
        store.tab = .engines; try await capture?("engine-one-stopped")
        store.showService(first); try await capture?("service-stopped-delete")
        let log = store.services.logURL(first.id)
        store.removeServiceConfiguration(first)
        try ConnectionChecks.require(store.message == nil && store.selectedServiceID == second.id, "Deleting selected service left an invalid detail selection")
        try ConnectionChecks.require(store.engineServices("llama").map(\.id) == [second.id], "Deletion changed the wrong instance")
        let saved = try JSONDecoder().decode([ServiceSpec].self, from: Data(contentsOf: store.services.stateDirectory.appendingPathComponent("services.json")))
        try ConnectionChecks.require(saved.map(\.id) == [second.id] && FileManager.default.fileExists(atPath: log.path) && FileManager.default.fileExists(atPath: fixture.model.path), "Deletion lost another configuration, logs or model weights")
        let restored = ServiceController(stateDirectory: store.services.stateDirectory)
        try ConnectionChecks.require(restored.records.first?.pid == second.pid, "Deletion did not persist safely across relaunch")
        store.tab = .engines; try await capture?("engine-after-delete")
        // An unbound or stopping launch must remain protected even without a PID.
        for status in [ServiceStatus.starting, .running, .stopping] {
            var pending = first; pending.id = "pending-\(status.rawValue)"; pending.pid = nil
            store.services.records.append(pending); store.services.statuses[pending.id] = status
            try ConnectionChecks.require(!store.services.canRemoveConfiguration(pending), "Pending launch configuration was deletable")
            store.services.records.removeAll { $0.id == pending.id }; store.services.statuses[pending.id] = nil
        }
        try ConnectionChecks.require(second.pid.map { processStartTime($0) == second.processStart } == true, "Deleting first instance changed second identity")
        try await stopAndWait(second, store: store)
        let report: [String: Any] = ["result": "passed", "ports": [first.port, second.port], "checks": ["Same engine and model show two independent running instances", "Selected model and port do not filter the list", "External engines require verified identity", "Second instance restores its own settings and detail", "Stale copied configuration cannot delete a restarted service", "Stopping/deleting first preserves second PID and readiness", "Selected deletion advances detail selection", "Persisted remaining service survives relaunch", "Model weights and logs are retained", "Starting/running/stopping records are protected", "Owned lightweight fixtures cleaned up"], "realServicesStopped": false]
        try ConnectionFiles.json(report).write(to: fixture.root.appendingPathComponent("result.json"))
        print(String(decoding: try ConnectionFiles.json(report), as: UTF8.self))
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-engine-services").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        do { let fixture = try await prepare(store: store, root: root); try await exercise(store: store, fixture: fixture) }
        catch { await cleanup(store: store); throw error }
    }
}
