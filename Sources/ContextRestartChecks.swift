import Foundation

enum ContextRestartChecks {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-context-restart").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let script = root.appendingPathComponent("llama-server")
        let python = """
        #!/usr/bin/python3
        import sys,json,pathlib,argparse
        from http.server import HTTPServer,BaseHTTPRequestHandler
        p=argparse.ArgumentParser();p.add_argument('--port',type=int);p.add_argument('-c',type=int);a,rest=p.parse_known_args()
        pathlib.Path(__file__).with_name('started-'+str(a.port)+'-'+str(a.c)+'.json').write_text(json.dumps(sys.argv))
        if a.c==65536 and pathlib.Path(__file__).with_name('fail-expanded').exists():sys.exit(7)
        class H(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                data=json.dumps({'data':[{'id':'fixture'}]}).encode()
                self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        HTTPServer(('127.0.0.1',a.port),H).serve_forever()
        """
        try ConnectionFiles.write(Data(python.utf8), to: script, executable: true)
        let modelURL = root.appendingPathComponent("fixture.gguf"); try Data("GGUF".utf8).write(to: modelURL)
        let projector = root.appendingPathComponent("custom-projector.gguf"); try Data("GGUF".utf8).write(to: projector)
        let model = LocalModel(id: "fixture", name: "fixture", format: "GGUF Q4_K_M", path: modelURL.path, kind: .language,
            bytes: 4, complete: true, verification: "fixture", missingFiles: [], removalPath: modelURL.path)
        let engine = Engine(kind: .llama, name: "Llama", version: "fixture", path: script.path, installed: true,
            canServe: true, installation: "fixture", description: "fixture", defaultPort: 29660, symbol: "terminal")
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        store.inventory = .init(engines: [engine], models: [model], storageBytes: 4, memoryBytes: 0, chip: "fixture", roots: [root.path], warnings: [], scannedAt: Date())
        let ports = try MultiModelPlanner.availablePorts(base: 29660, count: 2, occupied: NetworkProbe.portOccupied)
        let first = try store.services.start(engine: engine, model: model, port: ports[0], context: 8192, inputMode: .multimodal, projectorPath: projector.path)
        let other = try store.services.start(engine: engine, model: model, port: ports[1], context: 8192, inputMode: .text)
        do {
            for _ in 0..<40 { await store.services.refresh(); if store.services.status(first) == .running && store.services.status(other) == .running { break }; try await Task.sleep(nanoseconds: 150_000_000) }
            let updated = try await store.connections.expandContext(store: store, port: ports[0], context: 32768)
            try ConnectionChecks.require(updated.context == 32768 && updated.pid != first.pid, "Context restart did not replace its own process")
            try ConnectionChecks.require(updated.inputMode == .multimodal && updated.projectorPath == projector.path, "Context restart lost input mode or selected projector")
            let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("started-\(ports[0])-32768.json")))
            try ConnectionChecks.require(arguments.contains(projector.path), "Restart did not pass the custom projector to the engine")
            try ConnectionChecks.require(other.pid.map { processStartTime($0) == other.processStart } == true, "Unrelated service changed")
            try Data().write(to: root.appendingPathComponent("fail-expanded"))
            do {
                _ = try await store.connections.expandContext(store: store, port: ports[0], context: 65536)
                throw LaunchError.message("Failed upgrade was accepted")
            } catch LaunchError.message(let text) where text.contains("已恢复原来的") { }
            guard let fallback = store.services.records.first(where: { $0.id == first.id }) else { throw LaunchError.message("Rollback service missing") }
            try ConnectionChecks.require(fallback.context == 32768 && fallback.pid != nil && store.services.status(fallback) == .running, "Rollback failed")
            try ConnectionChecks.require(fallback.inputMode == .multimodal && fallback.projectorPath == projector.path, "Rollback lost multimodal settings")
            try ConnectionChecks.require(other.pid.map { processStartTime($0) == other.processStart } == true, "Rollback altered another service")
            // Service parameter editor: reserved flags are rejected; a running service restarts with new values and extra flags.
            do { _ = try ServiceExtraArguments.parse("--threads 4 --port 1", engine: engine); throw LaunchError.message("Reserved flag was accepted") }
            catch LaunchError.message(let text) where text.contains("--port") { }
            func edit(_ spec: ServiceSpec, context: Int, extra: String) async throws -> ServiceParameterDraft {
                let draft = ServiceParameterDraft(spec); draft.context = context; draft.extra = extra
                store.saveServiceParameters(draft, spec: spec, launch: true)
                try ConnectionChecks.require(draft.error == nil, "Parameter edit rejected: \(draft.error ?? "")")
                for _ in 0..<80 { if store.relaunchingServiceID == nil { break }; try await Task.sleep(nanoseconds: 150_000_000) }
                return draft
            }
            _ = try await edit(other, context: 16384, extra: "--threads 4")
            guard let edited = store.services.records.first(where: { $0.id == other.id }) else { throw LaunchError.message("Edited service missing") }
            let editedArguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("started-\(ports[1])-16384.json")))
            try ConnectionChecks.require(edited.pid != other.pid && edited.context == 16384 && edited.extraArguments == ["--threads", "4"] && editedArguments.suffix(2) == ["--threads", "4"], "Parameter edit did not restart with new values")
            let failed = try await edit(edited, context: 65536, extra: "--threads 8")
            guard let restored = store.services.records.first(where: { $0.id == other.id }) else { throw LaunchError.message("Restored service missing") }
            try ConnectionChecks.require(failed.error?.contains("已按原参数重新启动") == true && restored.pid != nil && restored.context == 16384 && restored.extraArguments == ["--threads", "4"] && store.services.status(restored) == .running, "Failed parameter edit did not roll back")
            for spec in store.services.records where spec.pid != nil { try store.services.stop(spec) }
            for _ in 0..<40 { await store.services.refresh(); if ports.allSatisfy({ !NetworkProbe.portOccupied($0) }) { break }; try await Task.sleep(nanoseconds: 250_000_000) }
            try ConnectionChecks.require(ports.allSatisfy({ !NetworkProbe.portOccupied($0) }), "Fixture services not cleaned up")
            let report = try ConnectionFiles.json(["result": "passed", "checks": ["8K to 32K restart changes only selected PID",
                "Failed larger-context startup restores previous 32K service", "Multimodal mode and custom projector preserved on restart and rollback", "Other service identity preserved", "Service parameter edit restarts with extra flags", "Reserved flags rejected", "Failed parameter edit restores previous service", "Owned fixtures cleaned up"], "realServicesStopped": false])
            try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
        } catch {
            for spec in store.services.records where spec.pid != nil { try? store.services.stop(spec) }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            throw error
        }
    }
}
