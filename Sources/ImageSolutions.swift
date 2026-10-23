import SwiftUI

@MainActor extension AppStore {
    func installImageSolutionEngine() {
        guard let engine = engines.first(where: { $0.kind == .mflux }), !engine.installed, engineEnabled(engine.id),
              installation.checking == nil, !installation.running, !preparingInstall, !maintaining,
              !services.resourceCleanupInProgress, !appUpdates.applying, solutions.preparingID == nil else { return }
        installation.checking = engine.id; installation.log = ""; installation.message = nil; installation.succeeded = false; solutions.message = nil
        Task {
            defer { installation.checking = nil }
            do {
                let release = try await EngineCatalog.release(.mflux)
                await services.refresh()
                guard let current = engines.first(where: { $0.id == engine.id }), !current.installed,
                      engineEnabled(current.id), !installation.running, !maintaining, !appUpdates.applying, solutions.preparingID == nil else { return }
                let plan = EngineCatalog.plan(engine: current, release: release)
                installation.releases[current.id] = release
                installation.plan = plan
                performInstall(plan)
            } catch { solutions.message = error.localizedDescription }
        }
    }
}

@MainActor struct ImageSolutionEngineView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var installer: EngineInstallController
    private var engine: Engine? { store.engines.first { $0.kind == .mflux } }
    var body: some View {
        if let engine {
            let enabled = store.engineEnabled(engine.id)
            let supported = engine.canServe && [.current, .newer].contains(EngineVersionPolicy.state(installed: engine.version, available: "0.23.0"))
            let busy = installer.checking == engine.id || installer.activeEngineID == engine.id
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: L10n.text("推荐基座")).font(.system(size: TypeScale.body, weight: .semibold))
                HStack(spacing: 12) {
                    EngineIcon(engine: engine, size: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MFLUX").font(.system(size: TypeScale.body, weight: .semibold))
                        Text(verbatim: L10n.text("Apple Silicon · MFLUX 0.23.0 或更新版本 · 文生图 / 图生图")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        Text(verbatim: L10n.text(!enabled ? "已禁用" : !engine.installed ? "未安装" : "已安装") + (engine.installed ? " · " + engine.version : "")).font(.system(size: TypeScale.caption)).foregroundStyle(supported && enabled ? Theme.successText : Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if !enabled { Button(L10n.text("全局引擎设置")) { store.showGlobalEngines = true }.buttonStyle(.bordered) }
                    else if !engine.installed {
                        Button(L10n.text(busy ? "正在安装基座…" : "一键安装基座")) { store.installImageSolutionEngine() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(installer.checking != nil || installer.running || store.preparingInstall || store.maintaining || store.services.resourceCleanupInProgress || store.appUpdates.applying || store.solutions.preparingID != nil).accessibilityIdentifier("install-image-solution-engine")
                    } else {
                        Button(L10n.text(supported ? "管理基座" : "修复或更新基座…")) {
                            store.chooseEngine(engine.id); store.engineSection = .overview; store.tab = .engines
                            if !supported { store.checkInstall() }
                        }.buttonStyle(.bordered).accessibilityIdentifier("manage-image-solution-engine")
                    }
                }
                Text(verbatim: L10n.text("基座负责运行模型；此按钮只安装运行环境。模型权重通过下方方案单独下载，已有组件会复用。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if busy { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text(installer.checking != nil ? "正在检查引擎版本…" : "正在安装引擎")) }.font(.system(size: TypeScale.callout)) }
            }.padding(16).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("image-solution-recommended-engine")
        }
    }
}

@MainActor struct ImageSolutionScopeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Qwen-Image-2.1-Turbo · 8 steps · MFLUX").font(.system(size: TypeScale.body, weight: .medium))
            Text(verbatim: L10n.text("默认使用官方 Turbo；也可选择参考文档中的 Heretic MLX 版。均使用完整主模型、文本编码器和 VAE，优先复用已有服务。"))
            Text(verbatim: L10n.text("8 步、CFG 1，默认以 8-bit 加载主模型。完整下载约 32 GB，请为其他运行中的模型留出内存。"))
            Text(verbatim: L10n.text("支持文生图和单图重绘；图生图可设置重绘强度，使用同一套模型。"))
            Text(verbatim: L10n.text("Noct-Q 单文件、Viggle 6 步及 25 步模式需要另外转换和验证，本方案暂不提供。"))
        }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor struct ImageSolutionTrialView: View {
    @ObservedObject var store: AppStore
    var record: SolutionDeployment
    var body: some View {
        if let component = record.components.first(where: { $0.role == .image }),
           let spec = store.services.records.first(where: { $0.id == component.serviceID }), store.services.status(spec) == .running {
            ImageGenerationView(session: store.imageSession(spec, apiModel: component.serviceBinding?.model), copy: store.copy, showService: { store.showService(spec) })
        } else {
            Text(verbatim: L10n.text("请先启动生图服务并等待就绪。"))
                .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
        }
    }
}
