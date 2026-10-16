import Foundation
import CryptoKit

enum ModelManagementChecks {
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        let fm = FileManager.default
        let llama = try await EngineServiceChecks.prepare(store: store, root: root.appendingPathComponent("llama"))
        do {
            var ollama = store.engines.first { $0.kind == .ollama } ?? Engine(kind: .ollama, name: "Ollama", version: "测试", path: "", installed: true, canServe: true, installation: "测试", description: "测试", defaultPort: 11434, symbol: "cube")
            ollama.appPath = nil
            let fixtureProcesses = store.services.engineProcesses.filter { [llama.first.pid, llama.second.pid].contains($0.pid) }
            store.services.engineProcesses = fixtureProcesses
            try ConnectionChecks.require(store.installBlockers(ollama).isEmpty, "Unrelated Llama services blocked Ollama update")
            store.maintaining = true; store.maintenanceEngineID = "llama"
            try ConnectionChecks.require(store.installBlockers(ollama).isEmpty, "Unrelated engine maintenance blocked Ollama update")
            store.maintaining = false
            try ConnectionChecks.require(PortIdentity.engineID(executable: "/usr/bin/python3", arguments: ["python3", "-m", "mlx_lm.server"]) == "mlx" && PortIdentity.engineID(executable: "/usr/bin/python3", arguments: ["python3", "worker.py", "mlx"]) == nil, "Shared interpreter/library was treated as a serving engine")

            let registry = root.appendingPathComponent("ollama")
            let blob = registry.appendingPathComponent("blobs/sha256-" + String(repeating: "a", count: 64))
            let config = registry.appendingPathComponent("blobs/sha256-" + String(repeating: "b", count: 64))
            try fm.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("GGUFshared".utf8).write(to: blob); try Data("{}".utf8).write(to: config)
            let manifestData = try ConnectionFiles.json(["schemaVersion": 2, "config": ["digest": "sha256:" + String(repeating: "b", count: 64), "size": 2, "mediaType": "application/vnd.docker.container.image.v1+json"], "layers": [["digest": "sha256:" + String(repeating: "a", count: 64), "size": 10, "mediaType": "application/vnd.ollama.image.model"]]])
            func registered(_ name: String, namespace: String) throws -> LocalModel {
                let path = registry.appendingPathComponent("manifests/registry.ollama.ai/\(namespace)/\(name)/latest")
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true); try manifestData.write(to: path)
                let apiName = ModelFileCatalog.ollamaName(path)!
                return .init(id: "ollama:\(path.path)", name: apiName, format: "Ollama", path: path.path, kind: .language, bytes: 12, complete: true, verification: "模型层文件齐全", repository: apiName, missingFiles: [], removalPath: path.path)
            }
            let first = try registered("first", namespace: "library"), second = try registered("second", namespace: "team")
            try ConnectionChecks.require(first.repository == "first:latest" && second.repository == "team/second:latest", "Ollama namespaces or registry root were lost")
            let bundle = root.appendingPathComponent("mlx")
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try ConnectionFiles.json(["weight_map": ["a": "model-00001.safetensors", "b": "model-00002.safetensors"]]).write(to: bundle.appendingPathComponent("model.safetensors.index.json"))
            try ConnectionFiles.json(["quantization": ["bits": 4, "group_size": 64]]).write(to: bundle.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))
            try fm.createSymbolicLink(at: bundle.appendingPathComponent("model-00001.safetensors"), withDestinationURL: blob)
            let scan = Scanner.scan(extraRoots: [root.path])
            let fixtureLlama = store.engines.first { $0.kind == .llama }!
            store.inventory?.engines = scan.engines.map { $0.kind == .llama ? fixtureLlama : $0 }
            guard let partial = scan.models.first(where: { $0.path == bundle.path }) else { throw LaunchError.message("Imported model bundle was not detected") }
            try ConnectionChecks.require(!partial.complete && partial.missingFiles.contains("model-00002.safetensors"), "Missing shard was not detected")
            store.inventory?.models = [llama.model, first, second, partial]
            let entries = ModelFileCatalog.entries(model: first, models: store.models)
            try ConnectionChecks.require(entries.count == 3 && entries.filter { $0.references == 2 }.count == 2 && entries.allSatisfy(\.valid), "Ollama config/layers/shared references were not listed")
            let bundleEntries = ModelFileCatalog.entries(model: partial, models: store.models)
            try ConnectionChecks.require(bundleEntries.contains { $0.linked && $0.bytes == 10 } && bundleEntries.contains { $0.name == "model-00002.safetensors" && !$0.exists }, "Cache reference size or missing-file row was wrong")
            try store.registerModelLocations([URL(fileURLWithPath: llama.model.path), bundle])
            try ConnectionChecks.require(store.extraRoots.contains(bundle.path) && (try? Data(contentsOf: URL(fileURLWithPath: llama.model.path))) == Data("GGUF".utf8), "Import moved or modified original weights")
            store.showEngineModels("mlx")
            try ConnectionChecks.require(store.filteredModels.map(\.id) == [partial.id], "Model engine filter omitted incomplete compatible files or included unrelated formats")
            await store.modelFiles.load(partial, models: store.models)
            try await capture?("model-files-missing")
            store.modelFiles.search = "00002"
            try ConnectionChecks.require(store.modelFiles.filtered.count == 1 && !store.modelFiles.filtered[0].valid, "File search failed")
            store.modelFiles.search = ""
            let removal = try ModelFileSafety.removalURL(llama.model, models: store.models, roots: [root.path])
            try ConnectionChecks.require(ModelFileSafety.used(llama.model, removal: removal, services: store.services.records, external: []), "Active model was deletable")
            var broad = llama.model; broad.removalPath = root.path
            let narrow = try ModelFileSafety.removalURL(broad, models: store.models, roots: [root.path])
            try ConnectionChecks.require(narrow.path == llama.model.path, "Model removal included another model")

            let script = root.appendingPathComponent("ollama-server-fixture")
            let python = """
            #!/usr/bin/python3
            import os,json,pathlib,hashlib
            from http.server import HTTPServer,BaseHTTPRequestHandler
            root=pathlib.Path(__file__).parent;registry=root/'ollama';port=int(os.environ['OLLAMA_HOST'].rsplit(':',1)[1])
            paths={'first:latest':registry/'manifests/registry.ollama.ai/library/first/latest','team/second:latest':registry/'manifests/registry.ollama.ai/team/second/latest'}
            class H(BaseHTTPRequestHandler):
                def log_message(self,*args):pass
                def send(self,data):
                    raw=json.dumps(data).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
                def do_GET(self):
                    if self.path=='/api/tags':self.send({'models':[{'name':n,'digest':hashlib.sha256(p.read_bytes()).hexdigest()} for n,p in paths.items() if p.exists()]})
                    elif self.path=='/api/ps':self.send({'models':[{'name':'team/second:latest'}]+([{'name':'first:latest'}] if (root/'loaded-first').exists() else [])})
                    else:self.send({'data':[{'id':n} for n,p in paths.items() if p.exists()]})
                def do_POST(self):
                    body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    if self.path=='/api/generate':
                        if body['model']=='first:latest' and body['keep_alive']==0:(root/'loaded-first').unlink(missing_ok=True)
                        self.send({'done':True})
                    else:self.send({'modelfile':'FROM '+str(registry/'blobs'/('sha256-'+'a'*64))})
                def do_DELETE(self):
                    body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));name=body['model']
                    paths[name].unlink();(root/'deleted-name').write_text(name);self.send({})
            HTTPServer(('127.0.0.1',port),H).serve_forever()
            """
            try ConnectionFiles.write(Data(python.utf8), to: script, executable: true)
            ollama.path = script.path; ollama.canServe = true; ollama.installed = true; ollama.version = "测试"; ollama.description = "独立文件管理测试服务"
            if let index = store.inventory?.engines.firstIndex(where: { $0.id == "ollama" }) { store.inventory?.engines[index] = ollama }
            else { store.inventory?.engines.append(ollama) }
            let port = try MultiModelPlanner.availablePorts(base: 29860, count: 1, occupied: NetworkProbe.portOccupied)[0]
            let spec = try store.services.start(engine: ollama, model: nil, port: port, context: 8192)
            for _ in 0..<50 { await store.services.refresh(); if store.services.status(spec) == .running { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            let plan = EngineCatalog.plan(engine: ollama, release: .init(kind: .ollama, version: "0.0-test", source: "隔离测试 · 不执行更新", method: .brew))
            try ConnectionChecks.require(plan.blockers.isEmpty && store.installBlockers(ollama).isEmpty && store.restartableServices(ollama).map(\.port) == [port], "Update restart scope did not isolate the target engine")
            store.engineID = "ollama"; store.tab = .engines; store.installation.plan = plan
            try await capture?("ollama-update-scope-preview")
            store.installation.plan = nil; store.showEngineServices("ollama")
            try ConnectionChecks.require(store.visibleServices.allSatisfy { $0.engineID == "ollama" } && store.visibleExternalServices.allSatisfy { $0.engineID == "ollama" }, "Update navigation showed unrelated services")
            try await capture?("ollama-services-only")
            store.showEngineModels("ollama"); store.selectedFileID = first.id
            await store.modelFiles.load(first, models: store.models)
            try await capture?("ollama-model-files")
            let target = try await OllamaModelManagement.target(first, services: store.services)
            try Data().write(to: root.appendingPathComponent("loaded-first"))
            do { try await OllamaModelManagement.delete(target, services: store.services); throw LaunchError.message("Loaded model deletion was accepted") }
            catch LaunchError.message(let text) where text.contains("仍在内存") { }
            store.unloadOllamaModel("first:latest", port: port)
            for _ in 0..<50 { if store.unloadingModel == nil { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(store.message == nil && !fm.fileExists(atPath: root.appendingPathComponent("loaded-first").path), "Single-model unload failed")
            try await OllamaModelManagement.delete(target, services: store.services)
            try ConnectionChecks.require(!fm.fileExists(atPath: first.path) && fm.fileExists(atPath: second.path) && fm.fileExists(atPath: blob.path) && fm.fileExists(atPath: config.path), "Ollama deletion removed another model or shared blobs")
            try ConnectionChecks.require(spec.pid.map { processStartTime($0) == spec.processStart } == true && (try? String(contentsOf: root.appendingPathComponent("deleted-name"), encoding: .utf8)) == "first:latest", "Model deletion stopped the engine or targeted the wrong model")
            try await EngineServiceChecks.stopAndWait(spec, store: store)
            store.services.engineProcesses = fixtureProcesses
            try ConnectionChecks.require(store.installBlockers(ollama).isEmpty && store.restartableServices(ollama).isEmpty && plan.blockers.isEmpty, "Stopped runtime left a stale update blocker")
            await EngineServiceChecks.cleanup(store: store)
            let result: [String: Any] = ["result": "passed", "checks": ["Other engine services and maintenance do not block target update", "Interpreter/shared library does not identify a serving engine", "Target update restarts only related services; external processes still block", "Runtime blockers clear after stopping and are not saved in plan", "Update navigation filters to target engine", "Local import preserves originals", "Incomplete compatible models remain visible in engine filter", "Missing shard and cache reference size are accurate", "Ollama namespace/config/model layers/shared references are accurate", "Active files and other model directories are protected", "Loaded Ollama model deletion is blocked", "Native deletion targets one model and preserves shared layers, another model and engine PID", "Owned lightweight services cleaned up"], "realModelsDeleted": false, "realServicesStopped": false]
            let data = try ConnectionFiles.json(result); try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
        } catch { store.installation.plan = nil; await EngineServiceChecks.cleanup(store: store); throw error }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-model-management").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        try await exercise(store: store, root: root)
    }
}
