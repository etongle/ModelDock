import Foundation

/// A diffusion pipeline is one model; its text encoder and VAE are not chat models.
enum ImageModelPolicy {
    static let repository = "Qwen/Qwen-Image-2.1-Turbo"
    static let revision = "fc13ba1986fcb905854dc8de2f52eee395f49b5b"
    static var helper: String? { Bundle.main.resourceURL?.appendingPathComponent("image_server.py").path }
    static func isPipeline(_ folder: URL) -> Bool { jsonFile(folder.appendingPathComponent("model_index.json"))?["_class_name"] as? String == "QwenImage21Pipeline" }
    static func recognizes(_ folder: URL) -> Bool {
        guard let index = jsonFile(folder.appendingPathComponent("model_index.json")), index["_class_name"] as? String == "QwenImage21Pipeline",
              let sigmas = index["sample_sigmas"] as? [Double], sigmas.count == 8,
              sigmas.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }), zip(sigmas, sigmas.dropFirst()).allSatisfy({ $0 > $1 }) else { return false }
        return true
    }
    static func model(_ folder: URL) -> LocalModel? {
        guard isPipeline(folder) else { return nil }
        var required = ["model_index.json", "processor/tokenizer.json", "processor/tokenizer_config.json", "processor/chat_template.jinja", "processor/processor_config.json", "scheduler/scheduler_config.json", "text_encoder/config.json", "vae/config.json", "transformer/config.json", "text_encoder/model.safetensors", "vae/diffusion_pytorch_model.safetensors", "transformer/diffusion_pytorch_model.safetensors.index.json"]
        let indexPath = "transformer/diffusion_pytorch_model.safetensors.index.json"
        var invalidIndex = false
        if let index = jsonFile(folder.appendingPathComponent(indexPath)), let weights = index["weight_map"] as? [String: String], !weights.isEmpty {
            for shard in Set(weights.values).sorted() {
                if DownloadPaths.safeRelative(shard), !shard.contains("/"), shard.hasSuffix(".safetensors") { required.append("transformer/" + shard) }
                else { invalidIndex = true }
            }
        } else { invalidIndex = true }
        let missing = Array(Set(required.filter {
            let values = try? folder.appendingPathComponent($0).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile != true || (values?.fileSize ?? 0) == 0
        } + (invalidIndex ? [indexPath] : []) + (recognizes(folder) ? [] : ["model_index.json"]))).sorted()
        let bytes = Set(required).filter { $0.hasSuffix(".safetensors") }.reduce(Int64(0)) { value, file in value + Int64((try? folder.appendingPathComponent(file).resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let turbo = recognizes(folder)
        return .init(id: "image:\(folder.path)", name: ModelOrigin.displayName(folder: folder) ?? (turbo ? "Qwen-Image-2.1-Turbo" : "Qwen-Image-2.1"), format: "Diffusers · Qwen Image 2.1" + (turbo ? " Turbo" : ""), path: folder.path, kind: .image, bytes: bytes, complete: missing.isEmpty,
                     verification: missing.isEmpty ? "图片主模型、文本编码器与 VAE 齐全" : "图片生成组件不完整", missingFiles: missing, removalPath: folder.path, architecture: "qwen_image21")
    }
}
