import Foundation

@MainActor enum SolutionRecommendationChecks {
    static func run(_ store: AppStore, fixture: EngineServiceChecks.Fixture) throws {
        let inventory = store.inventory, drafts = store.solutions.drafts, selectedID = store.solutions.selectedID
        defer { store.inventory = inventory; store.solutions.drafts = drafts; store.solutions.selectedID = selectedID }
        func require(_ condition: Bool, _ message: String) throws { try ConnectionChecks.require(condition, message) }
        let folder = fixture.root.appendingPathComponent("recommendation-baseline")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ConnectionFiles.json(["model_type": "qwen3_5", "vision_config": [:]]).write(to: folder.appendingPathComponent("config.json"))
        var translator = fixture.model
        translator.name = "Confucius4-T3PO"; translator.repository = "netease-youdao/Confucius4-T3PO"
        let baseline = LocalModel(id: "baseline-mlx", name: "Qwen3.8-27B-4bit", format: "MLX 4-bit", path: folder.path, kind: .language, bytes: 16_000_000_000, complete: true, verification: "fixture", repository: SolutionRecommendations.baseline.repository, missingFiles: [], removalPath: folder.path, origin: .init(site: .huggingface, repository: SolutionRecommendations.baseline.repository, revision: SolutionRecommendations.baseline.revision, files: []))
        let mlx = Engine(kind: .mlx, name: "MLX", version: "fixture", path: "/usr/bin/true", installed: true, canServe: true, installation: "fixture", description: "fixture", defaultPort: 8081, symbol: "cpu", visionPath: "/usr/bin/true")
        store.inventory?.engines.append(mlx)
        store.inventory?.models = [translator, baseline]
        let solutions = store.solutions
        for role in [SolutionRole.chat, .text, .vision] {
            let result = try solutions.selection(role, draft: .init(), store: store)
            try require(result.modelID == baseline.id && result.modelPath == baseline.path, "Installed Qwen3.8 was not reused for " + role.rawValue)
            try require(SolutionCatalog.model(role, quality: .balanced) == SolutionRecommendations.baseline, "Default recipe fell below Qwen3.8")
        }
        try require(store.modelInstanceCounts(translator, engineID: "llama").running > 0, "Translation-priority regression fixture is not running")
        try require(solutions.choices(.chat, store: store).first?.model.id == baseline.id, "Running translator outranked the Qwen3.8 baseline")
        var manual = SolutionDraft(); manual.localChoices[SolutionRole.chat.rawValue] = "llama\n" + translator.id
        try require(try solutions.selection(.chat, draft: manual, store: store).modelID == translator.id, "Explicit model choice was changed")
        var lighter = SolutionDraft(); lighter.localChoices[SolutionRole.chat.rawValue] = SolutionRecommendations.lightweightChoice
        let light = try solutions.selection(.chat, draft: lighter, store: store)
        try require(light.modelID == nil && light.repository == "mlx-community/Qwen3.5-4B-4bit", "Explicit lightweight option was ignored")
        var download = SolutionDraft(); download.localChoices[SolutionRole.vision.rawValue] = "download"
        try require(try solutions.selection(.vision, draft: download, store: store).modelID == nil, "Explicit download reused a local model")
        var gguf = translator; gguf.id = "baseline-gguf"; gguf.repository = nil; gguf.path = fixture.root.appendingPathComponent("Qwen3.8-27B-Q8_0.gguf").path
        try require(SolutionRecommendations.matches(gguf, role: .chat, draft: .init()), "Standard GGUF quantization was not recognized")
        for name in ["Qwen3-4B-4bit", "Qwen3.5-27B-4bit", "Qwen3-Coder-Next-4bit", "SuperQwen3.8-27B", "Qwen3.8-27B-DFlash2", "Qwen3.8-27B-2bit", "Qwen3.8-27B-MTP-4bit"] {
            var other = baseline; other.origin = nil; other.repository = "example/" + name
            try require(!SolutionRecommendations.matches(other, role: .chat, draft: .init()), "Unverified upgrade or auxiliary model was recommended: " + name)
        }
        var incomplete = baseline; incomplete.complete = false
        store.inventory?.models = [translator, incomplete]
        let fallback = try solutions.selection(.chat, draft: .init(), store: store)
        try require(fallback.modelID == nil && fallback.repository == SolutionRecommendations.baseline.repository, "Incomplete baseline silently selected the translator")
        store.inventory?.models = [translator, gguf]
        try require(try solutions.selection(.vision, draft: .init(), store: store).modelID == nil, "Text-only baseline was reused for vision without a projector")
        var foreign = baseline; foreign.origin?.repository = "netease-youdao/Confucius4-T3PO"
        try require(!SolutionRecommendations.matches(foreign, role: .chat, draft: .init()), "Display name overrode source provenance")
        let legacy = SolutionComponent(role: .chat, engineID: "llama", modelID: translator.id, modelPath: translator.path, repository: translator.repository!, revision: "")
        try require(!SolutionRecommendations.isCurrent(legacy, draft: .init()) && SolutionRecommendations.isCurrent(legacy, draft: manual), "Old automatic recommendations were mistaken for current ones or explicit choices were invalidated")
        try ConnectionFiles.json(["result": "passed", "checks": ["installed Qwen3.8 reused for coding/translation/vision", "running translation model cannot displace baseline", "explicit manual and lightweight options preserved", "standard GGUF recognized", "incomplete or text-only models not silently reused", "no upgrade inference from parameter count or finetune name"]]).write(to: fixture.root.appendingPathComponent("recommendations.json"))
    }
}
