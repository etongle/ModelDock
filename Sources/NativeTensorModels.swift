import Foundation

/// Safetensors is a container. Only advertise a raw architecture/layout that the
/// native loader supports, rather than treating every tensor file as an MLX model.
enum NativeTensorPolicy {
    static func supports(_ model: LocalModel) -> Bool {
        guard model.kind == .language, model.format == "Safetensors",
              let config = jsonFile(URL(fileURLWithPath: model.folder).appendingPathComponent("config.json")),
              config["model_type"] as? String == "qwen3",
              config["architectures"] as? [String] == ["Qwen3ForCausalLM"],
              (config["dtype"] ?? config["torch_dtype"]) as? String == "bfloat16",
              config["quantization"] == nil, config["quantization_config"] == nil,
              config["auto_map"] == nil, config["model_file"] == nil,
              config["vision_config"] == nil, config["audio_config"] == nil else { return false }
        return true
    }
}
