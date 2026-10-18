import Foundation

enum TranslationLanguages {
    static let targets = ["English", "Chinese", "French", "Portuguese", "German", "Spanish", "Italian", "Japanese", "Korean", "Russian"]
    static func title(_ value: String) -> String {
        if value == "auto" { return L10n.text("自动检测") }
        return ["English": "English", "Chinese": "中文", "French": "Français", "Portuguese": "Português", "German": "Deutsch", "Spanish": "Español", "Italian": "Italiano", "Japanese": "日本語", "Korean": "한국어", "Russian": "Русский"][value] ?? value
    }
    static func modelIssue(_ model: LocalModel) -> String? {
        let identity = (model.origin?.repository ?? model.repository ?? model.name).lowercased()
        if identity.contains("confucius4-t3po") { return "T3PO 需要专用的中英同传协议，不能用于当前多语言翻译流程。请选择 Qwen3.8。" }
        return nil
    }
}
