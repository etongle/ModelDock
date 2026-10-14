import SwiftUI

enum WindowCloseBehavior: String, Codable, CaseIterable {
    case keepRunning, confirmQuit
}

struct AppPreferences: Codable {
    var windowCloseBehavior: WindowCloseBehavior = .keepRunning
    var language: AppLanguage = .english
    enum CodingKeys: String, CodingKey { case windowCloseBehavior, language }
    init(windowCloseBehavior: WindowCloseBehavior = .keepRunning, language: AppLanguage = .english) { self.windowCloseBehavior = windowCloseBehavior; self.language = language }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowCloseBehavior = try values.decodeIfPresent(WindowCloseBehavior.self, forKey: .windowCloseBehavior) ?? .keepRunning
        language = AppLanguage(rawValue: try values.decodeIfPresent(String.self, forKey: .language) ?? "en") ?? .english
    }
}

@MainActor
struct PreferencesView: View {
    @ObservedObject var store: AppStore
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.text("界面语言")) {
                    Picker(L10n.text("语言"), selection: $store.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in Text(verbatim: language.name).tag(language) }
                    }.accessibilityIdentifier("app-language")
                    Text(verbatim: L10n.text("默认使用英语。切换立即生效，设置会自动保存。"))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Section(L10n.text("关闭主界面时")) {
                    Picker(L10n.text("关闭行为"), selection: $store.windowCloseBehavior) {
                        Text(verbatim: L10n.text("保持程序后台运行（默认）")).tag(WindowCloseBehavior.keepRunning)
                        Text(verbatim: L10n.text("退出程序，每次再次确认")).tag(WindowCloseBehavior.confirmQuit)
                    }
                    .pickerStyle(.radioGroup).labelsHidden().accessibilityLabel(L10n.text("关闭主界面时的行为"))
                    .accessibilityIdentifier("window-close-behavior")
                    Text(verbatim: L10n.text(store.windowCloseBehavior == .keepRunning
                         ? "点击关闭按钮或按 ⌘W，只关闭主界面。模型服务、下载和资源监测继续运行，可从菜单栏图标重新打开。"
                         : "点击关闭按钮或按 ⌘W，会先询问是否退出。退出时暂停下载并结束监测；已启动的模型服务继续运行。"))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped)
            HStack {
                Text(verbatim: L10n.text(store.preferencesError ?? "设置会自动保存。")).font(.system(size: 12)).foregroundStyle(store.preferencesError == nil ? Theme.muted : Theme.errorText)
                Spacer()
                Button(L10n.text("完成"), action: close).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }.frame(width: 580, height: 450).background(Theme.background).environment(\.locale, L10n.locale)
    }
}
