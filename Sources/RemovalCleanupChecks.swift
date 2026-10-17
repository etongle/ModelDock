import Foundation

enum RemovalCleanupChecks {
    @MainActor static func run() throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-removal-cleanup").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home"), connections = root.appendingPathComponent("connections"), defaultConnections = connections
        let pi = home.appendingPathComponent(".pi/agent"), opencode = home.appendingPathComponent(".config/opencode")
        for url in [pi, opencode, connections.appendingPathComponent("launchers")] { try ConnectionFiles.privateDirectory(url) }
        // 用户自有的 provider 与两个 ModelDock 登记：deleted 属于被删除的服务，kept 属于继续存在的服务。
        try ConnectionFiles.write(try ConnectionFiles.json(["providers": [
            "mine": ["baseUrl": "https://example.invalid/v1", "models": [["id": "cloud"]]],
            "model-manager-29001": ["baseUrl": "http://127.0.0.1:29001/v1", "models": [["id": "deleted"]]],
            "model-manager-29002": ["baseUrl": "http://127.0.0.1:29002/v1", "models": [["id": "kept"], ["id": "deleted-too"]]]
        ]]), to: pi.appendingPathComponent("models.json"))
        try ConnectionFiles.write(try ConnectionFiles.json(["defaultProvider": "model-manager-29001", "defaultModel": "deleted", "theme": "dark",
            "compaction": ["modelOverrides": ["model-manager-29001/deleted": ["reserveTokens": 1], "model-manager-29002/kept": ["reserveTokens": 2]]]]), to: pi.appendingPathComponent("settings.json"))
        try ConnectionFiles.write(Data("""
        // user comment
        {"model": "model-manager-29001/deleted", "enabled_providers": ["mine", "model-manager-29001"],
         "provider": {"mine": {"models": {"cloud": {}}}, "model-manager-29001": {"models": {"deleted": {}}}},}
        """.utf8), to: opencode.appendingPathComponent("opencode.jsonc"))
        func receipt(_ client: CodingClient, source: String, port: Int, model: String, file: URL, engine: String = "llama", in connections: URL? = nil) throws {
            let connections = connections ?? defaultConnections
            let profile = connections.appendingPathComponent("profiles/\(client.rawValue)/\(UUID().uuidString)")
            try ConnectionFiles.privateDirectory(profile)
            let configuration = client == .pi ? profile.appendingPathComponent("models.json") : profile.appendingPathComponent("config/opencode/opencode.json")
            var target = ConnectionTarget(id: "\(source):\(model)", engineName: engine, engineID: engine, model: model, port: port, pid: 1, birth: 1, context: 32768)
            target.sourceID = source
            let script = connections.appendingPathComponent("launchers/\(client.rawValue)-\(UUID().uuidString).command")
            var connection = ClientConnection(client: client, model: model, endpoint: target.endpoint, providerID: target.providerID, context: 32768, project: root.path, executable: "/bin/true",
                configuration: configuration.path, script: script.path, environment: [:], arguments: [], service: target)
            connection.registeredConfiguration = file.path
            try ConnectionFiles.write(Data("#!/bin/sh\n".utf8), to: script, executable: true)
            try ConnectionFiles.write(try JSONEncoder().encode(connection), to: script.appendingPathExtension("json"))
        }
        try receipt(.pi, source: "service-a", port: 29001, model: "deleted", file: pi.appendingPathComponent("models.json"))
        try receipt(.opencode, source: "service-a", port: 29001, model: "deleted", file: opencode.appendingPathComponent("opencode.jsonc"))
        try receipt(.pi, source: "service-b", port: 29002, model: "kept", file: pi.appendingPathComponent("models.json"))
        // 来源服务早已删除的孤立登记，只能按模型名称匹配。
        try receipt(.pi, source: "gone", port: 29002, model: "deleted-too", file: pi.appendingPathComponent("models.json"))

        let scope = ClientRegistrationCleanup.Scope(sourceIDs: ["service-a"], names: ["deleted-too"], strictSources: ["service-b"])
        let plan = ClientRegistrationCleanup.plan(root: connections, scope: scope, keepSources: ["service-b"])
        try ConnectionChecks.require(plan.registrations.count == 3 && !plan.registrations.contains { $0.model == "kept" }, "Cleanup plan selected wrong registrations: \(plan.registrations)")
        let removed = try ClientRegistrationCleanup.apply(plan, root: connections)
        try ConnectionChecks.require(removed == 3, "Cleanup did not remove three registrations")

        let models = try NativeClientConfig.object(Data(contentsOf: pi.appendingPathComponent("models.json")))
        let providers = try NativeClientConfig.dictionary(models, "providers")
        try ConnectionChecks.require(providers["mine"] != nil && providers["model-manager-29001"] == nil, "pi provider cleanup wrong")
        try ConnectionChecks.require(((providers["model-manager-29002"] as? [String: Any])?["models"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["kept"], "pi kept model changed")
        let settings = try NativeClientConfig.object(Data(contentsOf: pi.appendingPathComponent("settings.json")))
        let overrides = try NativeClientConfig.dictionary(try NativeClientConfig.dictionary(settings, "compaction"), "modelOverrides")
        try ConnectionChecks.require(settings["defaultModel"] == nil && settings["theme"] as? String == "dark" && overrides.keys.sorted() == ["model-manager-29002/kept"], "pi settings cleanup wrong")
        let config = try NativeClientConfig.object(Data(contentsOf: opencode.appendingPathComponent("opencode.jsonc")))
        let opencodeProviders = try NativeClientConfig.dictionary(config, "provider")
        try ConnectionChecks.require(config["model"] == nil && config["enabled_providers"] as? [String] == ["mine"] && opencodeProviders.keys.sorted() == ["mine"], "OpenCode cleanup wrong")
        let left = ClientRegistrationCleanup.receipts(root: connections)
        try ConnectionChecks.require(left.count == 1 && left[0].connection.service.sourceID == "service-b", "Receipts not cleaned")
        let profiles = try FileManager.default.contentsOfDirectory(atPath: connections.appendingPathComponent("profiles/pi").path)
        try ConnectionChecks.require(profiles.count == 1, "Private profiles not cleaned")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: connections.appendingPathComponent("client-config-backups/opencode").path)) ?? []
        try ConnectionChecks.require(backups.count == 1, "Original client config not backed up")
        // 重复执行无副作用。
        try ConnectionChecks.require(ClientRegistrationCleanup.plan(root: connections, scope: scope, keepSources: ["service-b"]).isEmpty, "Second cleanup is not empty")

        // 测速记录：现有模型（别名大小写不同）保留，已删除模型的记录识别为失效，外部服务记录不计入。
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        let modelPath = root.appendingPathComponent("Qwen-Kept"); try ConnectionFiles.privateDirectory(modelPath)
        var kept = LocalModel(id: modelPath.path, name: "Qwen-Kept", format: "MLX", path: modelPath.path, kind: .language, bytes: 1, complete: true, verification: "", missingFiles: [], removalPath: modelPath.path)
        var registration = SplashRegistration(kept); registration.id = "Qwen-Kept-Alias"; registration.aliases = ["qwen-kept-alias"]; registration.name = "Qwen Kept"
        kept.splashRegistrations = [registration]
        store.inventory = .init(engines: [], models: [kept], storageBytes: 1, memoryBytes: 0, chip: "fixture", roots: [root.path], warnings: [], scannedAt: Date())
        func record(_ model: String, engine: String, id: String? = nil) -> BenchmarkResult {
            BenchmarkResult(target: .init(id: model, engineID: engine, engineName: engine, engineVersion: "1", modelID: id, modelName: model, apiModel: model, port: 1), chip: "fixture", requestedTokens: 1, elapsed: 1, rateSource: "fixture")
        }
        store.performance.records = [record("QWEN-KEPT-ALIAS", engine: "splash"), record("mlx-community/Gone", engine: "splash"), record("lmstudio-model", engine: "lmstudio"), record("x", engine: "mlx", id: "/gone/model")]
        let orphans = Set(store.orphanedBenchmarks.map(\.target.modelName))
        try ConnectionChecks.require(orphans == ["mlx-community/Gone", "x"], "Orphaned benchmark detection wrong: \(orphans)")
        let deletion = store.removalCleanup(model: kept, removedPath: modelPath.path)
        try ConnectionChecks.require(deletion.benchmarks == Set(store.performance.records.filter { $0.target.modelName == "QWEN-KEPT-ALIAS" }.map(\.id)), "Model deletion did not select its benchmark records")

        // 服务仍在，但同端口登记的已删除模型应识别为失效；当前别名（含在服务模型名中）保留。
        try ConnectionFiles.privateDirectory(store.connections.root.appendingPathComponent("launchers"))
        store.services.records = [ServiceSpec(id: "svc-live", engineID: "splash", modelID: "", modelName: "Owner/Super-Live-Model-4bit", modelPath: "", port: 28000)]
        let piFile = pi.appendingPathComponent("models.json")
        try receipt(.pi, source: "svc-live", port: 28000, model: "mlx-community/Gone", file: piFile, engine: "splash", in: store.connections.root)
        try receipt(.pi, source: "svc-live", port: 28000, model: "live-model", file: piFile, engine: "splash", in: store.connections.root)
        store.refreshStaleRegistrations()
        try ConnectionChecks.require(store.staleRegistrations.registrations.map(\.model) == ["mlx-community/Gone"], "Stale registration detection wrong: \(store.staleRegistrations.registrations.map(\.model))")

        let report = try ConnectionFiles.json(["result": "passed", "checks": ["Only registrations of removed services and orphaned names selected", "pi provider, overrides and default removed; user entries kept",
            "OpenCode JSONC provider, enabled list and default model cleaned", "Receipts, launchers and private profiles removed", "Original configs backed up", "Cleanup is idempotent", "Orphaned benchmark records detected by ID and name", "Model deletion selects its benchmark records", "Registrations of deleted models on a live service detected"]])
        try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
    }
}
