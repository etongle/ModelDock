import Foundation

@MainActor
enum LocalizationChecks {
    static func run() throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-localization-checks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = L10n.catalogs[.chinese] ?? [:]
        try ConnectionChecks.require(source.count > 1200, "Localization catalog was not bundled")
        func placeholders(_ value: String) -> [String] { let string = value as NSString; return L10n.placeholders.matches(in: value, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }.sorted() }
        for language in [AppLanguage.english, .french, .portuguese] {
            let entries = L10n.catalogs[language] ?? [:]
            try ConnectionChecks.require(Set(entries.keys) == Set(source.keys), "Missing translations in " + language.rawValue)
            for (key, value) in entries {
                try ConnectionChecks.require(!value.isEmpty && placeholders(key) == placeholders(value), "Translation placeholder mismatch: " + key)
                try ConnectionChecks.require(value.range(of: #"[\u3400-\u9fff]"#, options: .regularExpression) == nil, "Untranslated entry in " + language.rawValue)
            }
            L10n.select(language)
            try ConnectionChecks.require(L10n.text("下载中") != "下载中" && L10n.text("端口 8083") != "端口 8083", "Dynamic state or port not translated")
            try ConnectionChecks.require(L10n.text("http://localhost:8083/v1") == "http://localhost:8083/v1" && L10n.text("/Models/模型文件/Qwen") == "/Models/模型文件/Qwen", "Technical path/URL translated")
        }
        try ConnectionChecks.require(AppLanguage.resolve(.system, preferred: ["fr-CA"]) == .french && AppLanguage.resolve(.system, preferred: ["pt-BR"]) == .portuguese && AppLanguage.resolve(.system, preferred: ["de-DE"]) == .english, "System locale fallback wrong")
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"windowCloseBehavior":"confirmQuit"}"#.utf8))
        try ConnectionChecks.require(old.language == .english && old.windowCloseBehavior == .confirmQuit, "Legacy preferences lost close behavior or English default")
        try JSONEncoder().encode(old).write(to: root.appendingPathComponent("preferences.json"))
        let store = AppStore(stateDirectory: root)
        try ConnectionChecks.require(store.language == .english, "First launch does not default to English")
        store.language = .french
        let restored = AppStore(stateDirectory: root)
        try ConnectionChecks.require(restored.language == .french && restored.windowCloseBehavior == .confirmQuit && L10n.text("模型文件") == L10n.catalogs[.french]?["模型文件"], "Language switch failed to persist")
        try ConnectionChecks.require(DownloadState.paused.rawValue == "已暂停" && AppTab.engines.rawValue == "运行引擎", "Internationalization changed persisted identifiers")
        let translation = L10n.render("{1} before {0}", arguments: [0: "model/{1}", 1: "draft"])
        try ConnectionChecks.require(translation == "draft before model/{1}", "Reordered placeholders changed model ID")
        L10n.select(.english)
        let report: [String: Any] = ["result": "passed", "messagesPerLanguage": source.count, "languages": ["en", "zh-Hans", "fr", "pt"], "checks": ["English first-launch and legacy-settings default", "complete translation catalogs", "placeholder integrity", "regional/system fallback", "immediate language selection and persistence", "URLs, model IDs and file paths preserved", "stored enum values remain stable"]]
        try ConnectionFiles.json(report).write(to: root.appendingPathComponent("result.json")); print("Localization checks passed")
    }
}
