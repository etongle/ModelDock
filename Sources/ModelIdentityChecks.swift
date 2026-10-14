import Foundation

enum ModelIdentityChecks {
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = ModelOrigin(site: .huggingface, repository: "fixture/Qwen3.8-27B-4bit", revision: String(repeating: "a", count: 40), files: ["model.safetensors", "config.json", "tokenizer.json"])
        let folder = root.appendingPathComponent("hf-cache/hub/models--fixture--Qwen3.8-27B-4bit/snapshots/" + source.revision)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let config: [String: Any] = ["model_type": "qwen3_5", "text_config": ["hidden_size": 5120, "num_hidden_layers": 64, "vocab_size": 248320], "vision_config": ["hidden_size": 1280], "quantization": ["bits": 4, "group_size": 64]]
        try ConnectionFiles.json(config).write(to: folder.appendingPathComponent("config.json")); try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json")); try Data("MAIN_WEIGHT_BYTES".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        let primary = LocalModel(id: "mlx:" + folder.path, name: "Qwen3.8-27B-4bit", format: "MLX 4-bit", path: folder.path, kind: .language, bytes: 17, complete: true, verification: "权重与配置齐全", repository: source.repository, missingFiles: [], removalPath: folder.path, origin: source)
        let draftFolder = root.appendingPathComponent("hf-cache/hub/models--incoai--Qwen3.8-27B-DFlash2/snapshots/" + String(repeating: "b", count: 40))
        try fm.createDirectory(at: draftFolder, withIntermediateDirectories: true); try Data("DRAFT".utf8).write(to: draftFolder.appendingPathComponent("model.safetensors"))
        try ConnectionFiles.json(["architectures": ["DFlash2DraftModel"], "hidden_size": 5120, "num_target_layers": 64, "vocab_size": 248320, "dflash_config": [:]]).write(to: draftFolder.appendingPathComponent("config.json"))
        let assembly = root.appendingPathComponent(".resolved/assembly"); try fm.createDirectory(at: assembly, withIntermediateDirectories: true)
        var files: [String: [String: Any]] = [:]
        for (name, path) in [("target/model.safetensors", folder.appendingPathComponent("model.safetensors")), ("target/config.json", folder.appendingPathComponent("config.json")), ("tokenizer/tokenizer.json", folder.appendingPathComponent("tokenizer.json")), ("draft/config.json", draftFolder.appendingPathComponent("config.json")), ("draft/model.safetensors", draftFolder.appendingPathComponent("model.safetensors"))] {
            let target = assembly.appendingPathComponent(name); try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.createSymbolicLink(at: target, withDestinationURL: path)
            files[name] = ["path": path.path, "bytes": (try path.resourceValues(forKeys: [.fileSizeKey])).fileSize!]
        }
        try ConnectionFiles.json(["version": 1, "model": source.repository, "target_format": "mlx-affine", "vision_format": "safetensors", "sources": ["target": ["repo": source.repository, "revision": source.revision]], "files": files]).write(to: assembly.appendingPathComponent("model.json"))
        let registration = LocalModel(id: "splash-upstream:" + root.appendingPathComponent("selection").path, name: source.repository, format: "Splash 上游 mlx-affine", path: assembly.path, kind: .language, bytes: 22, complete: true, verification: "组件齐全", repository: source.repository, missingFiles: [], removalPath: assembly.path, origin: source, splashSelection: assembly.path, splashVision: "safetensors")
        var alias = registration; alias.id += "-alias"
        let merged = ModelIdentity.coalesce([primary, registration, alias])
        try ConnectionChecks.require(merged.count == 1 && merged[0].id == primary.id && merged[0].path == primary.path && merged[0].bytes == primary.bytes, "Shared main weights counted twice or primary size/path changed")
        try ConnectionChecks.require(merged[0].splashRegistrations?.count == 1 && merged[0].matchesID(alias.id) && merged[0].matchesID(registration.id), "Registration alias or identity migration lost")
        let mlx = Engine(kind: .mlx, name: "MLX", version: "fixture", path: "/usr/bin/true", installed: true, canServe: true, installation: "Fixture", description: "", defaultPort: 18110, symbol: "cpu", visionPath: "/usr/bin/true", visionVersion: "0.7.6")
        let splash = Scanner.engines().first { $0.kind == .splash }!
        try ConnectionChecks.require(merged[0].compatible(with: mlx) && merged[0].compatible(with: splash) && merged[0].exclusiveEngine == nil, "Merged model lost shared engine compatibility")
        let mlxPlan = try LaunchBuilder.plan(engine: mlx, model: merged[0], port: 18110, inputMode: .multimodal)
        let splashPlan = try LaunchBuilder.plan(engine: splash, model: merged[0], port: 18111, inputMode: .multimodal)
        try ConnectionChecks.require(mlxPlan.arguments.contains(primary.path) && splashPlan.arguments.contains(source.repository) && splashPlan.arguments.contains(source.revision) && splashPlan.arguments.contains(draftFolder.path), "Launch did not select engine-specific preparation")
        var next = primary; next.id += "-new"; next.origin?.revision = String(repeating: "c", count: 40)
        let revisions = ModelIdentity.coalesce([primary, next, registration])
        try ConnectionChecks.require(revisions.count == 2 && LocalModelVersions.related(revisions[0], models: revisions).count == 2, "Different revisions were incorrectly merged")
        let otherFolder = root.appendingPathComponent("other-quant"); try fm.createDirectory(at: otherFolder, withIntermediateDirectories: true); try Data("INDEPENDENT_8_BIT_WEIGHT".utf8).write(to: otherFolder.appendingPathComponent("model.safetensors")); try ConnectionFiles.json(config).write(to: otherFolder.appendingPathComponent("config.json"))
        var quant = primary; quant.id += "-quant"; quant.path = otherFolder.path; quant.format = "MLX 8-bit"
        try ConnectionChecks.require(ModelIdentity.coalesce([primary, quant, registration]).count == 2, "Independent quantizations were merged by repository alone")
        let entries = ModelFileCatalog.entries(model: merged[0], models: merged)
        try ConnectionChecks.require(entries.filter { $0.path == folder.appendingPathComponent("model.safetensors").path }.count == 1 && entries.contains { $0.role == "草稿组件" }, "Component files missing or main weight duplicated in file list")
        guard let draftEntry = entries.first(where: { $0.path == draftFolder.appendingPathComponent("model.safetensors").path }) else { throw LaunchError.message("Draft file missing from merged listing") }
        let (draftOrigin, _, _) = try ModelFileRepair.reference(model: merged[0], entry: draftEntry)
        try ConnectionChecks.require(draftOrigin.repository == "incoai/Qwen3.8-27B-DFlash2", "Auxiliary repair selected the main repository")
        store.inventory = .init(engines: [splash, mlx], models: merged, storageBytes: 22, memoryBytes: 0, chip: "Fixture", roots: [root.path], warnings: [], scannedAt: Date())
        store.modelAssociations[registration.id] = .init(draftMode: .local, draftPath: draftFolder.path)
        try ConnectionChecks.require(store.models[0].association?.draftPath == draftFolder.path, "Existing prepared-model association was lost")
        var active = ServiceSpec(engineID: "splash", modelID: registration.id, modelName: source.repository, modelPath: assembly.path, port: 18111); active.pid = 999999; active.commandText = "splash serve --model " + source.repository
        store.services.records = [active]; store.selectedModels["splash"] = primary.id; store.chooseEngine("splash"); store.port = "18111"
        try ConnectionChecks.require(store.currentService?.id == active.id && ModelFileSafety.used(primary, removal: folder, services: [active], external: [], models: merged), "Existing service/deletion protection lost after merge")
        let draft = LocalModel(id: draftFolder.path, name: "DFlash2", format: "DFlash2 草稿", path: draftFolder.path, kind: .draft, bytes: 5, complete: true, verification: "", repository: "incoai/Qwen3.8-27B-DFlash2", missingFiles: [], removalPath: draftFolder.path)
        try ConnectionChecks.require(ModelFileSafety.used(draft, removal: draftFolder, services: [active], external: [], models: merged), "Shared auxiliary protection lost after deduplication")
        store.showModelFile(store.models[0]); try await capture?("single-model-with-components"); store.services.records = []
        let actual = Scanner.scan()
        let repositories = ["mlx-community/Qwen3.8-27B-4bit", "Jiunsong/SuperQwen3.8-27b-abliterated-MLX-4bit"]
        var counts: [String: Int] = [:]
        for repository in repositories {
            let matching = actual.models.filter { $0.origin?.repository == repository && $0.kind == .language }
            counts[repository] = matching.count
            try ConnectionChecks.require(matching.count == 1 && matching[0].splashRegistrations?.isEmpty == false, "Actual downloaded model still duplicated: " + repository)
        }
        let report: [String: Any] = ["result": "passed", "actualModelCounts": counts, "checks": ["same source revision and physical weight identity coalesced", "selection aliases merged", "different revision and independent quantizations retained", "MLX and Splash launch correctly from one entry", "helper listing and repair use helper repository", "saved associations and active service identity retained", "shared weights and draft deletion protected"]]
        try ConnectionFiles.json(report).write(to: root.appendingPathComponent("result.json")); print(root.path)
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-identity-checks").appendingPathComponent(UUID().uuidString)
        try await exercise(store: AppStore(stateDirectory: root.appendingPathComponent("state")), root: root)
    }
}
