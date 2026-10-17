import Foundation

enum MemoryEstimateChecks {
    /// 构造只含元数据的 GGUF：值为 String（类型 8）、Int（uint32，类型 4）或 [Int]（int32 数组）。
    static func gguf(_ entries: [(String, Any)]) -> Data {
        var data = Data("GGUF".utf8)
        func int(_ value: UInt64, _ size: Int) { for index in 0..<size { data.append(UInt8((value >> (8 * UInt64(index))) & 0xff)) } }
        func string(_ value: String) { int(UInt64(value.utf8.count), 8); data.append(contentsOf: Array(value.utf8)) }
        int(3, 4); int(0, 8); int(UInt64(entries.count), 8)
        for (key, value) in entries {
            string(key)
            if let text = value as? String { int(8, 4); string(text) }
            else if let number = value as? Int { int(4, 4); int(UInt64(number), 4) }
            else if let list = value as? [Int] { int(9, 4); int(5, 4); int(UInt64(list.count), 8); list.forEach { int(UInt64(UInt32(bitPattern: Int32($0))), 4) } }
        }
        return data
    }

    static func run() throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-memory").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        func model(_ path: URL, format: String, bytes: Int64) -> LocalModel {
            LocalModel(id: path.path, name: path.lastPathComponent, format: format, path: path.path, kind: .language, bytes: bytes, complete: true, verification: "", missingFiles: [], removalPath: path.path)
        }
        let gib: Int64 = 1_073_741_824
        // 标准 GQA：32 层 × 8 个 KV 头 × (128+128) × 2 字节 × 8192 = 1 GiB。
        let dense = root.appendingPathComponent("dense.gguf")
        try gguf([("general.architecture", "llama"), ("llama.block_count", 32), ("llama.attention.head_count", 32), ("llama.attention.head_count_kv", 8), ("llama.embedding_length", 4096)]).write(to: dense)
        let estimate = MemoryEstimate.make(model: model(dense, format: "GGUF Q4_K_M", bytes: 4 * gib), context: 8192)
        try ConnectionChecks.require(estimate?.cache == gib && estimate?.weights == 4 * gib, "Dense GGUF KV estimate wrong: \(String(describing: estimate))")
        // 混合架构：按层给出的 KV 头数中 0 表示线性注意力层，不占 KV 缓存。
        let hybrid = root.appendingPathComponent("hybrid.gguf")
        try gguf([("general.architecture", "qwen35"), ("qwen35.block_count", 8), ("qwen35.attention.head_count", 16), ("qwen35.attention.head_count_kv", [0, 0, 0, 4, 0, 0, 0, 4]), ("qwen35.attention.key_length", 256), ("qwen35.attention.value_length", 256)]).write(to: hybrid)
        let shape = MemoryEstimate.gguf(hybrid)
        try ConnectionChecks.require(shape == ModelShape(attentionLayers: 2, kvHeads: 4, keyLength: 256, valueLength: 256), "Hybrid GGUF shape wrong: \(String(describing: shape))")
        // MLX：text_config 与 layer_types。
        let mlx = root.appendingPathComponent("mlx-model"); try ConnectionFiles.privateDirectory(mlx)
        try JSONSerialization.data(withJSONObject: ["model_type": "qwen3_5", "text_config": ["num_hidden_layers": 4, "num_attention_heads": 16, "num_key_value_heads": 2, "head_dim": 128,
            "layer_types": ["linear_attention", "linear_attention", "linear_attention", "full_attention"]]]).write(to: mlx.appendingPathComponent("config.json"))
        let mlxShape = MemoryEstimate.config(mlx)
        try ConnectionChecks.require(mlxShape == ModelShape(attentionLayers: 1, kvHeads: 2, keyLength: 128, valueLength: 128), "MLX shape wrong: \(String(describing: mlxShape))")
        // 判断阈值：超过物理内存 75% 为不足；在空闲内存内为充足；其余为偏紧。
        let value = MemoryEstimate(weights: 10 * gib, cache: gib, overhead: gib)
        try ConnectionChecks.require(value.level(available: UInt64(20 * gib), total: UInt64(32 * gib)) == .fits && value.level(available: UInt64(8 * gib), total: UInt64(32 * gib)) == .tight
            && value.level(available: UInt64(14 * gib), total: UInt64(15 * gib)) == .exceeds, "Memory level thresholds wrong")
        // 不是 GGUF 或缺少结构信息时只计权重，不报错。
        let broken = root.appendingPathComponent("broken.gguf"); try Data("nope".utf8).write(to: broken)
        try ConnectionChecks.require(MemoryEstimate.make(model: model(broken, format: "GGUF", bytes: gib), context: 4096).map { $0.cache == nil } == true, "Unknown shape should estimate weights only")
        // Hugging Face 搜索：解析、请求参数与下载前的内存适配判断。
        let sample = Data(#"[{"id":"unsloth/Qwen3.8-27B-GGUF","downloads":6768984,"likes":5144,"tags":["gguf","qwen3"],"pipeline_tag":null},{"modelId":"a/b","tags":["mlx"]}]"#.utf8)
        let found = try ModelSearch.parse(sample)
        try ConnectionChecks.require(found.map(\.id) == ["unsloth/Qwen3.8-27B-GGUF", "a/b"] && found[0].formats == ["GGUF"] && found[0].downloads == 6768984 && found[1].formats == ["MLX"], "Search parse wrong: \(found)")
        let url = ModelSearch.url("qwen3 coder", format: .gguf)?.absoluteString ?? ""
        try ConnectionChecks.require(url.contains("search=qwen3%20coder") && url.contains("filter=gguf") && url.contains("sort=downloads"), "Search URL wrong: \(url)")
        let memory = UInt64(64 * gib)
        try ConnectionChecks.require(ModelSearch.fit(bytes: 20 * gib, memory: memory) == .fits && ModelSearch.fit(bytes: 44 * gib, memory: memory) == .tight && ModelSearch.fit(bytes: 60 * gib, memory: memory) == .exceeds, "Download fit levels wrong")
        let report = try ConnectionFiles.json(["result": "passed", "checks": ["Dense GGUF KV cache", "Hybrid GGUF per-layer KV heads", "MLX text_config layer_types", "Fit thresholds", "Unknown metadata falls back to weights", "Hugging Face search parse and URL", "Download fit levels"]])
        try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
    }
}
