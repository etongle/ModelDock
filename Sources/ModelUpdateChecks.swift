import Foundation
import CryptoKit

final class ModelUpdateHTTPFixture: URLProtocol {
    static let revision = String(repeating: "b", count: 40)
    static let bytes = ModalityChecks.gguf([:]) + Data("new fixture weights".utf8)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" && request.url?.path.contains("fixture-update/") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        let data: Data
        if path.hasPrefix("/api/models/") {
            let sha = SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined()
            data = try! JSONSerialization.data(withJSONObject: ["sha": Self.revision, "siblings": [
                ["rfilename": "model-Q8_0.gguf", "size": Self.bytes.count, "lfs": ["sha256": sha]],
                ["rfilename": "mmproj.gguf", "size": Self.bytes.count, "lfs": ["sha256": sha]],
                ["rfilename": "model-Q4_K_M.gguf", "size": Self.bytes.count, "lfs": ["sha256": sha]]]])
        } else { data = Self.bytes }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count), "Content-Type": "application/octet-stream", "ETag": "fixture-v2"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum ModelUpdateChecks {
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        try ConnectionFiles.privateDirectory(root)
        let fm = FileManager.default
        let old = root.appendingPathComponent("models/hf-cache/hub/models--fixture-update--demo/snapshots/" + String(repeating: "a", count: 40))
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let weight = old.appendingPathComponent("model-Q8_0.gguf"), projector = old.appendingPathComponent("mmproj.gguf")
        let oldBytes = ModalityChecks.gguf([:]) + Data("original fixture".utf8)
        try oldBytes.write(to: weight); try ModalityChecks.gguf(["clip.has_vision_encoder": true]).write(to: projector)
        let model = LocalModel(id: "gguf:\(weight.path)", name: "Update fixture", format: "GGUF Q8_0", path: weight.path, kind: .language, bytes: Int64(oldBytes.count), complete: true, verification: "fixture", missingFiles: [], companion: projector.path, removalPath: weight.path)
        let source = ModelOrigin.read(model)
        try ConnectionChecks.require(source?.repository == "fixture-update/demo" && source?.revision == String(repeating: "a", count: 40), "Local revision/origin was not recovered")
        try ConnectionChecks.require(!ModelOrigin.validRepository("../demo") && !ModelOrigin.validRepository("owner/repo/extra"), "Invalid repository escaped validation")
        var nested = model; nested.path = old.appendingPathComponent("quant/model-Q8_0.gguf").path; nested.companion = old.appendingPathComponent("quant/mmproj.gguf").path
        let nestedListing = RemoteListing(site: .huggingface, repository: "fixture-update/demo", revision: "new", files: ["quant/model-Q8_0.gguf", "quant/mmproj.gguf", "other/model-Q8_0.gguf"].map { RemoteFile(path: $0, url: URL(string: "https://huggingface.co/fixture-update/demo/resolve/new/" + $0)!, bytes: 1) })
        try ConnectionChecks.require(ModelOrigin.selectedFiles(model: nested, listing: nestedListing) == ["quant/model-Q8_0.gguf", "quant/mmproj.gguf"], "Nested repository paths mixed different models")
        URLProtocol.registerClass(ModelUpdateHTTPFixture.self)
        defer { URLProtocol.unregisterClass(ModelUpdateHTTPFixture.self) }
        store.downloads.transferProtocolClasses = [ModelUpdateHTTPFixture.self]
        let update = ModelUpdateDraft(model: model); store.modelUpdate = update
        update.check()
        for _ in 0..<100 { if !update.checking { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        try ConnectionChecks.require(update.error == nil && update.listing?.revision == ModelUpdateHTTPFixture.revision, "Update listing failed: \(update.error ?? "missing revision")")
        try ConnectionChecks.require(update.selected == ["model-Q8_0.gguf", "mmproj.gguf"] && !update.sameRevision, "Update chose another quantization or missed the projector")
        try await capture?("model-update-preview")
        store.downloads.destination = root.appendingPathComponent("models").path
        update.download(store: store)
        for _ in 0..<150 { if store.downloads.activeID == nil { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        guard let job = store.downloads.jobs.first, job.state == .complete else { throw LaunchError.message("Fixture version download failed: \(store.downloads.jobs.first?.error ?? store.downloads.message ?? "unknown")") }
        let newFolder = URL(fileURLWithPath: job.root).appendingPathComponent(job.folder)
        let preservedBytes = try Data(contentsOf: weight), downloadedBytes = try Data(contentsOf: newFolder.appendingPathComponent("model-Q8_0.gguf"))
        try ConnectionChecks.require(preservedBytes == oldBytes, "Update changed the old version")
        try ConnectionChecks.require(downloadedBytes == ModelUpdateHTTPFixture.bytes, "New version was not downloaded")
        try ConnectionChecks.require(!fm.fileExists(atPath: newFolder.appendingPathComponent("model-Q4_K_M.gguf").path), "Update downloaded an unrelated quantization")
        let receipt = try JSONDecoder().decode(ModelOrigin.self, from: Data(contentsOf: newFolder.appendingPathComponent("model-manager-source.json")))
        try ConnectionChecks.require(receipt.revision == ModelUpdateHTTPFixture.revision && receipt.files.count == 2, "Imported revision receipt was lost")
        for _ in 0..<100 { if !store.scanning { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        let scan = Scanner.scan(extraRoots: [root.appendingPathComponent("models").path])
        try ConnectionChecks.require(scan.models.contains { $0.path == weight.path } && scan.models.contains { $0.path == newFolder.appendingPathComponent("model-Q8_0.gguf").path && $0.origin?.revision == ModelUpdateHTTPFixture.revision }, "New and old versions were not separately discoverable")

        let fixture = URL(fileURLWithPath: fm.currentDirectoryPath + "/Tests/update_service_fixture.py")
        let launcher = root.appendingPathComponent("llama-server")
        try ConnectionFiles.write(Data("#!/bin/sh\nexec /usr/bin/python3 -B \(ServiceCommand.quote(fixture.path)) \"$@\"\n".utf8), to: launcher, executable: true)
        let engine = Engine(kind: .llama, name: "Llama", version: "fixture", path: launcher.path, installed: true, canServe: true, installation: "fixture", description: "Fixture", defaultPort: 29510, symbol: "sparkles")
        let ports = try EnginePortPolicy.available(engine: engine, base: 29510, count: 3, occupied: { NetworkProbe.portOccupied($0) })
        defer { for spec in store.services.records where spec.pid != nil { try? store.services.stop(spec) } }
        let text = "HF_HUB_CACHE=" + ServiceCommand.quote(root.appendingPathComponent("cache with spaces").path) + " \\\n" + ServiceCommand.quote(engine.path) + " -m " + ServiceCommand.quote(weight.path) + " --port=\(ports[0]) -c 32768 --no-mmproj --temp 0.65"
        let command = try ServiceCommand.parse(text, engine: engine, models: [model])
        try ConnectionChecks.require(command.port == ports[0] && command.context == 32768 && command.mode == .text && command.plan.arguments.contains("0.65"), "Command parameters were not preserved")
        let reparsed = try ServiceCommand.parse(command.display, engine: engine, models: [model])
        try ConnectionChecks.require(reparsed.plan.arguments == command.plan.arguments && reparsed.plan.environment == command.plan.environment, "Saved command cannot be restored")
        for invalid in [text + " ; echo bad", text + " --port 29520", text + " --host 0.0.0.0", "sh -c 'echo bad'", text + " --model '/different/file'", text + " --api-key secret", text + " $(echo bad)"] {
            var rejected = false; do { _ = try ServiceCommand.parse(invalid, engine: engine, models: [model]) } catch { rejected = true }
            try ConnectionChecks.require(rejected, "Invalid command was accepted")
        }
        let sentinel = try store.services.start(engine: engine, model: model, port: ports[1], context: 8192)
        let active = try store.services.start(command: command)
        for _ in 0..<50 { await store.services.refresh(); if store.services.status(active) == .running && store.services.status(sentinel) == .running { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try ConnectionChecks.require(store.services.status(active) == .running, "Command service did not become ready")
        let state = try await OllamaModelManagement.request(port: active.port, path: "/fixture/state")
        try ConnectionChecks.require(state["context"] as? Int == 32768 && (state["argv"] as? [String])?.contains("0.65") == true && state["cache"] as? String == command.plan.environment["HF_HUB_CACHE"], "Spawned command differs from preview")
        // Download another revision while the old model is actively served.
        let activeRoot = root.appendingPathComponent("active-update-models")
        store.downloads.destination = activeRoot.path; update.download(store: store)
        for _ in 0..<150 { if store.downloads.activeID == nil { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        try ConnectionChecks.require(store.downloads.jobs.first?.state == .complete &&
                                     store.downloads.jobs.first?.root == activeRoot.path, "Independent update did not finish while the old service ran")
        let activeAfterUpdate = try await OllamaModelManagement.request(port: active.port, path: "/fixture/state")
        let servedBytesAfterUpdate = try Data(contentsOf: weight)
        try ConnectionChecks.require(processStartTime(active.pid!) == active.processStart &&
                                     activeAfterUpdate["model"] as? String == weight.path &&
                                     servedBytesAfterUpdate == oldBytes &&
                                     store.services.records.first { $0.id == active.id }?.modelPath == active.modelPath, "Model update altered the running old-version service")
        var conflictRejected = false; do { _ = try store.services.start(command: command) } catch { conflictRejected = true }
        try ConnectionChecks.require(conflictRejected && processStartTime(sentinel.pid!) == sentinel.processStart, "Port conflict disturbed a different service")
        let restored = ServiceController(stateDirectory: store.services.stateDirectory)
        try ConnectionChecks.require(restored.records.first { $0.id == active.id }?.commandText == command.display && restored.records.first { $0.id == active.id }?.pid == active.pid, "Command service did not survive controller restoration")
        store.configureService(active); try ConnectionChecks.require(store.commandDraft?.text == command.display, "Configure lost the custom command")
        var inventory = scan; inventory.engines = [engine]; inventory.models = [model]; store.inventory = inventory
        try await capture?("service-command-preview"); store.commandDraft = nil
        try store.services.stop(active)
        for _ in 0..<60 { if processStartTime(active.pid!) == 0 { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try ConnectionChecks.require(processStartTime(sentinel.pid!) == sentinel.processStart, "Stopping a command service killed the other instance")

        // Modern Splash records, including hidden revision/text selections.
        let splashRoot = root.appendingPathComponent("Splash/models"), assembly = splashRoot.appendingPathComponent(".resolved/fixture")
        try fm.createDirectory(at: assembly, withIntermediateDirectories: true)
        try fm.createDirectory(at: splashRoot.appendingPathComponent(".selections"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: assembly.appendingPathComponent("weights.gguf"), withDestinationURL: weight)
        let record: [String: Any] = ["version": 1, "model": "fixture-update/demo:Q8_0", "family": "fixture", "target_format": "gguf", "vision_format": "safetensors", "sources": ["target": ["repo": "fixture-update/demo", "revision": String(repeating: "a", count: 40)], "draft": ["repo": "fixture-update/draft", "revision": String(repeating: "c", count: 40)]], "files": ["weights.gguf": ["path": weight.path, "bytes": oldBytes.count]]]
        try ConnectionFiles.json(record).write(to: assembly.appendingPathComponent("model.json"))
        try fm.createSymbolicLink(at: splashRoot.appendingPathComponent(".selections/revision-selection"), withDestinationURL: assembly)
        let prepared = SplashAssemblyCatalog.scan(root: splashRoot)
        try ConnectionChecks.require(prepared.count == 1 && prepared[0].complete && ModalityPolicy.local(prepared[0]).inputs == ["text", "image", "file"], "Hidden modern Splash selection was not recognized")
        let keg = root.appendingPathComponent("Cellar/splash/1.3.1"), libexec = keg.appendingPathComponent("libexec")
        for subdir in ["bin", "libexec/python/bin", "libexec/engine", "libexec/install"] { try fm.createDirectory(at: keg.appendingPathComponent(subdir), withIntermediateDirectories: true) }
        for path in [keg.appendingPathComponent("bin/splash"), libexec.appendingPathComponent("python/bin/python3"), libexec.appendingPathComponent("engine/splash")] { try ConnectionFiles.write(Data("#!/bin/sh\nexit 0\n".utf8), to: path, executable: true) }
        try Data().write(to: libexec.appendingPathComponent("engine/splash.metallib")); try Data().write(to: libexec.appendingPathComponent("install/launcher.py"))
        try Data("PACKAGE_REPLACEMENTS = {}".utf8).write(to: libexec.appendingPathComponent("install/models.py")); try ConnectionFiles.json(["version": "1.3.1"]).write(to: libexec.appendingPathComponent("release.json"))
        var splash = engine; splash.kind = .splash; splash.name = "Splash"; splash.path = keg.appendingPathComponent("bin/splash").path
        let modern = try ServiceCommand.parse("\(ServiceCommand.quote(splash.path)) serve --model mlx-community/Qwen3.8-27B-4bit --port \(ports[2]) --max-context 32768 --language-only", engine: splash, models: [])
        try ConnectionChecks.require(modern.plan.executable == libexec.appendingPathComponent("python/bin/python3").path && modern.mode == .text && modern.downloadsModel, "Modern Splash command was not pinned to the new runtime")
        let plan = try LaunchBuilder.plan(engine: splash, model: prepared[0], port: ports[2], context: 32768, inputMode: .multimodal)
        try ConnectionChecks.require(plan.arguments.contains(String(repeating: "a", count: 40)) && !plan.arguments.contains("--language-only") && plan.engineVersion == "1.3.1", "Prepared Splash vision/revision launch is incorrect")
        var legacy = model; legacy.format = "Splash 4-bit"; legacy.repository = "incoai/Qwen3.8-27B-Splash"
        try ConnectionChecks.require(ModelOrigin.replacement(legacy) == "mlx-community/Qwen3.8-27B-4bit", "Old packed migration target was not mapped")
        let sourceUse = ServiceSpec(engineID: "splash", modelID: prepared[0].id, modelName: prepared[0].name, modelPath: assembly.path, port: ports[2], pid: 42)
        try ConnectionChecks.require(ModelFileSafety.used(model, removal: weight, services: [sourceUse], external: []), "Active Splash shared source files were not protected")
        try fm.removeItem(at: assembly.appendingPathComponent("weights.gguf"))
        try ConnectionChecks.require(SplashAssemblyCatalog.scan(root: splashRoot).first?.complete == false, "Missing assembly source was marked complete")

        // Pull only one registered Ollama model through its owning service.
        let ollamaRoot = root.appendingPathComponent("ollama"), manifest = ollamaRoot.appendingPathComponent("manifests/registry.ollama.ai/library/demo/latest")
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.createDirectory(at: ollamaRoot.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try ConnectionFiles.json(["layers": [], "config": ["digest": "sha256:" + String(repeating: "a", count: 64), "size": 1]]).write(to: manifest)
        try Data([1]).write(to: ollamaRoot.appendingPathComponent("blobs/sha256-" + String(repeating: "a", count: 64)))
        let ollamaEntry = root.appendingPathComponent("ollama-cli")
        try ConnectionFiles.write(Data("#!/bin/sh\nexec /usr/bin/python3 -B \(ServiceCommand.quote(fixture.path)) \"$@\"\n".utf8), to: ollamaEntry, executable: true)
        var ollama = engine; ollama.kind = .ollama; ollama.name = "Ollama"; ollama.path = ollamaEntry.path
        let ollamaCommand = try ServiceCommand.parse("OLLAMA_MODELS=\(ServiceCommand.quote(ollamaRoot.path)) OLLAMA_HOST=127.0.0.1:\(ports[2]) \(ServiceCommand.quote(ollama.path)) serve", engine: ollama, models: [])
        let ollamaSpec = try store.services.start(command: ollamaCommand)
        for _ in 0..<50 { await store.services.refresh(); if store.services.status(ollamaSpec) == .running { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        let registered = LocalModel(id: "ollama:\(manifest.path)", name: "demo:latest", format: "Ollama", path: manifest.path, kind: .language, bytes: 1, complete: true, verification: "fixture", repository: "demo:latest", missingFiles: [], removalPath: manifest.path)
        func loaded(_ names: [String]) async throws {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(ports[2])/fixture/loaded-models")!)
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: ["models": names])
            let (_, response) = try await URLSession.shared.data(for: request)
            try ConnectionChecks.require((response as? HTTPURLResponse)?.statusCode == 200, "Could not set fixture loaded models")
        }
        try await loaded(["demo:latest"])
        let blockedPull = ModelUpdateDraft(model: registered); blockedPull.ollamaUpdate(store: store)
        for _ in 0..<100 { if !blockedPull.updating { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        let beforePull = try await OllamaModelManagement.request(port: ports[2], path: "/fixture/state")
        try ConnectionChecks.require(blockedPull.error?.contains("再更新") == true && (beforePull["pulls"] as? [String])?.isEmpty == true, "Loaded Ollama model was updated")
        try await loaded([])
        let pull = ModelUpdateDraft(model: registered); pull.ollamaUpdate(store: store)
        for _ in 0..<100 { if !pull.updating { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try ConnectionChecks.require(pull.error == nil && pull.result != nil, "Ollama update failed: \(pull.error ?? "unknown")")
        let pulled = try await OllamaModelManagement.request(port: ports[2], path: "/fixture/state")
        try ConnectionChecks.require(pulled["pulls"] as? [String] == ["demo:latest"] && processStartTime(sentinel.pid!) == sentinel.processStart, "Ollama update affected another model or service")
        for _ in 0..<100 { if !store.scanning { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        let report: [String: Any] = ["result": "passed", "checks": ["repository and local revision recovery", "same quantization and projector selection", "SHA-verified new snapshot with old bytes preserved", "both snapshots scan independently", "update while old-version service remains running", "loaded Ollama model update blocked", "argv/env/quotes/custom parameters actually executed", "shell and endpoint ambiguity rejected", "port conflicts and instance stop isolation", "persisted command restored", "modern Splash hidden selections and vision", "new Splash runtime and revision pinned", "missing assembly files detected", "active shared weights protected", "single Ollama tag updated through its owning service"], "realModelDownloads": false, "originalRealServicesTouched": false]
        try ConnectionFiles.json(report).write(to: root.appendingPathComponent("result.json")); print(String(decoding: try ConnectionFiles.json(report), as: UTF8.self))
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--evidence-dir") ?? "/private/tmp/model-update-checks").appendingPathComponent(UUID().uuidString)
        let state = root.appendingPathComponent("state"); try ConnectionFiles.privateDirectory(state)
        try await exercise(store: AppStore(stateDirectory: state), root: root)
        print("Evidence: \(root.path)")
    }
}
