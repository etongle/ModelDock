import Foundation

@MainActor enum ImageModelChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("modeldock-image-check-" + UUID().uuidString)
        let modelRoot = root.appendingPathComponent("Qwen-Image-2.1-Turbo")
        let fm = FileManager.default
        try fm.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let index: [String: Any] = ["_class_name": "QwenImage21Pipeline", "sample_sigmas": [1.0, 0.98, 0.96, 0.94, 0.90, 0.80, 0.70, 0.4]]
        try ConnectionFiles.json(index).write(to: modelRoot.appendingPathComponent("model_index.json"))
        for path in ["processor/tokenizer.json", "processor/tokenizer_config.json", "processor/chat_template.jinja", "processor/processor_config.json", "scheduler/scheduler_config.json", "text_encoder/config.json", "text_encoder/model.safetensors", "transformer/config.json", "transformer/part-1.safetensors", "transformer/part-2.safetensors", "vae/config.json", "vae/diffusion_pytorch_model.safetensors"] {
            let url = modelRoot.appendingPathComponent(path); try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("fixture".utf8).write(to: url)
        }
        let weights: [String: Any] = ["weight_map": ["layer.1": "part-1.safetensors", "layer.2": "part-2.safetensors"]]
        try ConnectionFiles.json(weights).write(to: modelRoot.appendingPathComponent("transformer/diffusion_pytorch_model.safetensors.index.json"))
        guard let model = ImageModelPolicy.model(modelRoot) else { throw LaunchError.message("Image pipeline was not recognized") }
        try ConnectionChecks.require(model.complete && model.kind == .image, "Complete image components are not classified as image generation")
        let inventory = Scanner.scan(extraRoots: [root.path])
        let found = inventory.models.filter { $0.path.contains("/" + root.lastPathComponent + "/") }
        try ConnectionChecks.require(found.count == 1 && found[0].kind == .image, "Image inventory mismatch: root=\(root.path), matches=\(found.map { $0.kind.rawValue + ":" + $0.path }), scannedRoots=\(inventory.roots), warnings=\(inventory.warnings.filter { $0.contains(root.lastPathComponent) })")
        var engine = Scanner.engines().first { $0.kind == .mflux }!
        engine.path = "/usr/bin/true"; engine.installed = true; engine.canServe = true
        let plan = try LaunchBuilder.plan(engine: engine, model: model, port: 28100)
        try ConnectionChecks.require(plan.arguments.contains(model.path) && plan.environment["HF_HUB_OFFLINE"] == "1" && plan.environment["TRANSFORMERS_OFFLINE"] == "1", "Image launch does not use offline local snapshot")
        try ConnectionChecks.require(ModalityPolicy.local(model).outputs == ["image"] && !model.compatible(with: Scanner.engines().first { $0.kind == .mlx }!), "Image model was offered as a chat model")
        try fm.removeItem(at: modelRoot.appendingPathComponent("transformer/part-2.safetensors"))
        let partial = ImageModelPolicy.model(modelRoot)!
        try ConnectionChecks.require(!partial.complete && partial.missingFiles.contains("transformer/part-2.safetensors") && !partial.compatible(with: engine), "Missing image shard can still launch")
        let file = ModelFileCatalog.entries(model: partial, models: [partial]).first { $0.name == "transformer/part-2.safetensors" }
        try ConnectionChecks.require(file?.valid == false, "Missing image shard has no single-file repair entry")
        try ConnectionFiles.json(["weight_map": ["x": "../../outside.safetensors"]]).write(to: modelRoot.appendingPathComponent("transformer/diffusion_pytorch_model.safetensors.index.json"))
        try ConnectionChecks.require(ImageModelPolicy.model(modelRoot)?.complete == false, "Unsafe image shard index was accepted")
        print("Image model checks passed (fixtures; full-model inference not claimed)")
    }
}
