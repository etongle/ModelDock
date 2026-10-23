import Foundation

@MainActor enum ImageModelChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("modeldock-image-check-" + UUID().uuidString)
        let modelRoot = root.appendingPathComponent("Qwen-Image-2.1-Turbo")
        let fm = FileManager.default
        try fm.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let index: [String: Any] = ["_class_name": "QwenImage21Pipeline", "sample_sigmas": ImageModelPolicy.sigmas]
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
        try ConnectionChecks.require(Scanner.engines().filter { model.supportsEngineFormat($0) }.map(\.kind) == [.mflux], "Image model details include unrelated engines")
        let unknown = LocalModel(id: "unknown", name: "Unknown", format: "Safetensors", path: root.appendingPathComponent("unknown").path, kind: .language, bytes: 0, complete: false, verification: "", missingFiles: [], removalPath: root.appendingPathComponent("unknown").path)
        try ConnectionChecks.require(!Scanner.engines().contains { unknown.supportsEngineFormat($0) }, "Missing files fabricated engine support for an unknown format")
        let state = AppStore(stateDirectory: root.appendingPathComponent("state"))
        var installed = model
        installed.repository = ImageModelPolicy.repository
        installed.origin = .init(site: .huggingface, repository: ImageModelPolicy.repository, revision: ImageModelPolicy.revision, files: [])
        state.inventory = .init(engines: [engine], models: [installed], storageBytes: model.bytes, memoryBytes: 64_000_000_000, chip: "Fixture", roots: [root.path], warnings: [], scannedAt: Date())
        state.solutions.selectedID = "image-generation"
        try ConnectionChecks.require(SolutionCatalog.visible.map(\.id).contains("image-generation") && state.solutions.roles == [.image], "Image recipe is absent or includes audio roles")
        let selected = try state.solutions.selection(.image, draft: .init(), store: state)
        try ConnectionChecks.require(selected.modelID == installed.id && selected.engineID == "mflux", "Image recipe duplicated an installed pipeline")
        var hereticDraft = SolutionDraft(); hereticDraft.localChoices[SolutionRole.image.rawValue] = "heretic"
        let alternative = try state.solutions.selection(.image, draft: hereticDraft, store: state)
        try ConnectionChecks.require(alternative.repository == ImageModelPolicy.heretic.repository && alternative.revision == ImageModelPolicy.heretic.revision, "Image alternative is not pinned")
        var deployment = SolutionDeployment(solutionID: "image-generation", draft: .init()); deployment.components = [selected]
        state.solutions.deployments = [deployment]
        try state.solutions.configure(deployment.id, store: state)
        let serviceID = state.solutions.deployments[0].components[0].serviceID
        try state.solutions.configure(deployment.id, store: state)
        try ConnectionChecks.require(state.services.records.count == 1 && serviceID != nil && state.solutions.deployments[0].components[0].serviceID == serviceID, "Repeated image configuration duplicated service instances")
        let reused = try state.solutions.selection(.image, draft: .init(), store: state)
        try ConnectionChecks.require(reused.serviceBinding != nil && reused.serviceID == serviceID, "Compatible image service was not reused")
        let script = SolutionGatewayExamples.all(state.solutions.deployments[0], endpoint: "http://127.0.0.1:18790/solutions/fixture/v1").first { $0.id == "image" }?.script ?? ""
        try ConnectionChecks.require(script.contains("/images/generations") && script.contains("b64_json") && SolutionRole.image.gatewayModel == "image", "Image solution publishes the wrong endpoint")
        let editScript = SolutionGatewayExamples.all(state.solutions.deployments[0], endpoint: "http://127.0.0.1:18790/solutions/fixture/v1").first { $0.id == "image-to-image" }?.script ?? ""
        try ConnectionChecks.require(editScript.contains("/images/edits") && editScript.contains("image=@${MODELDOCK_IMAGE_FILE}") && editScript.contains("strength=0.75"), "Image solution lacks a usable image-to-image upload example")
        // Native MLX saves use per-component indices, not Diffusers filenames.
        for component in ["transformer", "text_encoder", "vae"] {
            try ConnectionFiles.json(["weight_map": ["weight": "0.safetensors"], "metadata": ["mflux_version": "0.23.0", "quantization_level": "None"]]).write(to: modelRoot.appendingPathComponent(component + "/model.safetensors.index.json"))
            try Data("fixture-native-weight".utf8).write(to: modelRoot.appendingPathComponent(component + "/0.safetensors"))
        }
        try ConnectionChecks.require(ImageModelPolicy.model(modelRoot)?.complete == true, "Complete Heretic-style MLX pipeline rejected")
        try fm.removeItem(at: modelRoot.appendingPathComponent("vae/0.safetensors"))
        try ConnectionChecks.require(ImageModelPolicy.model(modelRoot)?.missingFiles.contains("vae/0.safetensors") == true, "Native missing VAE shard not repairable")
        for component in ["transformer", "text_encoder", "vae"] { try fm.removeItem(at: modelRoot.appendingPathComponent(component + "/model.safetensors.index.json")) }
        try fm.removeItem(at: modelRoot.appendingPathComponent("transformer/part-2.safetensors"))
        let partial = ImageModelPolicy.model(modelRoot)!
        try ConnectionChecks.require(Scanner.engines().filter { partial.supportsEngineFormat($0) }.map(\.kind) == [.mflux], "Incomplete image pipeline displays unrelated engines or loses its repair path")
        try ConnectionChecks.require(!partial.complete && partial.missingFiles.contains("transformer/part-2.safetensors") && !partial.compatible(with: engine), "Missing image shard can still launch")
        let file = ModelFileCatalog.entries(model: partial, models: [partial]).first { $0.name == "transformer/part-2.safetensors" }
        try ConnectionChecks.require(file?.valid == false, "Missing image shard has no single-file repair entry")
        try ConnectionFiles.json(["weight_map": ["x": "../../outside.safetensors"]]).write(to: modelRoot.appendingPathComponent("transformer/diffusion_pytorch_model.safetensors.index.json"))
        try ConnectionChecks.require(ImageModelPolicy.model(modelRoot)?.complete == false, "Unsafe image shard index was accepted")
        print("Image model checks passed (fixtures; full-model inference not claimed)")
    }
}
