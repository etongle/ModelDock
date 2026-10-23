import Foundation

@MainActor enum NativeTensorChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-tensor-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config: [String: Any] = ["model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"], "dtype": "bfloat16"]
        let file = root.appendingPathComponent("config.json")
        try ConnectionFiles.json(config).write(to: file)
        var model = LocalModel(id: "fixture", name: "Unrelated display name", format: "Safetensors", path: root.path, kind: .language, bytes: 16, complete: true, verification: "fixture", missingFiles: [], removalPath: root.path)
        var engine = Engine(kind: .mlx, name: "MLX", version: "0.32.0", path: "/usr/bin/true", installed: true, canServe: true, installation: "fixture", description: "", defaultPort: 28110, symbol: "cpu")
        try ConnectionChecks.require(NativeTensorPolicy.supports(model) && model.compatible(with: engine), "Raw Qwen3 BF16 was incorrectly excluded")
        let plan = try LaunchBuilder.plan(engine: engine, model: model, port: 28110)
        try ConnectionChecks.require(plan.arguments.contains(root.path) && plan.executable == "/usr/bin/true" && ModalityPolicy.local(model).inputs == ["text"], "Native Qwen3 did not retain its original path or text modality")
        model.complete = false
        try ConnectionChecks.require(model.supportsEngineFormat(engine) && model.compatibility(with: engine).level == .incomplete, "Missing-file readiness masked relevant architecture support")
        model.complete = true; engine.version = "0.31.0"
        do { _ = try LaunchBuilder.plan(engine: engine, model: model, port: 28110); throw LaunchError.message("Old native runtime was accepted") }
        catch { try ConnectionChecks.require(error.localizedDescription.contains("0.32.0"), "Old runtime did not explain required update") }
        for changes in [["model_type": "unsupported"], ["architectures": ["Qwen3ForEmbedding"]], ["quantization_config": ["quant_method": "gptq"]], ["auto_map": ["AutoModel": "remote.Code"]], ["dtype": "int8"], ["vision_config": [:]]] as [[String: Any]] {
            try ConnectionFiles.json(config.merging(changes) { _, new in new }).write(to: file)
            try ConnectionChecks.require(!NativeTensorPolicy.supports(model), "Unverified raw architecture, quantization or custom code was advertised as compatible")
        }
        print("Native tensor checks passed (metadata/launch fixtures; local inference checked separately)")
    }
}
