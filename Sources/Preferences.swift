import AppKit
import SwiftUI

enum WindowCloseBehavior: String, Codable, CaseIterable {
    case keepRunning, confirmQuit
}

/// Interface appearance; `.system` follows the macOS Light/Dark setting.
enum AppAppearance: String, Codable, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var appearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) } }
}

struct AppPreferences: Codable {
    var windowCloseBehavior: WindowCloseBehavior = .keepRunning
    var language: AppLanguage = .english
    var appearance: AppAppearance = .system
    var sidebarHidden = false
    var systemNotifications = true
    /// Icon only keeps the menu-bar item narrow so it is less likely to hide behind the notch.
    var menuBarIconOnly = false
    var sidebarWidth: Double?
    enum CodingKeys: String, CodingKey { case windowCloseBehavior, language, appearance, sidebarHidden, systemNotifications, menuBarIconOnly, sidebarWidth }
    init(windowCloseBehavior: WindowCloseBehavior = .keepRunning, language: AppLanguage = .english, appearance: AppAppearance = .system, sidebarHidden: Bool = false, systemNotifications: Bool = true, menuBarIconOnly: Bool = false, sidebarWidth: Double? = nil) {
        self.sidebarWidth = sidebarWidth
        self.windowCloseBehavior = windowCloseBehavior; self.language = language; self.appearance = appearance; self.sidebarHidden = sidebarHidden; self.systemNotifications = systemNotifications; self.menuBarIconOnly = menuBarIconOnly
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowCloseBehavior = try values.decodeIfPresent(WindowCloseBehavior.self, forKey: .windowCloseBehavior) ?? .keepRunning
        language = AppLanguage(rawValue: try values.decodeIfPresent(String.self, forKey: .language) ?? "en") ?? .english
        appearance = AppAppearance(rawValue: try values.decodeIfPresent(String.self, forKey: .appearance) ?? "system") ?? .system
        sidebarHidden = try values.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? false
        systemNotifications = try values.decodeIfPresent(Bool.self, forKey: .systemNotifications) ?? true
        menuBarIconOnly = try values.decodeIfPresent(Bool.self, forKey: .menuBarIconOnly) ?? false
        sidebarWidth = try values.decodeIfPresent(Double.self, forKey: .sidebarWidth)
    }
}

@MainActor
struct PreferencesView: View {
    @ObservedObject var store: AppStore
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            // Paged Settings keeps every page short as options grow (a single long form overflowed). A segmented
            // control is used instead of TabView, whose tab strip does not render in offscreen captures.
            Picker(L10n.text("设置"), selection: $store.settingsTab) {
                Text(verbatim: L10n.text("通用")).tag(0); Text(verbatim: L10n.text("外观")).tag(1); Text(verbatim: L10n.text("应用更新")).tag(2)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 16).accessibilityIdentifier("settings-pages")
            Group {
                switch store.settingsTab {
                case 1:
                Form {
                    Section(L10n.text("外观")) {
                        Picker(L10n.text("外观"), selection: $store.appearance) {
                            ForEach(AppAppearance.allCases, id: \.self) { option in Text(verbatim: L10n.text(option.title)).tag(option) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("app-appearance")
                    }
                    Section(L10n.text("菜单栏显示")) {
                        Picker(L10n.text("菜单栏显示"), selection: $store.menuBarIconOnly) {
                            Text(verbatim: L10n.text("图标 + CPU · 内存")).tag(false)
                            Text(verbatim: L10n.text("仅图标")).tag(true)
                        }.pickerStyle(.segmented).accessibilityIdentifier("menu-bar-style")
                    }
                }.formStyle(.grouped)
                case 2:
                Form {
                    Section(L10n.text("应用更新")) {
                        AppUpdateSettings(updates: store.appUpdates).id(store.language.rawValue)
                    }
                }.formStyle(.grouped)
                default:
                Form {
                    Section(L10n.text("界面语言")) {
                        Picker(L10n.text("语言"), selection: $store.language) {
                            ForEach(AppLanguage.allCases, id: \.self) { language in Text(verbatim: language.name).tag(language) }
                        }.accessibilityIdentifier("app-language")
                        Text(verbatim: L10n.text("默认使用英语。切换立即生效，设置会自动保存。"))
                            .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
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
                            .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Section(L10n.text("通知")) {
                        Toggle(L10n.text("下载完成、服务就绪或意外退出时发送系统通知"), isOn: $store.systemNotifications).accessibilityIdentifier("system-notifications")
                    }
                }.formStyle(.grouped)
                }
            // Separate window: rebuild on language change so pickers and labels never keep the previous language.
            }.id(store.language)
            HStack {
                Text(verbatim: L10n.text(store.preferencesError ?? "设置会自动保存。")).font(.system(size: TypeScale.callout)).foregroundStyle(store.preferencesError == nil ? Theme.muted : Theme.errorText)
                Spacer()
                Button(L10n.text("完成"), action: close).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }.frame(width: 580, height: 560).background(Theme.background).environment(\.locale, L10n.locale)
    }
}

struct AppUpdateSettings: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: L10n.text("当前应用版本：\(AppUpdateCatalog.installedVersion)"))
                Spacer()
                if let latest = updates.release { Text(verbatim: L10n.text("GitHub 正式版：\(latest.version)")) }
            }.font(.system(size: 12)).textSelection(.enabled)
            Toggle(L10n.text("每天自动检查 GitHub 新版本"), isOn: $updates.automaticCheck).accessibilityIdentifier("automatic-app-update-check")
            Toggle(L10n.text("自动下载并覆盖安装，完成后重新打开"), isOn: $updates.automaticInstall).accessibilityIdentifier("automatic-app-update-install")
            Text(verbatim: L10n.text("模型文件和设置保留，运行中的模型服务继续运行。安装引擎、下载或准备模型时会延后更新。"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L10n.text(updates.status)).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if updates.busy {
                if updates.received > 0, let release = updates.release {
                    ProgressView(value: updates.progress)
                    HStack {
                        Text(verbatim: String(format: "%.1f%%", updates.progress * 100) + " · " + sizeLabel(updates.received) + " / " + sizeLabel(release.bytes))
                        Spacer()
                        Text(verbatim: updates.speed > 0 ? sizeLabel(Int64(updates.speed)) + "/s" : "—")
                    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                } else { ProgressView().controlSize(.small) }
            }
            if let error = updates.error { Text(verbatim: L10n.text(error)).font(.system(size: 12)).foregroundStyle(Theme.errorText).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.text("检查应用更新…")) { updates.check() }.disabled(updates.busy || updates.applying).accessibilityIdentifier("check-app-update")
                if updates.available {
                    Button(L10n.text(updates.ready != nil ? "安装并重新打开" : "下载并覆盖安装")) { updates.download(installWhenReady: true) }
                        .disabled(updates.busy || updates.applying).accessibilityIdentifier("install-app-update")
                }
                Spacer()
                Link(L10n.text("发行说明"), destination: updates.release?.page ?? URL(string: "https://github.com/etongle/ModelDock/releases")!)
            }
            if let last = updates.lastCheck { Text(verbatim: L10n.text("上次检查：\(last.formatted(date: .abbreviated, time: .shortened))")).font(.system(size: 11)).foregroundStyle(Theme.muted) }
        }
    }
}
