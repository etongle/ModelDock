import AppKit
import Foundation
import CryptoKit

@MainActor enum SolutionChecks {
    static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw LaunchError.message("Solution fixture timed out")
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-solutions").appendingPathComponent(UUID().uuidString)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        let fixture = try await EngineServiceChecks.prepare(store: store, root: root)
        do { try await exercise(store, fixture: fixture); await cleanupGateway(store); await EngineServiceChecks.cleanup(store: store) }
        catch { store.downloads.pauseAll(); await cleanupGateway(store); await EngineServiceChecks.cleanup(store: store); throw error }
        print("SOLUTION CHECKS PASSED: " + root.path)
    }
    private static func cleanupGateway(_ store: AppStore) async {
        for _ in 0..<120 { if !store.gateway.busy { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        store.gateway.stop()
        for _ in 0..<120 { if !store.gateway.busy { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
    }
    private static func exercise(_ store: AppStore, fixture: EngineServiceChecks.Fixture) async throws {
        let root = fixture.root
        func require(_ condition: Bool, _ message: String) throws { try ConnectionChecks.require(condition, message) }
        let solutions = store.solutions
        try require(store.serviceOrigin(fixture.first).labels == ["原生服务"], "Direct service was classified as solution-created")
        solutions.selectedID = "coding"
        var draft = solutions.draft; draft.localChoices[SolutionRole.chat.rawValue] = "llama\n" + fixture.model.id; solutions.setDraft(draft)
        solutions.install(store: store)
        try await wait { solutions.latest?.state == .configured || solutions.latest?.state == .failed }
        try require(solutions.latest?.state == .configured, solutions.latest?.error ?? "Local solution failed")
        let borrowed = solutions.latest!
        try require(store.serviceOrigin(fixture.first).labels == ["原生服务", "方案复用"], "Borrowed native service lost its creation source")
        try require(borrowed.components[0].ownsConfiguration == false && store.services.records.count == 2, "Running service was duplicated or claimed")
        solutions.start(borrowed.id, store: store); solutions.stop(borrowed.id, store: store); solutions.remove(borrowed.id, store: store)
        try require(processStartTime(fixture.first.pid!) == fixture.first.processStart && processStartTime(fixture.second.pid!) == fixture.second.processStart && solutions.deployments.isEmpty, "Removing a borrowed solution affected other service processes")

        let server = fixture.root.appendingPathComponent("solution-server")
        let script = """
        #!/usr/bin/python3
        import argparse,json
        from http.server import HTTPServer,BaseHTTPRequestHandler
        p=argparse.ArgumentParser();p.add_argument('--port',type=int);p.add_argument('--model',default='fixture');p.add_argument('--task',default='chat');a,_=p.parse_known_args()
        class H(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def reply(self,data,kind='application/json'):
                self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
            def do_GET(self):self.reply(json.dumps({'data':[{'id':a.model}]}).encode())
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length',0)))
                if self.path.endswith('/speech'):self.reply(b'RIFF'+b'0'*4+b'WAVE'+b'0'*36,'audio/wav')
                elif self.path.endswith('/transcriptions'):self.reply(json.dumps({'text':'Hello world'}).encode())
                else:self.reply(json.dumps({'choices':[{'message':{'content':'Bonjour le monde'}}]}).encode())
        HTTPServer(('127.0.0.1',a.port),H).serve_forever()
        """
        try ConnectionFiles.write(Data(script.utf8), to: server, executable: true)
        let audio = Engine(kind: .audio, name: "MLX Audio", version: "0.5.9", path: server.path, installed: false, canServe: false, installation: "fixture", description: "fixture", defaultPort: 29800, symbol: "waveform")
        let mlx = Engine(kind: .mlx, name: "MLX", version: "0.32.0", path: server.path, installed: true, canServe: true, installation: "fixture", description: "fixture", defaultPort: 29810, symbol: "cpu", visionPath: server.path)
        store.inventory?.engines += [audio, mlx]
        store.downloads.chooseDestination(root.appendingPathComponent("library").path)
        store.downloads.transferProtocolClasses = [SolutionHTTPFixture.self]
        store.downloads.onImported = { _ in }
        var installed = 0
        solutions.releaseLoader = { kind in .init(kind: kind, version: "0.5.9", source: "fixture", method: .python) }
        solutions.installEngine = { engine, _ in installed += 1; if let index = store.inventory?.engines.firstIndex(where: { $0.id == engine.id }) { store.inventory?.engines[index].installed = true; store.inventory?.engines[index].canServe = true } }
        solutions.catalogLoader = { input, credential in
            guard credential.isEmpty else { throw LaunchError.message("Public recipe inherited a private import token") }
            let value = URL(string: input)!.path.split(separator: "/").map(String.init)
            let repo = value.prefix(2).joined(separator: "/"), revision = value.last!
            let type = repo.contains("ASR") ? "qwen3_asr" : repo.contains("TTS") ? "qwen3_tts" : "qwen3"
            var files: [String: Data] = ["config.json": try JSONSerialization.data(withJSONObject: ["model_type": type, "quantization": ["bits": 4, "group_size": 64]]), "vocab.json": Data("{}".utf8), "model.safetensors": Data(repeating: 0, count: 512 * 1024)]
            if type == "qwen3_tts" { files["speech_tokenizer/config.json"] = Data("{}".utf8); files["speech_tokenizer/model.safetensors"] = Data(repeating: 0, count: 64) }
            let remote = files.keys.sorted().map { name -> RemoteFile in
                let url = URL(string: "https://solution-fixture.invalid/" + repo + "/" + name)!
                let data = files[name]!; SolutionHTTPFixture.put(url: url, data: data)
                return .init(path: name, url: url, bytes: Int64(data.count), sha256: DownloadTaskChecks.hash(data))
            }
            return .init(site: .huggingface, repository: repo, revision: revision, files: remote)
        }
        solutions.selectedID = "voice-translation"
        var voice = solutions.draft; voice.localChoices[SolutionRole.text.rawValue] = "download"; voice.destination = root.appendingPathComponent("library").path; voice.language = "French"; solutions.setDraft(voice)
        store.downloads.address = "keep-my-form"; store.downloads.token = "keep-my-token"; store.downloads.selectedTaskID = "keep-my-selection"
        solutions.install(store: store)
        try await wait { store.downloads.jobs.count == 3 && solutions.preparingID == nil }
        let voiceID = solutions.latest!.id
        try require(installed == 1 && store.downloads.address == "keep-my-form" && store.downloads.token == "keep-my-token", "Engine deduplication or import form isolation failed")
        solutions.pause(voiceID, store: store)
        try await wait { !store.downloads.hasPendingWork }
        try require(solutions.latest?.state == .paused && store.downloads.jobs.allSatisfy { $0.state == .paused || $0.state == .complete }, "Solution pause failed")
        let restored = SolutionController(directory: root.appendingPathComponent("state"))
        try require(restored.deployments.first { $0.id == voiceID }?.state == .paused && restored.drafts["voice-translation"]?.language == "French", "Solution state or language did not restore")
        solutions.retry(voiceID, store: store)
        try await wait { solutions.latest?.state == .configured || solutions.latest?.state == .failed }
        try require(solutions.latest?.state == .configured, solutions.latest?.error ?? "Remote solution failed")
        try require(store.downloads.selectedTaskID == "keep-my-selection", "Resuming a solution changed the open import selection")
        let configured = solutions.latest!
        let gatewayPort = try MultiModelPlanner.availablePorts(base: 29840, count: 1, occupied: NetworkProbe.portOccupied)[0]
        store.gateway.settings.port = gatewayPort; store.gateway.portText = String(gatewayPort)
        let endpoint = store.gateway.solutionEndpoint(configured)
        let connection = try store.gateway.solutionConnection(configured)
        let exported = try JSONSerialization.jsonObject(with: Data(connection.utf8)) as! [String: Any]
        try require(exported["baseURL"] as? String == endpoint && (exported["models"] as? [[String: String]])?.contains(where: { $0["model"] == "translation" }) == true, "Solution connection export is incomplete")
        let restoredGateway = GatewayController(directory: root.appendingPathComponent("state"))
        try require(restoredGateway.solutionEndpoint(configured) == endpoint && restoredGateway.settings.apiKey == store.gateway.settings.apiKey, "Solution URL/key did not survive reload")
        store.synchronizeGateway()
        try require(store.gateway.solutionRoutes.first(where: { $0.id == voiceID.lowercased() })?.components.allSatisfy { $0.routeID == nil } == true, "Stopped solution accidentally bound unrelated native services")
        let instances = solutions.services(configured, store: store)
        try require(instances.count == 3 && Set(instances.map(\.port)).count == 3 && instances.allSatisfy { $0.pid == nil } && installed == 1, "Installation started processes, allocated duplicate ports or reinstalled the engine")
        let asr = configured.components.first { $0.role == .asr }!, tts = configured.components.first { $0.role == .tts }!
        try require(instances.allSatisfy { store.serviceOrigin($0).labels == ["方案服务"] }, "Solution-created services lack their origin")
        try require(store.models.first { $0.id == asr.modelID }?.kind == .speech && store.models.first { $0.id == tts.modelID }?.kind == .speech, "Audio models were classified as chat models")
        try require(!store.models.contains { $0.path.hasSuffix("speech_tokenizer") }, "TTS audio tokenizer became an independent model")
        solutions.start(voiceID, store: store)
        for _ in 0..<100 { await store.services.refresh(); if solutions.services(configured, store: store).allSatisfy({ store.services.status($0) == .running }) { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try require(solutions.services(configured, store: store).allSatisfy { store.services.status($0) == .running }, "Solution components did not become ready")
        store.synchronizeGateway()
        let gatewaySolution = store.gateway.solutionRoutes.first { $0.id == voiceID.lowercased() }!
        try require(gatewaySolution.components.map(\.role) == ["asr", "translation", "tts"] && gatewaySolution.components.allSatisfy { $0.routeID != nil }, "Solution components did not bind to running routes")
        for component in configured.components {
            let binding = gatewaySolution.components.first { $0.role == component.role.gatewayModel }
            try require(store.gateway.routes.first { $0.id == binding?.routeID }?.sourceID == component.serviceID, "Solution URL routed to another service")
        }
        var changed = configured; changed.components[0].modelPath = root.appendingPathComponent("wrong-model").path
        store.gateway.synchronize(store.gatewaySourceTargets, local: store.models, services: store.services, deployments: [changed])
        try require(store.gateway.solutionRoutes[0].components.first?.routeID == nil, "Changed model path kept a stale solution binding")
        store.synchronizeGateway()
        let input = root.appendingPathComponent("sample.wav"); try Data("RIFFfixture".utf8).write(to: input)
        store.gateway.start(store: store)
        try await wait { store.gateway.ready && !store.gateway.busy }
        try require(store.gateway.supportsSolutionRoutes && store.gateway.solutionReady(configured), "Native gateway did not expose the configured solution")
        try require(store.solutionTrial.connection == .gateway, "Solution trial does not default to its gateway")
        store.solutionTrial.input = input; store.solutionTrial.run(configured, store: store)
        try await wait { !store.solutionTrial.busy }
        try require(store.solutionTrial.error == nil && store.solutionTrial.transcript == "Hello world" && store.solutionTrial.translation == "Bonjour le monde" && store.solutionTrial.output != nil, store.solutionTrial.error ?? "ASR -> translation -> TTS chain failed")
        await store.gateway.poll()
        try require(store.gateway.requests == 3, "Trial bypassed the scoped gateway")
        store.solutionTrial.connection = .direct; store.solutionTrial.run(configured, store: store)
        try await wait { !store.solutionTrial.busy }
        await store.gateway.poll()
        try require(store.solutionTrial.error == nil && store.solutionTrial.output != nil && store.gateway.requests == 3, "Explicit direct trial failed or used the gateway")
        try await SolutionExampleChecks.run(configured, store: store, root: root)
        await cleanupGateway(store)
        store.solutionTrial.connection = .gateway; store.solutionTrial.run(configured, store: store)
        try await wait { !store.solutionTrial.busy }
        try require(store.solutionTrial.error != nil && store.solutionTrial.transcript.isEmpty && store.solutionTrial.output == nil, "Unavailable gateway silently fell back to a direct service")
        solutions.selectedID = "transcription"
        solutions.install(store: store)
        try await wait { solutions.latest?.state == .configured || solutions.latest?.state == .failed }
        try require(solutions.latest?.state == .configured && store.downloads.jobs.count == 3 && solutions.latest?.components.first?.serviceID == asr.serviceID && solutions.latest?.components.first?.ownsConfiguration == false, "Shared model task/service was duplicated")
        let transcription = solutions.latest!
        try require(store.gateway.solutionEndpoint(transcription) != endpoint, "Different deployments collided on a solution URL")
        let shared = store.services.records.first { $0.id == asr.serviceID }!
        try require(store.serviceOrigin(shared).labels == ["方案服务", "方案复用"] && store.serviceOrigin(shared).uses.count == 2, "Shared solution origin is ambiguous")
        solutions.stop(transcription.id, store: store)
        try require(store.services.records.first { $0.id == asr.serviceID }?.pid != nil, "Borrowed ASR service stopped or disappeared")
        solutions.stop(voiceID, store: store)
        for _ in 0..<100 { await store.services.refresh(); if solutions.services(configured, store: store).filter({ $0.id != asr.serviceID }).allSatisfy({ $0.pid == nil }) { break }; try await Task.sleep(nanoseconds: 40_000_000) }
        try require(store.services.records.first { $0.id == asr.serviceID }?.pid != nil, "Owner stopped a service shared with another solution")
        try require(processStartTime(fixture.first.pid!) == fixture.first.processStart && processStartTime(fixture.second.pid!) == fixture.second.processStart, "Stopping a solution affected unrelated instances")
        solutions.remove(voiceID, store: store)
        store.synchronizeGateway()
        try require(!store.gateway.solutionRoutes.contains { $0.id == voiceID.lowercased() }, "Removed solution URL stayed registered")
        try require(solutions.deployments.count == 1 && solutions.deployments[0].components[0].ownsConfiguration && !solutions.deployments[0].processes.isEmpty, "Shared configuration/process ownership was not transferred")
        try require(store.serviceOrigin(shared).labels == ["方案服务"] && store.serviceOrigin(shared).uses.first?.solutionID == "transcription", "Transferred solution source was lost")
        solutions.stop(transcription.id, store: store)
        for _ in 0..<100 { await store.services.refresh(); if store.services.records.first(where: { $0.id == asr.serviceID })?.pid == nil { break }; try await Task.sleep(nanoseconds: 40_000_000) }
        solutions.remove(transcription.id, store: store)
        try require(solutions.deployments.isEmpty && store.downloads.jobs.count == 3 && FileManager.default.fileExists(atPath: asr.modelPath!), "Removing a solution deleted shared tasks or model files")
        let source = solutions.catalogLoader
        var forced = solutions.draft; forced.localChoices[SolutionRole.asr.rawValue] = "download"; solutions.setDraft(forced)
        solutions.catalogLoader = { address, credential in var listing = try await source!(address, credential); listing.revision = "incorrect-revision"; return listing }
        solutions.install(store: store)
        try await wait { solutions.latest?.state == .failed && solutions.preparingID == nil }
        try require(store.downloads.jobs.count == 3 && installed == 1, "Wrong revision caused downloads or engine mutations")
        solutions.remove(solutions.latest!.id, store: store)
        solutions.catalogLoader = source
        store.setEngineEnabled("audio", enabled: false)
        solutions.install(store: store)
        try require(solutions.deployments.isEmpty && solutions.message != nil, "A disabled engine was enabled or installed silently")
        store.setEngineEnabled("audio", enabled: true)
        let persisted = try String(contentsOf: root.appendingPathComponent("state/solutions.json"))
        try require(!persisted.contains("keep-my-token"), "Solution state persisted an access token")
        try ConnectionFiles.json(["result": "passed", "realServicesModified": false, "realModelInferenceTested": false, "checks": ["borrowed service stop/remove isolation", "pinned model manifests and resumable task reuse", "engine install once in an isolated runtime", "import form/token preservation", "pause and state restoration", "three stopped configurations with distinct ports", "ASR/TTS classification and companion decoder", "owned fixture processes start/stop", "fixture ASR-translation-TTS end-to-end", "shared ASR download/service reuse", "configuration removal preserves weights and jobs"]]).write(to: root.appendingPathComponent("result.json"))
    }
}

private final class SolutionHTTPFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payloads: [URL: Data] = [:]
    private var cancelled = false
    static func put(url: URL, data: Data) { lock.lock(); defer { lock.unlock() }; payloads[url] = data }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "solution-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let body = Self.payloads[request.url!]!; Self.lock.unlock()
        let offset = Int((request.value(forHTTPHeaderField: "Range") ?? "bytes=0-").dropFirst(6).split(separator: "-").first ?? "0") ?? 0
        var headers = ["Content-Length": String(max(0, body.count - offset)), "ETag": "\"fixture\"", "Accept-Ranges": "bytes"]
        if offset > 0 { headers["Content-Range"] = "bytes \(offset)-\(body.count - 1)/\(body.count)" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: offset > 0 ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        send(body, offset: offset)
    }
    private func send(_ body: Data, offset: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, !self.cancelled else { return }
            let end = min(offset + 16384, body.count)
            if offset < end { self.client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end)) }
            if end == body.count { self.client?.urlProtocolDidFinishLoading(self) } else { self.send(body, offset: end) }
        }
    }
    override func stopLoading() { cancelled = true }
}

@MainActor enum SolutionScreens {
    static func run(_ app: AppDelegate, folder: URL) async throws {
        guard argumentValue("--state-dir") != nil, let store = app.store, store.services.records.isEmpty else { throw LaunchError.message("Solution screenshots require isolated state") }
        store.services.polling = true
        let engine = Engine(kind: .llama, name: "Llama", version: "0.6.0_1", path: "/opt/modeldock/llama-server", installed: true, canServe: true, installation: "命令行服务", description: "使用 llama.cpp 运行本地 GGUF 模型", defaultPort: 8080, symbol: "bolt.fill")
        let model = LocalModel(id: "solution-demo-model", name: "Qwen3.8-27B", format: "GGUF Q8_0", path: "/private/tmp/ModelDock-Demo/Models/Qwen3.8-27B.gguf", kind: .language, bytes: 29_980_000_000, complete: true, verification: "文件存在 · GGUF 头部有效", missingFiles: [], removalPath: "/private/tmp/ModelDock-Demo/Models/Qwen3.8-27B.gguf")
        let audio = Engine(kind: .audio, name: "MLX Audio", version: "—", path: "", installed: false, canServe: false, installation: "独立语音运行环境", description: "Apple Silicon 语音识别与语音合成", defaultPort: 8096, symbol: "waveform")
        store.inventory = .init(engines: [engine, audio], models: [model], storageBytes: model.bytes, memoryBytes: 137_438_953_472, chip: "Apple Silicon", roots: [], warnings: [], scannedAt: Date())
        store.tab = .solutions; store.solutions.selectedID = "voice-translation"
        for language in [AppLanguage.english, .chinese, .french, .portuguese] {
            store.language = language
            store.solutions.section = .configuration
            try await Task.sleep(nanoseconds: 400_000_000); try app.capture(language.rawValue + "-solutions-configuration", folder: folder)
            store.solutions.section = .overview
            try await Task.sleep(nanoseconds: 300_000_000); try app.capture(language.rawValue + "-solutions-overview", folder: folder)
            store.solutions.section = .instances
            try await Task.sleep(nanoseconds: 300_000_000); try app.capture(language.rawValue + "-solutions-empty", folder: folder)
        }
        if CommandLine.arguments.contains("--solution-origins-ui") {
            let native = ServiceSpec(engineID: engine.id, modelID: model.id, modelName: model.name, modelPath: model.path, port: 8080)
            let reused = ServiceSpec(engineID: engine.id, modelID: model.id, modelName: model.name, modelPath: model.path, port: 8081)
            let shared = ServiceSpec(engineID: audio.id, modelID: "demo-asr", modelName: "Qwen3-ASR-1.7B-8bit", modelPath: "/private/tmp/ModelDock-Demo/Models/Qwen3-ASR-1.7B-8bit", port: 8096, engineVersion: "0.5.9")
            var translation = SolutionDeployment(solutionID: "voice-translation", draft: .init())
            translation.id = "FBA3CB54-89B0-410D-A606-17A9CDF949C4"
            translation.state = .configured
            translation.stage = "安装完成，服务尚未启动"
            translation.components = [
                .init(role: .asr, engineID: audio.id, repository: "mlx-community/Qwen3-ASR-1.7B-8bit", revision: "demo", serviceID: shared.id, ownsConfiguration: true),
                .init(role: .text, engineID: engine.id, repository: model.name, revision: "demo", serviceID: reused.id)
            ]
            var transcription = SolutionDeployment(solutionID: "transcription", draft: .init())
            transcription.id = "5A994F3F-9265-4356-8E31-79B9825BF45C"
            transcription.state = .configured
            transcription.stage = "安装完成，服务尚未启动"
            transcription.components = [.init(role: .asr, engineID: audio.id, repository: "mlx-community/Qwen3-ASR-1.7B-8bit", revision: "demo", serviceID: shared.id)]
            store.services.records = [native, reused, shared]
            store.solutions.deployments = [translation, transcription]
            for language in [AppLanguage.english, .chinese, .french, .portuguese] {
                store.language = language; store.showService(shared)
                try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-service-origins", folder: folder)
                store.chooseEngine(engine.id); store.engineSection = .services; store.tab = .engines
                try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-engine-origins", folder: folder)
                store.tab = .solutions; store.solutions.selectedID = "voice-translation"; store.solutions.section = .instances
                try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-solution-gateway", folder: folder)
                store.tab = .services; store.gatewaySelected = true
                try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-gateway-solutions", folder: folder)
                store.tab = .solutions; store.solutions.section = .overview
                try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-solution-trial", folder: folder)
            }
        }
        if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }
    }
}
