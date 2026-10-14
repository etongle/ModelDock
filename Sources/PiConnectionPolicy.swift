import Foundation

enum PiConnectionPolicy {
    static func output(_ context: Int) -> Int { min(8192, context / 4) }
    static func reserve(_ context: Int) -> Int { min(context / 2, output(context) + 4096) }
    static func settings(_ old: [String: Any], provider: String, model: String, context: Int) throws -> [String: Any] {
        var result = old
        var compaction = try NativeClientConfig.dictionary(result, "compaction")
        var overrides = try NativeClientConfig.dictionary(compaction, "modelOverrides")
        let key = provider + "/" + model
        var values = try NativeClientConfig.dictionary(overrides, key)
        values["reserveTokens"] = reserve(context); values["keepRecentTokens"] = min(2048, context / 4)
        overrides[key] = values; compaction["modelOverrides"] = overrides; result["compaction"] = compaction
        return result
    }
    static func thinkingSupported(engine: String, version: String?) -> Bool {
        engine == "splash" && version.map { $0.compare("1.3.1", options: .numeric) != .orderedAscending } == true
    }
}
