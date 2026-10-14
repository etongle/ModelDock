import Foundation
import CryptoKit

enum ReleaseChecks {
    @MainActor static var liveStore: AppStore?
    @MainActor static func startAssociated() async throws {
        guard let path = argumentValue("--launch-associated-test"), let folder = argumentValue("--state-dir"), let port = argumentValue("--launch-port").flatMap(Int.init) else { throw LaunchError.message("Isolated state, model and test port required") }
        let store = AppStore(stateDirectory: URL(fileURLWithPath: folder))
        guard store.services.records.isEmpty else { throw LaunchError.message("Test state must be empty") }
        store.inventory = await Task.detached { Scanner.scan() }.value
        guard let model = store.models.first(where: { $0.path == path }), var engine = store.engines.first(where: { $0.kind == .mlx }) else { throw LaunchError.message("Test model/runtime missing") }
        let runtimeRoot = Scanner.home.appendingPathComponent("Library/Application Support/ModelManager/engines")
        guard let vision = EnginePaths.manifest(.mlx, root: runtimeRoot, record: "vision.json") else { throw LaunchError.message("Installed vision runtime missing") }
        engine.visionPath = runtimeRoot.appendingPathComponent("mlx").appendingPathComponent(vision.executable).path
        engine.visionVersion = vision.version; engine.path = engine.visionPath!; engine.canServe = true
        let spec = try store.services.start(engine: engine, model: model, port: port, context: 32768, inputMode: .multimodal)
        liveStore = store; store.services.beginMonitoring(); print("Associated test service: " + spec.id)
    }
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("project"), home = root.appendingPathComponent("home")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let target = ConnectionTarget(id: "native-fixture", engineName: "Strata", engineID: "strata", model: "fixture/vision", port: 18091, pid: 0, birth: 0, context: 32768, capabilities: .init(inputs: ["text", "image"], outputs: ["text"], known: true, source: "fixture"))
        var exports: [ClientConnection] = []
        for client in [CodingClient.opencode, .pi] {
            let folder = home.appendingPathComponent(client == .pi ? ".pi/agent" : ".config/opencode")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let native = folder.appendingPathComponent(client == .pi ? "models.json" : "opencode.jsonc")
            let original = Data((client == .pi ? #"{"providers":{"existing":{"apiKey":"keep","models":[{"id":"cloud-model"}]}},"custom":true}"# : "{\n// Keep user settings\n\"model\":\"cloud/default\",\"provider\":{\"existing\":{\"options\":{\"apiKey\":\"keep\"}}},\"permission\":{\"bash\":\"ask\"},\"custom\":true,\n}").utf8)
            try original.write(to: native)
            if client == .pi { try ConnectionFiles.json(["theme": "custom", "defaultModel": "cloud-model", "compaction": ["enabled": false, "reserveTokens": 16384, "modelOverrides": ["existing/cloud-model": ["reserveTokens": 20000]]]]).write(to: folder.appendingPathComponent("settings.json")) }
            var connection = try ConnectionFiles.prepare(client: client, target: target, context: 32768, executable: "/usr/bin/true", project: project.path, root: root.appendingPathComponent("connections"), guardExecutable: nil, webSearch: true)
            let registration = try NativeClientConfig.register(connection, root: root.appendingPathComponent("connections"), home: home, webSearch: true)
            connection.registeredConfiguration = registration.configuration.path; exports.append(connection)
            let merged = try NativeClientConfig.object(Data(contentsOf: native))
            try ConnectionChecks.require(merged["custom"] as? Bool == true && (merged[client == .pi ? "providers" : "provider"] as? [String: Any])?["existing"] != nil, "Existing native providers/settings were lost")
            let backupData = try Data(contentsOf: registration.backups.appendingPathComponent(native.lastPathComponent + ".backup"))
            try ConnectionChecks.require(backupData == original, "Exact original config was not backed up")
            if client == .opencode { try ConnectionChecks.require(merged["model"] as? String == "cloud/default" && (merged["permission"] as? [String: Any])?["bash"] as? String == "ask", "Default or shell permissions were changed") }
            else { let mcp = try NativeClientConfig.object(Data(contentsOf: folder.appendingPathComponent("mcp.json"))); try ConnectionChecks.require((mcp["mcpServers"] as? [String: Any])?[WebSearchConnection.name] != nil, "Native pi search MCP missing") }
            var next = target; next.model = "fixture/text"; next.id = "second"
            let second = try ConnectionFiles.prepare(client: client, target: next, context: 32768, executable: "/usr/bin/true", project: project.path, root: root.appendingPathComponent("connections"), guardExecutable: nil)
            _ = try NativeClientConfig.register(second, root: root.appendingPathComponent("connections"), home: home)
            let updated = try NativeClientConfig.object(Data(contentsOf: native)), provider = (updated[client == .pi ? "providers" : "provider"] as? [String: Any])?[target.providerID] as? [String: Any]
            try ConnectionChecks.require(client == .pi ? (provider?["models"] as? [[String: Any]])?.count == 2 : (provider?["models"] as? [String: Any])?.count == 2, "Registering second model removed first")
            if client == .pi {
                let settings = try NativeClientConfig.object(Data(contentsOf: folder.appendingPathComponent("settings.json"))), compaction = settings["compaction"] as? [String: Any], overrides = compaction?["modelOverrides"] as? [String: [String: Int]]
                try ConnectionChecks.require(settings["theme"] as? String == "custom" && settings["defaultModel"] as? String == "cloud-model" && compaction?["enabled"] as? Bool == false && overrides?["existing/cloud-model"]?["reserveTokens"] == 20000, "Native pi user settings changed")
                try ConnectionChecks.require(overrides?[target.providerID + "/" + target.model]?["reserveTokens"] == 12288 && overrides?[target.providerID + "/fixture/text"]?["keepRecentTokens"] == 2048, "Native pi model-specific compaction budgets missing")
            }
        }
        try JSONEncoder().encode(exports).write(to: root.appendingPathComponent("native-exports.json"))
        try ConnectionChecks.require(ModelCatalog.normalizedAddress(" incoai/Qwen3.8-27B-DFlash2 ") == "https://huggingface.co/incoai/Qwen3.8-27B-DFlash2", "HF short name failed")

        let mainFolder = root.appendingPathComponent("models/Qwen3.8-27B-4bit"), draftFolder = root.appendingPathComponent("models/Qwen3.8-27B-DFlash2")
        for folder in [mainFolder, draftFolder] { try fm.createDirectory(at: folder, withIntermediateDirectories: true); try Data("fixture-weights".utf8).write(to: folder.appendingPathComponent("model.safetensors")) }
        let config: [String: Any] = ["model_type": "qwen3_5", "text_config": ["hidden_size": 5120, "num_hidden_layers": 64, "vocab_size": 248320], "vision_config": ["hidden_size": 1280], "quantization": ["bits": 4, "group_size": 64]]
        let draftConfig: [String: Any] = ["architectures": ["DFlash2DraftModel"], "model_type": "qwen3", "hidden_size": 5120, "num_target_layers": 64, "vocab_size": 248320, "dflash_config": ["target_layer_ids": [5,19,33,47,61]]]
        try ConnectionFiles.json(config).write(to: mainFolder.appendingPathComponent("config.json")); try ConnectionFiles.json(draftConfig).write(to: draftFolder.appendingPathComponent("config.json")); try Data("{}".utf8).write(to: mainFolder.appendingPathComponent("tokenizer.json"))
        let scanned = Scanner.scan(extraRoots: [root.appendingPathComponent("models").path])
        guard var main = scanned.models.first(where: { $0.path == mainFolder.path }), let draft = scanned.models.first(where: { $0.path == draftFolder.path }) else { throw LaunchError.message("Fixture models not found") }
        try ConnectionChecks.require(draft.kind == .draft && draft.complete && draft.missingFiles.isEmpty && !ModelFileCatalog.entries(model: draft, models: [main,draft]).contains(where: { !$0.valid }), "Draft tokenizer false positive remains")
        let executable = root.appendingPathComponent("mlx_vlm.server"); try ConnectionFiles.write(Data(contentsOf: URL(fileURLWithPath: fm.currentDirectoryPath + "/Tests/modality_fixture.py")), to: executable, executable: true)
        var engine = Engine(kind: .mlx, name: "MLX · LM / VLM", version: "0.32.0", path: executable.path, installed: true, canServe: true, installation: "Fixture", description: "", defaultPort: 18100, symbol: "cpu", visionPath: executable.path, visionVersion: "0.7.6")
        main.association = .init(draftMode: .local, draftPath: draft.path)
        let plan = try LaunchBuilder.plan(engine: engine, model: main, port: 18100, context: 32768, inputMode: .multimodal)
        try ConnectionChecks.require(plan.arguments.contains(draft.path) && plan.arguments.contains("dflash") && plan.arguments.contains("--draft-model"), "Associated draft not in VLM launch")
        var wrong = main; let badFolder = root.appendingPathComponent("bad"); try fm.createDirectory(at: badFolder, withIntermediateDirectories: true)
        var badConfig = draftConfig; badConfig["hidden_size"] = 4096; try ConnectionFiles.json(badConfig).write(to: badFolder.appendingPathComponent("config.json")); try Data("bad".utf8).write(to: badFolder.appendingPathComponent("model.safetensors"))
        wrong.association = .init(draftMode: .local, draftPath: badFolder.path)
        do { _ = try LaunchBuilder.plan(engine: engine, model: wrong, port: 18100, inputMode: .multimodal); throw LaunchError.message("Mismatched draft accepted") } catch LaunchError.message(let text) where text.contains("不匹配") { }
        let port = try EnginePortPolicy.available(engine: engine, base: 18831, count: 1, occupied: { NetworkProbe.portOccupied($0) })[0]
        let spec = try store.services.start(engine: engine, model: main, port: port, context: 32768, inputMode: .multimodal)
        defer { try? store.services.stop(spec) }
        for _ in 0..<80 { await store.services.refresh(); if store.services.status(spec) == .running { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        try ConnectionChecks.require(store.services.status(spec) == .running, "Component fixture service not ready")
        store.inventory = Inventory(engines: [engine] + scanned.engines.filter { $0.kind != .mlx }, models: [main,draft], storageBytes: 0, memoryBytes: 0, chip: "Fixture", roots: [root.path], warnings: [], scannedAt: Date())
        store.modelAssociations[main.id] = main.association
        store.showService(spec)
        store.connections.present(port: port, targets: store.connectionTargets)
        for _ in 0..<80 { if !store.connections.discovering { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        try await capture?("native-client-registration-preview"); store.connections.draft = nil
        try ConnectionChecks.require(spec.draftModelPath == draft.path && spec.launchArguments == plan.arguments.map { $0 == "18100" ? String(port) : $0 }, "Service did not pin actual arguments")
        let changed = ModelAssociationDraft(model: main); changed.mode = .disabled; store.saveAssociation(changed); store.message = nil
        try ConnectionChecks.require(store.models.first?.association?.draftMode == .disabled && store.services.records.first?.draftModelPath == draft.path, "Association edits changed active service")
        try ConnectionChecks.require(ModelFileSafety.used(draft, removal: draftFolder, services: store.services.records, external: [], models: store.models), "Active draft was deletable")
        store.chooseEngine("mlx"); store.setEngineEnabled("mlx", enabled: false)
        try ConnectionChecks.require(!store.enabledEngines.contains(where: { $0.id == "mlx" }) && store.services.records.first?.pid == spec.pid && !store.directConnectionTargets.contains(where: { $0.engineID == "mlx" }), "Disabled engine visible or active service modified")
        store.showGlobalEngines = true; try await capture?("global-engines-preview"); store.showGlobalEngines = false
        store.setEngineEnabled("mlx", enabled: true); engine.launchSettings = .init(enabled: false)
        do { _ = try LaunchBuilder.plan(engine: engine, model: main, port: 18100); throw LaunchError.message("Disabled engine launched") } catch LaunchError.message(let text) where text.contains("停用") { }
        let reopened = AppStore(stateDirectory: store.services.stateDirectory)
        try ConnectionChecks.require(reopened.modelAssociations[main.id]?.draftMode == .disabled && reopened.engineEnabled("mlx"), "Saved configuration did not persist")
        store.prepareAssociation(main); try await capture?("model-association-preview"); store.associationDraft = nil
        store.prepareEngineConfiguration(store.engines.first { $0.id == "mlx" }); try await capture?("engine-configuration-preview"); store.engineConfigurationDraft = nil
        store.showModelFile(draft); try await capture?("draft-model-files")
        store.tab = .engines; store.chooseEngine("strata"); try await capture?("strata-integration")

        let repairFolder = root.appendingPathComponent("repair"), untouched = repairFolder.appendingPathComponent("other.safetensors")
        try fm.createDirectory(at: repairFolder, withIntermediateDirectories: true); try Data("KEEP_OTHER_WEIGHT".utf8).write(to: untouched)
        let missing = repairFolder.appendingPathComponent("config.json")
        let file = RemoteFile(path: "config.json", url: URL(string: "https://download-fixture.invalid/range/config.json")!, bytes: Int64(DownloadHTTPFixture.config.count), sha256: SHA256.hash(data: DownloadHTTPFixture.config).map { String(format: "%02x", $0) }.joined())
        store.downloads.transferProtocolClasses = [DownloadHTTPFixture.self]
        let repair = try store.downloads.createRepair(file: file, source: .init(site: .huggingface, repository: "fixture/main", revision: String(repeating: "a", count: 40), files: [file.path]), target: missing, modelID: "repair-fixture")
        for _ in 0..<300 { if store.downloads.activeID == nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        try ConnectionChecks.require(store.downloads.jobs.first(where: { $0.id == repair.id })?.state == .complete && (try? Data(contentsOf: missing)) == DownloadHTTPFixture.config && (try? Data(contentsOf: untouched)) == Data("KEEP_OTHER_WEIGHT".utf8), "Single-file repair failed or touched other weights")
        var race = repair; race.id = UUID().uuidString; race.repairFingerprint = try RepairFingerprint.read(missing); race.finished = [file.path]
        try Data("concurrent-change".utf8).write(to: missing)
        do { try ModelFileRepair.publish(race); throw LaunchError.message("Concurrent file replacement accepted") } catch LaunchError.message(let text) where text.contains("改变") { }
        store.tab = .downloads; store.downloads.selectedTaskID = repair.id; try await capture?("single-file-repair")
        let compiled = root.appendingPathComponent("llama.cpp-prism/build"); try fm.createDirectory(at: compiled, withIntermediateDirectories: true)
        let removal = RemovalItem(path: compiled.path, group: .executable, note: "本地构建", bytes: 0, identity: FileIdentity.read(compiled.path)!, formula: nil)
        var unrelated = repair; unrelated.state = .downloading; unrelated.repairTarget = nil
        try ConnectionChecks.require(EngineMaintenance.downloadBlockers([removal], jobs: [unrelated]).isEmpty, "Unrelated download blocked local engine uninstall")
        unrelated.root = compiled.path; unrelated.folder = "models/test"
        try ConnectionChecks.require(!EngineMaintenance.downloadBlockers([removal], jobs: [unrelated]).isEmpty, "Download in selected build directory was not protected")
        try ConnectionChecks.require(EngineMaintenance.downloadBlockers([], jobs: [unrelated]).isEmpty, "Unselected directory blocked uninstall")
        store.tab = .engines; store.engineID = "prism"
        let prism = store.engines.first { $0.kind == .prism }!
        store.maintenanceSelection = [removal.id]; store.maintenancePlan = .init(engine: prism, mode: .uninstall, items: [removal], preserved: [root.appendingPathComponent("llama.cpp-prism").path + "（源码保留）"], notes: [], blockers: [])
        var activePreview = repair; activePreview.id = UUID().uuidString; activePreview.repairTarget = nil
        store.downloads.jobs.insert(activePreview, at: 0); store.downloads.jobs[0].state = .downloading
        try await capture?("local-build-uninstall-preview"); store.downloads.jobs[0].state = .complete; store.maintenancePlan = nil
        let report: [String: Any] = ["result": "passed", "root": root.path, "checks": ["native pi/OpenCode registration, exact backups and provider merging", "optional native Exa MCP configuration", "Hugging Face short identifiers", "DFlash classification without phantom tokenizer", "associated VLM draft, incompatible draft blocked", "actual service pins components and protects deletion", "global engine visibility, gateway filtering and persistence", "single-file SHA-verified atomic repair, other weights unchanged", "concurrent target mutation blocks repair"]]
        try ConnectionFiles.json(report).write(to: root.appendingPathComponent("result.json")); print(root.path)
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--checks-dir") ?? "/private/tmp/model-manager-release-checks").appendingPathComponent(UUID().uuidString)
        try await exercise(store: AppStore(stateDirectory: root.appendingPathComponent("state")), root: root)
    }
}
