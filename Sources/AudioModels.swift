import Foundation

enum AudioModelPolicy {
    static var helper: String? { Bundle.main.resourceURL?.appendingPathComponent("audio_server.py").path }
    static func task(_ config: [String: Any]) -> String? {
        let type = (config["model_type"] as? String ?? "").lowercased()
        if type == "qwen3_asr" { return "asr" }
        if type == "qwen3_tts" { return "tts" }
        return nil
    }
    static func task(_ model: LocalModel) -> String? {
        guard let config = jsonFile(URL(fileURLWithPath: model.folder).appendingPathComponent("config.json")) else { return nil }
        return task(config)
    }
    static func supportsReference(_ model: LocalModel) -> Bool {
        guard let config = jsonFile(URL(fileURLWithPath: model.folder).appendingPathComponent("config.json")), task(config) == "tts" else { return false }
        return (config["tts_model_type"] as? String ?? "base") == "base"
    }
    static func missing(_ folder: URL, config: [String: Any]) -> [String]? {
        guard let task = task(config) else { return nil }
        let fm = FileManager.default
        if task == "asr" { return ["tokenizer.json", "tokenizer.model", "vocab.json"].contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) } ? [] : ["tokenizer 文件"] }
        // Qwen3-TTS Base shares its text tokenizer but also requires the bundled audio decoder.
        return ["speech_tokenizer/config.json"].filter { !fm.fileExists(atPath: folder.appendingPathComponent($0).path) } +
            (["speech_tokenizer/model.safetensors", "speech_tokenizer/model.safetensors.index.json"].contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) } ? [] : ["speech_tokenizer/model.safetensors"])
    }
}
