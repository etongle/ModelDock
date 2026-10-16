import SwiftUI
import AppKit

extension AppStore {
    func installBlockers(_ engine: Engine) -> [String] {
        var result: [String] = []
        if engine.kind == .strata && strata.busy { result.append("请等待 Strata 模型准备操作完成。") }
        if (maintaining || preparingMaintenance) && maintenanceEngineID == engine.id { result.append("请等待 \(engine.name) 清理完成。") }
        // Services started by ModelDock are stopped and restarted around the update, so they are not blockers.
        if let app = engine.appPath, NSRunningApplicationCheck.isRunning(app) { result.append("请先退出 \(engine.name) 原应用。") }
        let owned = Set(restartableServices(engine).compactMap(\.pid))
        // Children of a managed service share its process group and stop with it.
        for process in updateProcesses(engine) where !owned.contains(process.pid) && !owned.contains(getpgid(process.pid)) { result.append("\(engine.name) 的外部运行进程 · PID \(process.pid)，请使用原应用停止。") }
        if multiModel?.engine.id == engine.id && multiModel?.running == true { result.append("请等待模型加载操作完成。") }
        return result
    }
    func restartableServices(_ engine: Engine) -> [ServiceSpec] { services.records.filter { $0.engineID == engine.id && $0.pid != nil } }
    func checkInstall() {
        let chosen = engine
        guard !((maintaining || preparingMaintenance) && maintenanceEngineID == chosen.id) && !(multiModel?.engine.id == chosen.id && multiModel?.running == true) else { return }
        Task { await services.refresh(); installation.check(chosen) }
    }
}
@MainActor
struct EngineInstallPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var installer: EngineInstallController
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Label(L10n.text("安装与更新"), systemImage: "arrow.down.app").font(.system(size: TypeScale.body, weight: .semibold))
                    Text(verbatim: L10n.text(installer.releases[store.engineID].map { EngineVersionPolicy.summary(EngineVersionPolicy.rows(engine: store.engine, release: $0)) + " · 检查于 " + $0.checkedAt.formatted(date: .omitted, time: .shortened) } ?? (store.engine.kind == .strata ? "官方 Metal 源码编译 · Apple Silicon · macOS 15+" : "检查后显示已安装版本、最新版本与更新状态"))).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 10)
                if installer.checking == store.engineID { ProgressView().controlSize(.small); Text(verbatim: L10n.text("检查中…")).font(.system(size: TypeScale.body)) }
                else { Button { store.checkInstall() } label: { Label(L10n.text(store.engine.kind == .mlx && !store.engine.canServe ? "安装 MLX-LM…" : store.engine.installed ? "检查更新…" : "安装引擎…"), systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(SecondaryButton()).disabled(installer.checking != nil || installer.running || (store.maintaining && store.maintenanceEngineID == store.engineID)) }
            }
            if installer.running { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text("正在安装或更新；完成后自动扫描引擎。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) } }
            else if let message = installer.message, installer.plan == nil { Text(verbatim: L10n.text(message)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(3).textSelection(.enabled) }
        }.padding(17).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}
@MainActor
struct EngineInstallView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var installer: EngineInstallController
    var plan: EngineInstallPlan
    var currentEngine: Engine { store.engines.first { $0.id == plan.engine.id } ?? plan.engine }
    var rows: [EngineVersionRow] { EngineVersionPolicy.rows(engine: currentEngine, release: plan.release) }
    var needsAction: Bool { rows.contains { $0.state.needsAction } }
    var blockers: [String] { needsAction ? Array(Set(plan.blockers + store.installBlockers(currentEngine))).sorted() : [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { EngineIcon(engine: currentEngine, size: 52); VStack(alignment: .leading, spacing: 6) { Text(verbatim: L10n.text(needsAction || installer.running ? plan.title : L10n.text("版本检查 · " + currentEngine.name))).font(.system(size: TypeScale.section, weight: .bold)); Text(verbatim: L10n.text(store.scanning && !installer.running ? "正在核对安装结果…" : EngineVersionPolicy.summary(rows))).foregroundStyle(needsAction ? Theme.warningText : Theme.muted) }; Spacer() }
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Label(L10n.text(plan.release.source), systemImage: "checkmark.shield").font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                    EngineVersionTable(rows: rows)
                    if needsAction { ForEach(plan.notes, id: \.self) { Text(verbatim: L10n.text($0)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) } }
                    else { Text(verbatim: L10n.text("当前无需更新。各组件的版本号独立，不能相互比较。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                    if let bytes = plan.release.bytes { Text(verbatim: L10n.text("发行包下载大小：" + sizeLabel(bytes))).font(.system(size: TypeScale.body)) }
                    if !blockers.isEmpty && !installer.running {
                        VStack(alignment: .leading, spacing: 12) { Label(L10n.text("\(plan.engine.name) 更新前需要处理"), systemImage: "pause.circle").fontWeight(.semibold); ForEach(blockers, id: \.self) { Text(verbatim: L10n.text($0)).font(.system(size: TypeScale.body)) }; Button(L10n.text("查看 \(plan.engine.name) 服务")) { installer.plan = nil; store.showEngineServices(plan.engine.id) }; if EnginePaths.brew == nil { Link("Homebrew 官方安装说明", destination: URL(string: "https://brew.sh")!) } }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.warningText.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(Theme.warningText)
                    }
                    if needsAction && blockers.isEmpty && !installer.running && installer.log.isEmpty && !store.restartableServices(currentEngine).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L10n.text("更新时会先停止以下服务，完成后自动重新启动"), systemImage: "arrow.clockwise.circle").fontWeight(.semibold)
                            ForEach(store.restartableServices(currentEngine)) { spec in Text(verbatim: L10n.text("端口 \(spec.port) · \(spec.modelName)")).font(.system(size: TypeScale.body)) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !plan.commands.isEmpty { DisclosureGroup("查看实际安装命令") { ForEach(Array(plan.commands.enumerated()), id: \.offset) { _, command in VStack(alignment: .leading, spacing: 6) { Text(verbatim: L10n.text(command.title)).fontWeight(.medium); Text(verbatim: L10n.text(command.display)).font(.system(size: TypeScale.caption, design: .monospaced)).textSelection(.enabled) }.padding(.vertical, 7) } }.font(.system(size: TypeScale.body)) }
                    if installer.running || !installer.log.isEmpty {
                        HStack { Text(verbatim: L10n.text("执行进度")).fontWeight(.semibold); Spacer(); if installer.running { ProgressView().controlSize(.small) } }
                        Text(verbatim: L10n.text(String(installer.log.suffix(24_000)))).font(.system(size: TypeScale.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Theme.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let message = installer.message { Text(verbatim: L10n.text(installer.succeeded && !installer.running && !store.scanning ? "操作已完成。" + EngineVersionPolicy.summary(rows) + "。" : message)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L10n.text(installer.log.isEmpty && needsAction ? "取消" : "关闭")) { installer.plan = nil }.buttonStyle(SecondaryButton()).disabled(installer.running)
                Spacer()
                if !installer.running && installer.log.isEmpty && needsAction { Button(L10n.text(store.preparingInstall ? "核对运行状态…" : "开始" + (plan.updating ? "更新" : "安装"))) { store.performInstall(plan) }.buttonStyle(AccentButton()).disabled(!blockers.isEmpty || store.preparingInstall || store.scanning) }
                if installer.running { Text(verbatim: L10n.text("安装任务进行中")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
            }
        }.padding(26).frame(width: 670, height: 600).background(Theme.background).interactiveDismissDisabled(installer.running)
    }
}

@MainActor
struct MultiModelView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var draft: MultiModelDraft
    var modalityBlockers: [String] {
        guard draft.mode == .independent, draft.inputMode == .multimodal else { return [] }
        return draft.choices.filter { draft.selected.contains($0.id) }.compactMap { choice in
            ModalityPolicy.nativeMultimodalReason(engine: draft.engine, model: choice.model, projector: choice.model.flatMap { draft.projectorPaths[$0.id] }).map { choice.name + "：" + $0 }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack { EngineIcon(engine: draft.engine, size: 50); VStack(alignment: .leading, spacing: 6) { Text(verbatim: L10n.text(draft.mode == .independent ? "启动多个模型" : "加载多个模型")).font(.system(size: TypeScale.section, weight: .bold)); Text(verbatim: L10n.text(draft.engine.name)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }; Spacer() }
            Text(verbatim: L10n.text(draft.engine.multiModelDescription)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            if draft.mode == .independent {
                Picker(L10n.text("本次启动模式"), selection: $draft.inputMode) { ForEach(InputMode.allCases) { Text(verbatim: L10n.text($0.title)).tag($0) } }.disabled(draft.running || draft.done)
                Text(verbatim: L10n.text("每个模型分别使用自己的投影组件；纯文本启动不加载投影文件。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            } else { Text(verbatim: L10n.text("多模态随所加载模型的实际能力自动开启；纯文本输入限制可在网关中设置。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            if draft.choices.isEmpty { EmptyMessage(symbol: "cube", title: L10n.text("暂时没有可加载的模型"), detail: draft.mode == .ollama ? "请先将模型导入 Ollama，再重新打开此页面。" : "先在“下载导入”或“模型文件”中添加适配此引擎的模型。") }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(draft.choices) { choice in
                        Button {
                            if draft.selected.contains(choice.id) { draft.selected.remove(choice.id) } else { draft.selected.insert(choice.id) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: draft.selected.contains(choice.id) ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(draft.selected.contains(choice.id) ? Theme.linkColor : Theme.muted)
                                VStack(alignment: .leading, spacing: 6) { Text(verbatim: L10n.text(choice.name)).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(2); Text(verbatim: L10n.text((choice.model.map { $0.format + " · " } ?? "") + (choice.bytes > 0 ? sizeLabel(choice.bytes) : "大小由引擎管理"))).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                                Spacer()
                                if draft.mode == .independent, let index = draft.selectedChoices.firstIndex(where: { $0.id == choice.id }), let ports = draft.ports, index < ports.count { Text(verbatim: L10n.text("端口 \(ports[index])")).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted) }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(draft.selected.contains(choice.id) ? Theme.selection : Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(draft.running || draft.done).help(L10n.text(choice.model?.path ?? choice.name))
                    }
                }
            }.frame(minHeight: 100)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) { Text(verbatim: L10n.text(draft.mode == .independent ? "起始端口 · 自动跳过占用" : "服务端口")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); TextField(L10n.text("8000"), text: $draft.basePort).textFieldStyle(.roundedBorder).frame(width: 170) }
                if draft.engine.kind != .mlx { VStack(alignment: .leading, spacing: 8) { Text(verbatim: L10n.text("上下文长度")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); Picker(L10n.text("上下文"), selection: $draft.context) { ForEach([2048, 4096, 8192, 16384, 32768], id: \.self) { Text(verbatim: L10n.text("\($0) tokens")).tag($0) } }.labelsHidden().frame(width: 170) } }
                else { Text(verbatim: L10n.text("上下文由 MLX-LM 与模型管理")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                Spacer()
                Text(verbatim: L10n.text("已选 \(draft.selected.count) 个")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            }.disabled(draft.running || draft.done)
            if draft.weightBytes > 0 { Text(verbatim: L10n.text("所选权重 \(sizeLabel(draft.weightBytes)) · 内存已用 \(store.resources.system.map { memoryLabel($0.memoryUsed) } ?? "—") / \(memoryLabel(store.inventory?.memoryBytes ?? 0))；运行另需缓存与工作内存。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            ForEach(Array(modalityBlockers.prefix(3)), id: \.self) { Text(verbatim: L10n.text($0)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText) }
            if draft.mode == .ollama { Text(verbatim: L10n.text("常驻模型数量可在启动 Ollama 服务的“更多设置”中调整。已有外部服务采用它自己的设置。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            if !draft.progress.isEmpty { HStack { if draft.running { ProgressView().controlSize(.small) }; Text(verbatim: L10n.text(draft.progress)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) } }
            if !draft.errors.isEmpty { Text(verbatim: L10n.text(draft.errors.joined(separator: "\n"))).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).lineLimit(4).textSelection(.enabled) }
            Divider()
            HStack { Button(L10n.text("关闭")) { store.multiModel = nil }.buttonStyle(SecondaryButton()).disabled(draft.running); Spacer(); if draft.done { Button(L10n.text("查看模型服务")) { store.multiModel = nil; store.tab = .services }.buttonStyle(AccentButton()) } else { Button(L10n.text(draft.mode == .independent ? "启动所选模型" : "加载所选模型")) { store.runMultiModel(draft) }.buttonStyle(AccentButton()).disabled(draft.selected.isEmpty || draft.selected.count > 16 || draft.running || !modalityBlockers.isEmpty || store.installation.activeEngineID == draft.engine.id) } }
        }.padding(26).frame(width: 680, height: 650).background(Theme.background).interactiveDismissDisabled(draft.running)
    }
}
@MainActor
struct OllamaLoadedView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var port: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(verbatim: L10n.text("实际常驻模型")).font(.system(size: TypeScale.section, weight: .semibold)); Spacer(); Button(L10n.text("加载多个模型…")) { store.chooseEngine("ollama"); store.port = String(port); store.prepareMultiModel() }.buttonStyle(.bordered).disabled(store.preparingMulti || store.installation.activeEngineID == "ollama") }
            if let models = services.loadedModels[port] {
                if models.isEmpty { Text(verbatim: L10n.text("目前没有常驻模型；模型请求到来时可按需加载。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                ForEach(models) { model in HStack { VStack(alignment: .leading, spacing: 6) { Text(model.name).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(1); ModelCapabilityBadge(capabilities: services.modelCapabilities[port]?[model.name] ?? ModelCapabilities()) }; Spacer(); Text(verbatim: L10n.text(model.size.map(sizeLabel) ?? "—")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); if let context = model.context_length { Text(verbatim: L10n.text("\(context) tokens")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }; Button(L10n.text(store.unloadingModel == "\(port):\(model.name)" ? "卸载中…" : "卸载常驻")) { store.unloadOllamaModel(model.name, port: port) }.buttonStyle(.bordered).disabled(store.unloadingModel != nil).help(L10n.text("释放此模型占用的内存，保留模型文件和其他常驻模型")) }.padding(14).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10)) }
            } else { Text(verbatim: L10n.text("正在读取引擎常驻状态…")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
        }
    }
}
