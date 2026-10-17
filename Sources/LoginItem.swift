import Foundation
import SwiftUI
import ServiceManagement

/// “登录时启动 ModelDock”：直接读写系统登录项，开关状态以系统为准，不另存设置。
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published var error: String?
    var enabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = L10n.text("登录项设置失败：") + error.localizedDescription }
        refresh()
    }
}

@MainActor struct LoginItemSettings: View {
    @ObservedObject var login: LoginItemController
    var body: some View {
        Toggle(L10n.text("登录 Mac 时启动 ModelDock"), isOn: Binding(get: { login.enabled }, set: { login.set($0) })).accessibilityIdentifier("launch-at-login")
        Text(verbatim: L10n.text(login.enabled
             ? "登录后自动打开 ModelDock；标记为“随 ModelDock 启动”的服务会随之启动。"
             : "关闭时不会自动打开 ModelDock。开启后会加入系统设置的“登录项”。"))
            .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        if login.status == .requiresApproval {
            HStack {
                Text(verbatim: L10n.text("需要在系统设置的“登录项”中允许 ModelDock。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText)
                Button(L10n.text("打开登录项设置")) { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error = login.error { Text(verbatim: error).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText) }
    }
}
