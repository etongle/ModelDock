import Foundation

/// A diffusion pipeline is one model; its text encoder and VAE are not chat models.
enum ImageModelPolicy {
    static let repository = "Qwen/Qwen-Image-2.1-Turbo"
    static let revision = "fc13ba1986fcb905854dc8de2f52eee395f49b5b"
    static var helper: String? { Bundle.main.resourceURL?.appendingPathComponent("image_server.py").path }
    static func isPipeline(_ folder: URL) -> Bool { jsonFile(folder.appendingPathComponent("model_index.json"))?["_class_name"] as? String == "QwenImage21Pipeline" }
    static let sigmas = [1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568]
    static let heretic = SolutionModel(repository: "vanch007/Qwen-Image-2.1-Turbo-Heretic-mlx-bf16", revision: "1ac68b7ede726b22ea3ace1fa6f03062450e4649")
    static func recognizes(_ folder: URL) -> Bool {
        guard isPipeline(folder), let values = jsonFile(folder.appendingPathComponent("model_index.json"))?["sample_sigmas"] as? [Double], values.count == sigmas.count else { return false }
        return zip(values, sigmas).allSatisfy { $0.isFinite && abs($0 - $1) < 0.000001 }
    }
    static func requiredFiles(_ folder: URL) -> [String] {
        var files = ["model_index.json", "processor/tokenizer.json", "processor/tokenizer_config.json", "processor/chat_template.jinja", "scheduler/scheduler_config.json", "text_encoder/config.json", "vae/config.json", "transformer/config.json"]
        files.append(FileManager.default.fileExists(atPath: folder.appendingPathComponent("processor/preprocessor_config.json").path) ? "processor/preprocessor_config.json" : "processor/processor_config.json")
        for (component, single) in [("transformer", "diffusion_pytorch_model.safetensors"), ("text_encoder", "model.safetensors"), ("vae", "diffusion_pytorch_model.safetensors")] {
            let native = component + "/model.safetensors.index.json", hf = component + "/diffusion_pytorch_model.safetensors.index.json"
            let index = FileManager.default.fileExists(atPath: folder.appendingPathComponent(native).path) ? native : hf
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(index).path) || component == "transformer" {
                files.append(index)
                if let map = jsonFile(folder.appendingPathComponent(index))?["weight_map"] as? [String: String], !map.isEmpty,
                   map.values.allSatisfy({ DownloadPaths.safeRelative($0) && !$0.contains("/") && $0.hasSuffix(".safetensors") }) {
                    files += Set(map.values).sorted().map { component + "/" + $0 }
                } else { /* invalid index is reported below using its real filename */ }
            } else { files.append(component + "/" + single) }
        }
        return Array(Set(files)).sorted()
    }
    static func invalidIndices(_ folder: URL) -> [String] {
        ["transformer", "text_encoder", "vae"].flatMap { component -> [String] in
            ["model.safetensors.index.json", "diffusion_pytorch_model.safetensors.index.json"].compactMap { name in
                let path = component + "/" + name
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) else { return nil }
                guard let map = jsonFile(folder.appendingPathComponent(path))?["weight_map"] as? [String: String], !map.isEmpty,
                      map.values.allSatisfy({ DownloadPaths.safeRelative($0) && !$0.contains("/") && $0.hasSuffix(".safetensors") }) else { return path }
                return nil
            }
        }
    }
    static func model(_ folder: URL) -> LocalModel? {
        guard isPipeline(folder) else { return nil }
        let required = requiredFiles(folder)
        let missing = Array(Set(required.filter {
            let values = try? folder.appendingPathComponent($0).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile != true || (values?.fileSize ?? 0) == 0
        } + invalidIndices(folder) + (recognizes(folder) ? [] : ["model_index.json"]))).sorted()
        let bytes = Set(required).filter { $0.hasSuffix(".safetensors") }.reduce(Int64(0)) { value, file in value + Int64((try? folder.appendingPathComponent(file).resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let turbo = recognizes(folder)
        return .init(id: "image:\(folder.path)", name: ModelOrigin.displayName(folder: folder) ?? (turbo ? "Qwen-Image-2.1-Turbo" : "Qwen-Image-2.1"), format: (FileManager.default.fileExists(atPath: folder.appendingPathComponent("transformer/model.safetensors.index.json").path) ? "MLX" : "Diffusers") + " · Qwen Image 2.1" + (turbo ? " Turbo" : ""), path: folder.path, kind: .image, bytes: bytes, complete: missing.isEmpty,
                     verification: missing.isEmpty ? "图片主模型、文本编码器与 VAE 齐全" : "图片生成组件不完整", missingFiles: missing, removalPath: folder.path, architecture: "qwen_image21")
    }
}
