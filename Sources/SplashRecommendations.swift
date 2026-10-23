import Foundation
import SwiftUI

struct SplashRecommendedVariant: Identifiable {
    var reference: String
    var title: String
    var minimumVersion = "1.3.0"
    var compact = false
    var id: String { reference }
}
struct SplashRecommendedFamily: Identifiable {
    var name: String
    var variants: [SplashRecommendedVariant]
    var id: String { name }
}

enum SplashRecommendations {
    // Official README/examples, checked 2026-10-22. Pin the source link so the
    // recommendation cannot silently imply support added by a later release.
    static let source = "https://github.com/incoai/splash/blob/1.4.0/README.md#models"
    static let families: [SplashRecommendedFamily] = [
        .init(name: "Qwen3.8-27B", variants: [
            .init(reference: "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", title: "GGUF · UD-Q4_K_M"),
            .init(reference: "mlx-community/Qwen3.8-27B-4bit", title: "MLX · 4-bit"),
            .init(reference: "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS", title: "GGUF · UD-IQ3_XXS", compact: true)
        ]),
        .init(name: "Qwen3.6-35B-A3B", variants: [
            .init(reference: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M", title: "GGUF · UD-Q4_K_M"),
            .init(reference: "mlx-community/Qwen3.6-35B-A3B-4bit", title: "MLX · 4-bit"),
            .init(reference: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL", title: "GGUF · UD-Q2_K_XL", compact: true)
        ]),
        .init(name: "Qwen3.8-Flash-Next", variants: [
            .init(reference: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0", title: "GGUF · Q2_0", minimumVersion: "1.4.0")
        ]),
        .init(name: "Ternary Bonsai 2 · 27B", variants: [
            .init(reference: "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0", title: "GGUF · PQ2_0", compact: true)
        ])
    ]

    static func versionIssue(_ variant: SplashRecommendedVariant, version: String) -> String? {
        let state = EngineVersionPolicy.state(installed: version, available: variant.minimumVersion)
        return [.current, .newer].contains(state) ? nil : L10n.format("需要 Splash {0} 或更新版本", [variant.minimumVersion])
    }
    static func hardwareIssue(chip: String, os: OperatingSystemVersion) -> String? {
        if os.majorVersion < 26 || (os.majorVersion == 26 && os.minorVersion < 4) { return "Splash 官方版需要 macOS 26.4 或更新版本。" }
        if let match = ServiceStartupProgress.match(#"Apple M([0-9]+)"#, in: chip), let generation = Int(match[1]), generation < 3 {
            return "Splash 官方版需要 Apple M3 或更新芯片。"
        }
        return nil
    }
    static func command(_ variant: SplashRecommendedVariant, engine: Engine, port: Int) -> String {
        var text = ServiceCommand.quote(engine.path) + " serve --model " + ServiceCommand.quote(variant.reference) + " --port \(port) --max-context 32768"
        if engine.launchSettings?.inputMode == .text { text += " --language-only" }
        if engine.launchSettings?.ane == false { text += " --disable-ane" }
        return text
    }
}

@MainActor extension AppStore {
    func prepareSplashRecommendation(_ variant: SplashRecommendedVariant) {
        guard let engine = engines.first(where: { $0.kind == .splash }), engine.canServe, engineEnabled(engine.id) else { message = "请先安装并启用 Splash。"; return }
        if let issue = SplashRecommendations.hardwareIssue(chip: inventory?.chip ?? "", os: ProcessInfo.processInfo.operatingSystemVersion) { message = issue; return }
        if let issue = SplashRecommendations.versionIssue(variant, version: SplashRuntime.current(engine)?.version ?? engine.version) { message = issue; return }
        guard SplashRuntime.current(engine)?.supportsPacked == false else { message = "请先更新 Splash，以使用新版上游模型加载组件。"; return }
        do {
            let port = try EnginePortPolicy.available(engine: engine, base: engine.defaultPort, count: 1, occupied: { self.services.portReserved($0) || NetworkProbe.portOccupied($0) })[0]
            prepareCommand(engine: engine, text: SplashRecommendations.command(variant, engine: engine, port: port))
        } catch { message = error.localizedDescription }
    }
}

@MainActor private final class SplashRecommendationViewState: ObservableObject { @Published var selections: [String: String] = [:] }

@MainActor struct SplashRecommendationsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var ui = SplashRecommendationViewState()
    private var engine: Engine { store.engine }
    private var hardwareIssue: String? { SplashRecommendations.hardwareIssue(chip: store.inventory?.chip ?? "", os: ProcessInfo.processInfo.operatingSystemVersion) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.text("Splash 官方推荐模型"), systemImage: "sparkles").font(.system(size: TypeScale.section, weight: .semibold))
                Spacer(minLength: 8)
                Button(L10n.text("检查更新…")) { store.checkInstall() }.buttonStyle(.bordered).disabled(store.installation.running || store.maintaining)
                Link(L10n.text("官方模型说明"), destination: URL(string: SplashRecommendations.source)!).font(.system(size: TypeScale.callout))
            }
            Text(verbatim: L10n.text("按官方示例提供主模型与量化选项，Splash 自动配对 DFlash2 草稿、tokenizer 和可用视觉组件。首次准备会下载文件，已有缓存会复用。"))
                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L10n.text("官方要求 M3 或更新芯片、macOS 26.4+；4-bit 示例至少 36 GB 内存，推荐 48 GB。24 GB 可考虑较小 GGUF，实际由引擎检查。"))
                .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let hardwareIssue { Text(verbatim: L10n.text(hardwareIssue)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText) }
            ForEach(SplashRecommendations.families) { family in
                let variant = family.variants.first { $0.id == ui.selections[family.id] } ?? family.variants[0]
                let versionIssue = SplashRecommendations.versionIssue(variant, version: SplashRuntime.current(engine)?.version ?? engine.version)
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack { familyLabel(family, variant: variant); Spacer(minLength: 12); variantPicker(family, variant: variant); launchButton(variant, issue: versionIssue) }
                        VStack(alignment: .leading, spacing: 10) { familyLabel(family, variant: variant); HStack { variantPicker(family, variant: variant); Spacer(); launchButton(variant, issue: versionIssue) } }
                    }
                    Text(verbatim: variant.reference).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let versionIssue { Text(verbatim: versionIssue).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.warningText) }
                }.padding(12).background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(verbatim: L10n.text("点击后先预览启动配置，再确认准备与启动；推荐不代表已经在本机完成推理验证。"))
                .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
        }.padding(16).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("splash-official-recommendations")
    }
    private func familyLabel(_ family: SplashRecommendedFamily, variant: SplashRecommendedVariant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: family.name).font(.system(size: TypeScale.body, weight: .semibold))
            if variant.compact { Text(verbatim: L10n.text("较小权重选项")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted) }
        }
    }
    private func variantPicker(_ family: SplashRecommendedFamily, variant: SplashRecommendedVariant) -> some View {
        Picker(L10n.text("量化格式"), selection: Binding(get: { variant.id }, set: { ui.selections[family.id] = $0 })) {
            ForEach(family.variants) { item in Text(verbatim: item.title).tag(item.id) }
        }.labelsHidden().frame(width: 185).accessibilityIdentifier("splash-variant-" + family.id)
    }
    private func launchButton(_ variant: SplashRecommendedVariant, issue: String?) -> some View {
        Button(L10n.text("准备并启动…")) { store.prepareSplashRecommendation(variant) }.buttonStyle(.bordered)
            .disabled(issue != nil || hardwareIssue != nil || !engine.canServe || !store.engineEnabled(engine.id) || store.installation.running || store.maintaining)
            .help(issue ?? L10n.text("预览主模型、匹配草稿和启动参数"))
            .accessibilityIdentifier("prepare-splash-" + variant.id)
    }
}
