import Foundation
import Darwin

enum GatewayChecks {
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        try ConnectionFiles.privateDirectory(root)
        let script = root.appendingPathComponent("llama-server")
        try ConnectionFiles.write(Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Tests/gateway_fixture.py")), to: script, executable: true)
        let weight = root.appendingPathComponent("fixture.gguf"), projector = root.appendingPathComponent("mmproj-fixture.gguf")
        try Data("GGUF".utf8).write(to: weight); try Data("GGUF".utf8).write(to: projector)
        let model = LocalModel(id: "gateway-fixture", name: "多模态测试模型", format: "GGUF", path: weight.path, kind: .language, bytes: 4, complete: true, verification: "测试模型", missingFiles: [], companion: projector.path, removalPath: weight.path)
        let engine = Engine(kind: .llama, name: "Llama", version: "测试", path: script.path, installed: true, canServe: true, installation: "测试", description: "模型输入模式验证", defaultPort: 29900, symbol: "terminal")
        store.inventory = .init(engines: [engine] + Scanner.engines().filter { $0.kind != .llama }, models: [model], storageBytes: 8, memoryBytes: 0, chip: "测试环境", roots: [root.path], warnings: [], scannedAt: Date())
        store.engineID = engine.id; store.selectedModels[engine.id] = model.id
        let plans = try [InputMode.text, .multimodal].map { try LaunchBuilder.plan(engine: engine, model: model, port: 29900, inputMode: $0) }
        try ConnectionChecks.require(!plans[0].arguments.contains("--mmproj") && plans[1].arguments.contains(projector.path), "Native text/multimodal launch settings were not applied")
        var missing = model; missing.companion = nil
        do { _ = try LaunchBuilder.plan(engine: engine, model: missing, port: 29900, inputMode: .multimodal); throw LaunchError.message("Missing projector was accepted") }
        catch LaunchError.message(let text) where text.contains("投影") { }
        let ports = try MultiModelPlanner.availablePorts(base: 29900, count: 4, occupied: NetworkProbe.portOccupied)
        var remoteProcess: Process?
        var remoteBirth: UInt64 = 0
        var takeover: Process?
        var takeoverBirth: UInt64 = 0
        do {
            let media = try store.services.start(engine: engine, model: model, port: ports[0], context: 32768, inputMode: .multimodal)
            let text = try store.services.start(engine: engine, model: model, port: ports[1], context: 32768, inputMode: .text)
            let remote = Process(); remote.executableURL = Bundle.main.executableURL
            remote.arguments = ["--child-exec", "/usr/bin/python3", script.path, "--port", String(ports[2]), "--mmproj", projector.path]
            var env = ProcessInfo.processInfo.environment; env["GATEWAY_FIXTURE_KEY"] = "upstream-fixture-secret"; remote.environment = env
            remote.standardOutput = FileHandle.nullDevice; remote.standardError = FileHandle.nullDevice; remote.standardInput = FileHandle.nullDevice
            try remote.run(); remoteProcess = remote; remoteBirth = processStartTime(remote.processIdentifier)
            for _ in 0..<60 { await store.services.refresh(); if store.services.status(media) == .running && store.services.status(text) == .running && NetworkProbe.portOccupied(ports[2]) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(store.services.status(media) == .running && store.services.status(text) == .running, "Fixture services did not become ready")
            let draft = GatewayEndpointDraft(); draft.name = "需密钥的外部测试服务"; draft.url = "http://127.0.0.1:\(ports[2])/v1"; draft.apiKey = "upstream-fixture-secret"; draft.context = "32768"
            store.gateway.addEndpoint(draft, store: store)
            for _ in 0..<100 { if !draft.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(draft.message == nil && store.gateway.settings.endpoints.count == 1, "External authenticated endpoint could not be registered")
            let duplicate = GatewayEndpointDraft(); duplicate.name = "另一个外部登记"; duplicate.url = draft.url; duplicate.apiKey = draft.apiKey; duplicate.context = "32768"
            store.gateway.addEndpoint(duplicate, store: store)
            for _ in 0..<100 { if !duplicate.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            store.gateway.portText = String(ports[3]); store.synchronizeGateway(); store.gateway.start(store: store)
            for _ in 0..<100 { if store.gateway.ready && !store.gateway.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(store.gateway.ready, "Gateway did not become ready: \(store.gateway.error ?? "")")
            guard let mediaRoute = store.gateway.routes.first(where: { $0.pid == media.pid }), let textRoute = store.gateway.routes.first(where: { $0.pid == text.pid }), let remoteRoute = store.gateway.routes.first(where: { $0.remote }) else { throw LaunchError.message("Gateway routes missing") }
            try ConnectionChecks.require(Set(store.gateway.routes.map(\.alias)).count == store.gateway.routes.count, "External services collided on model alias")
            let client = Process(); client.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            client.arguments = ["-B", FileManager.default.currentDirectoryPath + "/Tests/gateway_client_checks.py", "--config", store.gateway.configurationURL.path, "--url", store.gateway.endpoint, "--media-alias", mediaRoute.alias, "--text-alias", textRoute.alias, "--remote-alias", remoteRoute.alias, "--request-root", root.path]
            let output = root.appendingPathComponent("http-client.log"); FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output); client.standardOutput = handle; client.standardError = handle
            try client.run()
            for _ in 0..<300 { if !client.isRunning { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try handle.close()
            try ConnectionChecks.require(!client.isRunning && client.terminationStatus == 0, "Gateway HTTP protocol checks failed; see \(output.path)")
            store.gatewaySelected = true; store.tab = .services
            try await capture?("gateway-running")
            try await capture?("gateway-external-services")
            store.gatewaySelected = false; store.tab = .engines; store.port = String(ports[0]); store.inputMode = .multimodal
            try await capture?("model-multimodal-mode")
            guard let target = store.gatewayConnectionTargets.first(where: { $0.model == mediaRoute.alias }) else { throw LaunchError.message("Gateway connection target missing") }
            let connection = try ConnectionFiles.prepare(client: .pi, target: target, context: 32768, executable: "/bin/echo", project: root.path, root: root.appendingPathComponent("profiles"))
            try await ConnectionFiles.validateLaunch(URL(fileURLWithPath: connection.script + ".json"))
            let exported = jsonFile(URL(fileURLWithPath: connection.configuration))
            let providers = exported?["providers"] as? [String: Any]
            let provider = providers?[target.providerID] as? [String: Any]
            let exportModels = provider?["models"] as? [[String: Any]]
            try ConnectionChecks.require(provider?["apiKey"] as? String == store.gateway.settings.apiKey && exportModels?.first?["input"] as? [String] == ["text", "image"], "Gateway credentials or vision capability were not exported")
            store.tab = .services; store.connections.present(target: store.directConnectionTargets.first { $0.pid == media.pid }!)
            store.connections.viaGateway = true; store.connections.modelID = target.id; store.connections.context = 32768
            if capture != nil { for _ in 0..<80 { if !store.connections.discovering { break }; try await Task.sleep(nanoseconds: 100_000_000) } }
            try await capture?("gateway-connect-preview")
            store.connections.draft = nil
            store.gateway.setMode(mediaRoute, .text, store: store)
            var request = URLRequest(url: URL(string: store.gateway.endpoint + "/chat/completions")!); request.httpMethod = "POST"; request.setValue("Bearer " + store.gateway.settings.apiKey, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try ConnectionFiles.json(["model": mediaRoute.alias, "messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,fixture"]]]]]])
            let (_, filtered) = try await URLSession.shared.data(for: request)
            try ConnectionChecks.require((filtered as? HTTPURLResponse)?.statusCode == 400, "Gateway mode did not restrict a multimodal backend")
            do { try await ConnectionFiles.validateLaunch(URL(fileURLWithPath: connection.script + ".json")); throw LaunchError.message("Changed gateway route kept an old client receipt valid") }
            catch LaunchError.message(let text) where text.contains("路由") { }
            store.gateway.setMode(mediaRoute, .automatic, store: store)
            guard let remoteTarget = store.configuredConnectionTargets.first else { throw LaunchError.message("Direct external target missing") }
            try await ConnectionFiles.validateRemote(remoteTarget)
            let direct = try ConnectionFiles.prepare(client: .pi, target: remoteTarget, context: 32768, executable: "/bin/echo", project: root.path, root: root.appendingPathComponent("remote-profiles"))
            try await ConnectionFiles.validateLaunch(URL(fileURLWithPath: direct.script + ".json"))
            let controller = GatewayController(directory: store.services.stateDirectory)
            await controller.poll(); try ConnectionChecks.require(controller.ready && controller.process?.pid == store.gateway.process?.pid, "Gateway identity was not restored after manager relaunch")
            let secretAttrs = try FileManager.default.attributesOfItem(atPath: store.gateway.settingsURL.path)
            try ConnectionChecks.require(secretAttrs[.posixPermissions] as? Int == 0o600, "Gateway credentials are not private")
            try await EngineServiceChecks.stopAndWait(media, store: store)
            let replacement = Process(); replacement.executableURL = Bundle.main.executableURL; replacement.arguments = ["--child-exec", "/usr/bin/python3", script.path, "--port", String(ports[0])]; replacement.standardOutput = FileHandle.nullDevice; replacement.standardError = FileHandle.nullDevice
            try replacement.run(); takeover = replacement; takeoverBirth = processStartTime(replacement.processIdentifier)
            for _ in 0..<40 { if NetworkProbe.portOccupied(ports[0]) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            request.httpBody = try ConnectionFiles.json(["model": mediaRoute.alias, "messages": [["role": "user", "content": "do not forward"]]])
            let (_, stale) = try await URLSession.shared.data(for: request)
            try ConnectionChecks.require([404, 503].contains((stale as? HTTPURLResponse)?.statusCode ?? 0), "Gateway forwarded a stale route to a port replacement")
            try ConnectionChecks.require(text.pid.map { processStartTime($0) == text.processStart } == true, "Gateway operation stopped another backend")
            store.gateway.stop()
            for _ in 0..<60 { if !store.gateway.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(!store.gateway.ownsProcess() && text.pid.map { processStartTime($0) == text.processStart } == true, "Stopping gateway stopped its backend")
            await EngineServiceChecks.cleanup(store: store)
            if let remoteProcess, processStartTime(remoteProcess.processIdentifier) == remoteBirth { _ = kill(-remoteProcess.processIdentifier, SIGTERM) }
            if let takeover, processStartTime(takeover.processIdentifier) == takeoverBirth { _ = kill(-takeover.processIdentifier, SIGTERM) }
            let report: [String: Any] = ["result": "passed", "checks": ["Native text launch skips projector; multimodal requires matching projector", "Two separate model instances routed without alias collision", "Authenticated external endpoint supports direct and gateway access", "Stream, tools, image/audio/file and multipart HTTP checks passed", "Multimodal capabilities and private gateway key exported to pi", "Mode changes invalidate previous receipts", "Gateway restores verified process after manager relaunch", "Credentials saved with mode 0600", "Replaced listener cannot receive a stale model route", "Stopping gateway preserves backend PID", "Owned fixtures cleaned up"], "realModelsLoaded": false, "realServicesStopped": false]
            let data = try ConnectionFiles.json(report); try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
        } catch {
            store.connections.draft = nil; store.gateway.stop()
            for _ in 0..<50 { if !store.gateway.busy { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            await EngineServiceChecks.cleanup(store: store)
            if let remoteProcess, processStartTime(remoteProcess.processIdentifier) == remoteBirth { _ = kill(-remoteProcess.processIdentifier, SIGTERM) }
            if let takeover, processStartTime(takeover.processIdentifier) == takeoverBirth { _ = kill(-takeover.processIdentifier, SIGTERM) }
            throw error
        }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-gateway").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        try await exercise(store: store, root: root)
    }
}
