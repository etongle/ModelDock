import Foundation

/// Stable language identifiers; the default is English even on a Chinese system.
enum AppLanguage: String, Codable, CaseIterable {
    case english = "en", chinese = "zh-Hans", french = "fr", portuguese = "pt", system = "system"
    var name: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        case .french: return "Français"
        case .portuguese: return "Português"
        case .system: return L10n.text("跟随系统")
        }
    }
    static func resolve(_ language: AppLanguage, preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard language == .system else { return language }
        for code in preferred {
            if code.hasPrefix("en") { return .english }
            if code.hasPrefix("zh") { return .chinese }
            if code.hasPrefix("fr") { return .french }
            if code.hasPrefix("pt") { return .portuguese }
        }
        return .english
    }
}

/// Localization happens at presentation boundaries. Persisted enum values,
/// executable arguments, model IDs and paths keep their original representation.
enum L10n {
    private struct Pattern { var key: String; var regex: NSRegularExpression; var indices: [Int] }
    private static let lock = NSLock()
    private static var language: AppLanguage = .english
    private static let cache = NSCache<NSString, NSString>()
    static let placeholders = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    private static let chinese = try! NSRegularExpression(pattern: #"[\u3400-\u9fff]"#)
    static let catalogs: [AppLanguage: [String: String]] = {
        var result: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases where language != .system {
            if let url = Bundle.main.url(forResource: language.rawValue, withExtension: "json", subdirectory: "Localization"),
               let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([String: String].self, from: data) { result[language] = entries }
        }
        return result
    }()
    private static let patterns: [Pattern] = {
        (catalogs[.chinese] ?? [:]).keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key in
            let source = key as NSString, matches = placeholders.matches(in: key, range: NSRange(location: 0, length: source.length))
            var expression = "^", start = 0, indices: [Int] = []
            for match in matches {
                expression += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: start, length: match.range.location - start))) + "(.+?)"
                indices.append(Int(source.substring(with: match.range(at: 1)))!)
                start = NSMaxRange(match.range)
            }
            expression += NSRegularExpression.escapedPattern(for: source.substring(from: start)) + "$"
            guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]) else { return nil }
            return Pattern(key: key, regex: regex, indices: indices)
        }
    }()
    private static let fragments: [String] = {
        (catalogs[.chinese] ?? [:]).keys.filter { !$0.contains("{0}") && !$0.contains("\n") && $0.count >= 2 }.sorted { $0.count > $1.count }
    }()
    static func select(_ selection: AppLanguage) { lock.lock(); language = AppLanguage.resolve(selection); lock.unlock(); cache.removeAllObjects() }
    static var current: AppLanguage { lock.lock(); defer { lock.unlock() }; return language }
    static var locale: Locale { Locale(identifier: current.rawValue) }
    static func render(_ template: String, arguments: [Int: String]) -> String {
        let string = template as NSString
        var output = template
        for match in placeholders.matches(in: template, range: NSRange(location: 0, length: string.length)).reversed() {
            guard let index = Int(string.substring(with: match.range(at: 1))), let argument = arguments[index], let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: argument)
        }
        return output
    }
    static func text(_ value: String) -> String {
        let code = current
        let range = NSRange(value.startIndex..., in: value)
        guard chinese.firstMatch(in: value, range: range) != nil else { return value }
        let primary = catalogs[code] ?? [:], english = catalogs[.english] ?? [:]
        if let exact = primary[value] ?? english[value] { return exact }
        if code == .chinese { return value }
        // Raw filesystem paths and URLs must never be translated.
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        let cacheKey = (code.rawValue + "\0" + value) as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached as String }
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: value, range: range), match.range == range else { continue }
            var arguments: [Int: String] = [:]
            let original = value as NSString
            for (offset, index) in pattern.indices.enumerated() { let argument = original.substring(with: match.range(at: offset + 1)); arguments[index] = text(argument) }
            let translated = render(primary[pattern.key] ?? english[pattern.key] ?? pattern.key, arguments: arguments)
            cache.setObject(translated as NSString, forKey: cacheKey); return translated
        }
        // Composite status rows often join an API/model ID to stable UI labels.
        var translated = value
        for fragment in fragments where translated.contains(fragment) {
            if let replacement = primary[fragment] ?? english[fragment] { translated = translated.replacingOccurrences(of: fragment, with: replacement) }
        }
        cache.setObject(translated as NSString, forKey: cacheKey); return translated
    }
}
