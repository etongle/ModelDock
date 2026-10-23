import SwiftUI

enum HuggingFaceCredential {
    static func tokenURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = environment["HF_TOKEN_PATH"], !path.isEmpty { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        if let path = environment["HF_HOME"], !path.isEmpty { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).appendingPathComponent("token") }
        let cache = environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".cache")
        return cache.appendingPathComponent("huggingface/token")
    }
    static var available: Bool { ProcessInfo.processInfo.environment["HF_TOKEN"]?.isEmpty == false || FileManager.default.isReadableFile(atPath: tokenURL().path) }
    static func read(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        if let token = environment["HF_TOKEN"], !token.isEmpty { return token.trimmingCharacters(in: .whitespacesAndNewlines) }
        let url = tokenURL(environment: environment, home: home)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let token = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class DownloadAuthorizationDraft: ObservableObject, Identifiable {
    let id = UUID()
    let job: ModelDownload
    let includingPausedFiles: Bool
    @Published var token = ""
    @Published var error: String?
    init(job: ModelDownload, includingPausedFiles: Bool) { self.job = job; self.includingPausedFiles = includingPausedFiles }
}

@MainActor
struct DownloadAuthorizationView: View {
    @ObservedObject var downloads: DownloadController
    @ObservedObject var draft: DownloadAuthorizationDraft
    var configureGlobal: (() -> Void)? = nil
    @FocusState private var tokenFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: L10n.text("更新下载授权")).font(.system(size: TypeScale.section, weight: .semibold))
            Text(draft.job.repository).font(.system(size: TypeScale.body)).textSelection(.enabled)
            Text(verbatim: L10n.format("{0} 访问令牌", [draft.job.site.rawValue])).font(.system(size: TypeScale.body, weight: .medium))
            SecureField(L10n.text("粘贴访问令牌"), text: $draft.token).textFieldStyle(.roundedBorder).focused($tokenFocused).onSubmit { downloads.authorizeAndResume(draft) }.accessibilityIdentifier("download-access-token")
            if draft.job.site == .huggingface, let configureGlobal {
                Button(L10n.text("配置全局 Hugging Face 令牌…"), action: configureGlobal).buttonStyle(.bordered)
            }
            if draft.job.site == .huggingface, HuggingFaceCredential.available {
                Button(L10n.text("使用本机 Hugging Face 登录令牌并继续")) {
                    guard let token = HuggingFaceCredential.read(), !token.isEmpty else { draft.error = "无法读取本机登录令牌，请在上方重新输入。"; return }
                    draft.token = token; downloads.authorizeAndResume(draft)
                }.buttonStyle(.bordered).accessibilityIdentifier("use-local-hf-token")
            }
            Text(verbatim: L10n.text("令牌仅用于此任务，本次运行有效，不写入任务文件。请确认账号已获模型访问许可，并且令牌有读取权限。"))
                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            Label(L10n.format("已下载 {0}，更新授权后从断点继续。", [sizeLabel(draft.job.received)]), systemImage: "arrow.clockwise").font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            if let error = draft.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText) }
            Divider()
            HStack {
                Button(L10n.text("取消")) { draft.token = ""; downloads.authorization = nil }.buttonStyle(SecondaryButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("更新令牌并继续下载")) { downloads.authorizeAndResume(draft) }.buttonStyle(AccentButton()).disabled(draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("authorize-resume-download")
            }
        }.padding(26).frame(width: 570).background(Theme.background).onAppear { tokenFocused = true }.onDisappear { draft.token = "" }
    }
}
