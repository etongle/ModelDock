import SwiftUI

@MainActor private final class TokenSettingsInput: ObservableObject { @Published var value = "" }

@MainActor
struct HuggingFaceTokenSettings: View {
    @ObservedObject var tokens: ModelAccessTokens
    @StateObject private var input = TokenSettingsInput()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text(tokens.huggingFaceConfigured ? "已配置全局令牌" : "尚未配置全局令牌"), systemImage: tokens.huggingFaceConfigured ? "checkmark.shield" : "key")
                .foregroundStyle(tokens.huggingFaceConfigured ? Theme.successText : Theme.muted).accessibilityIdentifier("global-hf-token-status")
            SecureField(L10n.text(tokens.huggingFaceConfigured ? "输入新令牌以替换" : "粘贴 Hugging Face 读取令牌"), text: $input.value).textFieldStyle(.roundedBorder).accessibilityIdentifier("global-hf-token-input")
            HStack {
                Button(L10n.text("保存令牌")) { if tokens.save(input.value) { input.value = "" } }.disabled(input.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-global-hf-token")
                if tokens.huggingFaceConfigured { Button(L10n.text("移除令牌")) { tokens.remove(); input.value = "" }.accessibilityIdentifier("remove-global-hf-token") }
                Spacer()
                Link(L10n.text("获取令牌"), destination: URL(string: "https://huggingface.co/settings/tokens")!)
            }.buttonStyle(.bordered)
            if HuggingFaceCredential.available {
                Button(L10n.text("使用本机 Hugging Face 登录令牌")) {
                    guard let value = HuggingFaceCredential.read(), !value.isEmpty else { tokens.error = "无法读取本机登录令牌，请在上方重新输入。"; return }
                    if tokens.save(value) { input.value = "" }
                }.buttonStyle(.bordered).accessibilityIdentifier("import-global-hf-token")
            }
            Text(verbatim: L10n.text("令牌保存在 macOS 钥匙串，仅发送给 Hugging Face。自动用于搜索、模型更新、下载和续传；单次填写的令牌优先。受限模型仍需账号获准访问。"))
                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let error = tokens.error { Text(verbatim: L10n.text(error)).foregroundStyle(Theme.errorText).font(.system(size: TypeScale.callout)) }
            if let notice = tokens.notice { Text(verbatim: L10n.text(notice)).foregroundStyle(Theme.successText).font(.system(size: TypeScale.callout)) }
        }.onAppear { tokens.refresh() }.onDisappear { input.value = "" }
    }
}
