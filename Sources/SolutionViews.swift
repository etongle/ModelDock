import SwiftUI
import AppKit

@MainActor private final class SolutionViewState: ObservableObject { @Published var removal: SolutionDeployment? }
@MainActor struct SolutionWorkspace: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: SolutionController
    var sidebarWidth: CGFloat
    @StateObject private var ui = SolutionViewState()
    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarHidden {
                VStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
                    SidebarHeader(title: "解决方案") { SidebarToggleButton(store: store) }
                    TextField(L10n.text("搜索方案"), text: $controller.search).textFieldStyle(.roundedBorder).accessibilityIdentifier("solution-search")
                    List(selection: Binding(get: { controller.selectedID as String? }, set: { if let id = $0 { controller.selectedID = id; controller.section = .configuration; store.solutionTrial.reset() } })) {
                        ForEach(SolutionCatalog.visible.filter { controller.search.isEmpty || L10n.text($0.title).localizedCaseInsensitiveContains(controller.search) || L10n.text($0.subtitle).localizedCaseInsensitiveContains(controller.search) }) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).font(.system(size: 20)).foregroundStyle(Theme.muted).frame(width: 40, height: 40).background(Theme.line, in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: L10n.text(item.title)).font(.system(size: TypeScale.body, weight: .semibold))
                                    Text(verbatim: L10n.text(item.subtitle)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(2)
                                    Text(verbatim: L10n.text(status(item.id))).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 6).contentShape(Rectangle()).tag(item.id).listRowSeparator(.hidden).accessibilityIdentifier("solution-" + item.id)
                        }
                    }.sidebarList()
                    Text(verbatim: L10n.text("内置方案 · 模型与服务可替换")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    ScanStatus(store: store)
                }.padding(SidebarMetrics.padding).frame(width: sidebarWidth).clipped().background(Theme.sidebar)
                SidebarResizeHandle(store: store, width: sidebarWidth)
            } else { SidebarRail(store: store) }
            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    configurationSelector
                    Picker(L10n.text("解决方案"), selection: $controller.section) { ForEach(SolutionSection.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 16).padding(.bottom, 20).accessibilityIdentifier("solution-sections")
                    if controller.selectedID == "image-generation", [.overview, .configuration].contains(controller.section) {
                        ImageSolutionEngineView(store: store, installer: store.installation).padding(.bottom, 20)
                    }
                    switch controller.section {
                    case .overview: overview
                    case .configuration: configuration
                    case .instances: instances
                    case .maintenance: maintenance
                    }
                    if let message = controller.message { Text(verbatim: L10n.text(message)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled).padding(.top, 16) }
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }.id(controller.selectedID + controller.section.rawValue + (controller.section == .instances ? "" : controller.latest?.id ?? ""))
            if controller.section == .configuration || (controller.section == .overview && controller.latest.map { !controller.runtime($0, store: store).allReady } == true) {
                Divider()
                actionBar.padding(.horizontal, 30).padding(.vertical, 14).background(Theme.background)
            }
            }
        }.accessibilityIdentifier("solution-workspace")
            .onAppear { if !SolutionCatalog.visible.contains(where: { $0.id == controller.selectedID }) { controller.selectedID = "voice-translation" } }
            .task(id: store.services.records.map { $0.id + String($0.pid ?? 0) + store.services.status($0).rawValue }.joined()) {
                while !Task.isCancelled {
                    await controller.refreshAudioProtocols(store: store)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            .sheet(item: $ui.removal) { record in
                SolutionRemovalSheet(store: store, controller: controller, record: record) { ui.removal = nil }
            }
    }
    private var header: some View {
        HStack(spacing: 18) {
            Image(systemName: controller.definition.symbol).font(.system(size: 28)).foregroundStyle(Theme.linkColor).frame(width: 64, height: 64).background(Theme.selection, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L10n.text(controller.definition.title)).font(.system(size: TypeScale.display, weight: .bold))
                Text(verbatim: L10n.text(controller.definition.subtitle)).font(.system(size: TypeScale.section)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8)
    }
    @ViewBuilder private var configurationSelector: some View {
        if let selected = controller.latest, controller.editingID == nil, [.configuration, .overview].contains(controller.section) {
            let records = controller.deployments.filter { $0.solutionID == controller.selectedID }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: L10n.text("当前配置")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    Picker(L10n.text("当前配置"), selection: Binding(get: { selected.id }, set: { controller.selectDeployment($0, store: store) })) {
                        ForEach(records.reversed()) { record in
                            Text(verbatim: record.created.formatted(date: .abbreviated, time: .shortened) + " · " + String(record.id.prefix(8)) + " · " + L10n.text(record.id == records.last?.id ? "最新配置" : "历史配置")).tag(record.id)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).disabled(controller.preparingID != nil || !controller.startingIDs.isEmpty || !controller.removingIDs.isEmpty).accessibilityIdentifier("solution-current-configuration")
                }
                Text(verbatim: L10n.text("只显示所选配置的状态与接入地址。切换不会停止其他服务。"))
                    .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 12)
        }
    }
    private func status(_ id: String) -> String {
        let records = controller.deployments.filter { $0.solutionID == id }
        guard !records.isEmpty else { return "待安装" }
        let ready = records.filter { $0.state == .configured && controller.runtime($0, store: store).allReady }.count
        return L10n.format("{0} 个实例 · {1} 个可用", [String(records.count), String(ready)])
    }
    private var configuration: some View {
        Group {
            if let record = controller.latest, controller.editingID == nil {
                VStack(alignment: .leading, spacing: 18) {
                    if record.state == .configured { SolutionRuntimeCard(store: store, controller: controller, record: record) }
                    else { deploymentProgress(record) }
                    if record.solutionID != "image-generation" { Text(verbatim: L10n.text("目标语言") + " · " + TranslationLanguages.title(record.draft.language)).font(.system(size: TypeScale.body)) }
                    if record.state == .configured { SolutionGatewayCard(store: store, gateway: store.gateway, deployment: record) }
                }
            } else { configurationEditor }
        }
    }
    private var configurationEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.editingID != nil {
                HStack {
                    Text(verbatim: L10n.text("正在编辑方案配置")).font(.system(size: TypeScale.body, weight: .semibold))
                    Spacer()
                    Button(L10n.text("取消编辑")) { controller.editingID = nil; controller.message = nil }.buttonStyle(.bordered)
                }
                Text(verbatim: L10n.text("保存后更新此方案的接入地址配置；已有运行服务继续保留。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if controller.selectedID != "image-generation" {
            HStack {
                Text(verbatim: L10n.text("输入语言")).foregroundStyle(Theme.muted)
                Picker(L10n.text("输入语言"), selection: Binding(get: { controller.draft.sourceLanguage ?? "auto" }, set: { var draft = controller.draft; draft.sourceLanguage = $0 == "auto" ? nil : $0; controller.setDraft(draft) })) {
                    Text(verbatim: L10n.text("自动检测")).tag("auto")
                    ForEach(TranslationLanguages.targets, id: \.self) { Text(TranslationLanguages.title($0)).tag($0) }
                }.labelsHidden().frame(width: 170)
                Spacer()
            }
            HStack {
                Text(verbatim: L10n.text("目标语言")).foregroundStyle(Theme.muted)
                Picker(L10n.text("目标语言"), selection: Binding(get: { controller.draft.language }, set: { var draft = controller.draft; draft.language = $0; controller.setDraft(draft) })) {
                    ForEach(TranslationLanguages.targets, id: \.self) { Text(TranslationLanguages.title($0)).tag($0) }
                }.labelsHidden().frame(width: 170)
                Spacer()
            }
            Toggle(L10n.text("启用译文配音"), isOn: Binding(get: { controller.draft.speechOutput != false }, set: { var draft = controller.draft; draft.speechOutput = $0; controller.setDraft(draft) })).toggleStyle(.switch)
            } else { ImageSolutionScopeView() }
            HStack {
                Text(verbatim: L10n.text("配套模型与引擎")).font(.system(size: TypeScale.section, weight: .semibold))
                Spacer()
                if controller.definition.roles.contains(.asr) {
                Picker(L10n.text("方案规格"), selection: Binding(get: { controller.draft.quality }, set: { var draft = controller.draft; draft.quality = $0; controller.setDraft(draft) })) {
                    ForEach(SolutionQuality.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220).disabled(controller.preparingID != nil).accessibilityIdentifier("solution-quality")
                }
            }
            if controller.roles.contains(where: SolutionRecommendations.usesBaseline) {
                Text(verbatim: L10n.text("Qwen3.8-27B 是默认推荐，可更换本地模型或复用已有兼容服务，无需重复下载。翻译效果可在方案中试用。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(controller.roles, id: \.rawValue) { role in
                    componentRow(role)
                    if role != controller.roles.last { Divider().padding(.leading, 64) }
                }
            }.background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            if controller.roles.contains(.tts) {
                Text(verbatim: L10n.text("配音使用输入音频的参考音色；试用时需提供清晰的单人录音。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(L10n.text("更多设置")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(verbatim: L10n.text("保存到模型库")).font(.system(size: TypeScale.body))
                        Spacer()
                        Button(L10n.text("选择目录…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let path = panel.url?.path { var draft = controller.draft; draft.destination = path; controller.setDraft(draft) } }.buttonStyle(.bordered)
                    }
                    Text(verbatim: controller.draft.destination ?? store.downloads.destination).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    Text(verbatim: L10n.text("模型固定到方案登记的提交版本；已安装基座不自动升级。不同配置会独立保存。"))
                        .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("全局引擎设置")) { store.showGlobalEngines = true }.buttonStyle(PlainAction())
                }.padding(.top, 10)
            }.font(.system(size: TypeScale.body)).padding(.vertical, 4)
            if let deployment = controller.latest, deployment.state == .configured, controller.usesCurrentRecommendations(deployment) { SolutionGatewayCard(store: store, gateway: store.gateway, deployment: deployment) }
        }
    }
    private func componentRow(_ role: SolutionRole) -> some View {
        let selection = try? controller.selection(role, draft: controller.draft, store: store)
        let local = selection?.modelID.flatMap { id in store.models.first { $0.id == id } }
        let selectedService = selection?.serviceBinding.flatMap { _ in store.services.records.first { $0.id == selection?.serviceID } }
        let deployed = controller.latest.flatMap { record in
            record.draft == controller.draft && controller.usesCurrentRecommendations(record) ? record.components.first { $0.role == role } : nil
        }
        let job = deployed?.downloadID.flatMap { id in store.downloads.jobs.first { $0.id == id } }
        let inspect = local ?? deployed?.modelID.flatMap { id in store.models.first { $0.id == id } }
        let installingEngine = controller.latest?.state == .installing && controller.latest?.progress?.engineID == selection?.engineID
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: [.asr, .tts].contains(role) ? "waveform" : [.vision, .image].contains(role) ? "photo" : "cube").font(.system(size: 20)).foregroundStyle(Theme.muted).frame(width: 40, height: 40).background(Theme.line, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: L10n.text(role.rawValue)).font(.system(size: TypeScale.body, weight: .semibold))
                    Text(verbatim: selection?.serviceBinding?.model ?? local?.name ?? selection?.repository.components(separatedBy: "/").last ?? L10n.text("请重新选择模型"))
                        .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(verbatim: store.engines.first { $0.id == selection?.engineID }?.name ?? "—").font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                    if SolutionRecommendations.usesBaseline(role) {
                        Text(verbatim: L10n.text(SolutionRecommendations.label(role, draft: controller.draft, model: local)))
                            .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 6)
                Text(verbatim: L10n.text(selectedService.map { "复用服务 · " + String($0.port) } ?? (installingEngine ? "正在安装引擎" : job?.state.rawValue ?? (local == nil ? "待下载" : "可复用")))).font(.system(size: TypeScale.callout)).foregroundStyle(local == nil && selectedService == nil ? Theme.muted : Theme.successText)
                Menu(L10n.text("更换")) {
                    let services = controller.serviceChoices(role, store: store)
                    if !services.isEmpty {
                        Section(L10n.text("复用已有兼容服务")) {
                            ForEach(services) { item in Button(serviceChoiceTitle(item, store: store)) { choose(role, value: item.id) } }
                        }
                        Divider()
                    }
                    Button(L10n.text("优先复用推荐模型")) { choose(role, value: nil) }
                    Button(L10n.text("下载方案默认模型")) { choose(role, value: "download") }
                    if role == .image { Button("Turbo · Heretic MLX") { choose(role, value: "heretic") } }
                    if SolutionRecommendations.usesBaseline(role) { Button(L10n.text("选择轻量备选模型")) { choose(role, value: SolutionRecommendations.lightweightChoice) } }
                    if let inspect { Button(L10n.text("管理模型文件")) { store.showModelFile(inspect) } }
                    Divider()
                    let choices = controller.choices(role, store: store)
                    let recommended = choices.filter { SolutionRecommendations.matches($0.model, role: role, draft: controller.draft) }
                    if !recommended.isEmpty {
                        Section(L10n.text("推荐模型 · 已安装")) {
                            ForEach(recommended) { item in Button(item.model.name + " · " + item.engine.name) { choose(role, value: item.id) } }
                        }
                    }
                    let other = choices.filter { !SolutionRecommendations.matches($0.model, role: role, draft: controller.draft) }
                    if !other.isEmpty {
                        Section(L10n.text("其他本地模型 · 手动选择")) {
                            ForEach(other) { item in Button(item.model.name + " · " + item.engine.name) { choose(role, value: item.id) } }
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize().disabled(controller.preparingID != nil).accessibilityIdentifier("solution-model-" + role.rawValue)
            }
            if let job {
                if job.totalKnown && job.total > 0 { ProgressView(value: Double(min(job.received, job.total)), total: Double(job.total)).tint(Theme.accent) }
                else if job.state == .downloading { ProgressView().progressViewStyle(.linear).tint(Theme.accent) }
                HStack {
                    Text(verbatim: L10n.text(job.percentageLabel)).monospacedDigit()
                    Text(verbatim: sizeLabel(job.received) + " / " + (job.totalKnown ? sizeLabel(job.total) : L10n.text("大小待确认"))).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(L10n.text("查看下载")) { store.downloads.showTask(job.id); store.tab = .downloads }.buttonStyle(PlainAction())
                }.font(.system(size: TypeScale.callout))
            }
            if let local, store.modelInstanceCounts(local, engineID: selection?.engineID).total > 0 { ModelInstancesLink(store: store, model: local, engineID: selection?.engineID, compact: true) }
        }.padding(12).accessibilityIdentifier("solution-component-" + role.rawValue)
    }
    private func choose(_ role: SolutionRole, value: String?) { var draft = controller.draft; draft.localChoices[role.rawValue] = value; controller.setDraft(draft) }
    private func deploymentProgress(_ record: SolutionDeployment) -> some View {
        SolutionInstallationCard(store: store, controller: controller, record: record)
    }
    private var actionBar: some View {
        Group {
            if let record = controller.latest, controller.editingID == nil {
                let runtime = controller.runtime(record, store: store)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: record.state == .configured ? runtime.title : L10n.text(record.stage)).font(.system(size: TypeScale.body, weight: .medium))
                        Text(verbatim: L10n.text(runtime.needsConfiguration ? "先修改不兼容的组件，再启动此配置。" : runtime.needsReload ? "保留模型文件，更新旧语音组件后启动此配置。" : "复用服务会一并启动；按组件检查就绪状态。" )).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if controller.startingIDs.contains(record.id) { ProgressView().controlSize(.small) }
                    Button(L10n.text(record.state == .configured ? runtime.allReady ? (record.solutionID == "image-generation" ? "打开生图" : "打开实时翻译") : runtime.actionTitle : "继续准备并启动")) {
                        if record.state == .configured {
                            if runtime.allReady { store.openSolutionExperience(record) }
                            else { controller.activate(record, store: store) }
                        } else { controller.edit(record.id, store: store); controller.install(store: store, launchWhenReady: true) }
                    }.buttonStyle(AccentButton()).disabled(controller.preparingID != nil || controller.startingIDs.contains(record.id) || !controller.removingIDs.isEmpty || store.scanning).accessibilityIdentifier("solution-primary-action")
                }
            } else if controller.section == .configuration { editorActionBar }
        }
    }
    private var editorActionBar: some View {
        let record = controller.latest
        let current = record.map(controller.usesCurrentRecommendations) ?? true
        let configured = controller.editingID == nil && current && record?.state == .configured && record?.draft == controller.draft
        let installing = current && record?.draft == controller.draft && record.map { [.preparing, .installing, .downloading].contains($0.state) } == true
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: L10n.text(installing ? record!.stage : configured ? "安装完成，按需启动组件" : "安装缺少的组件并创建服务配置")).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(2)
                    Text(verbatim: installing ? store.solutionProgress(record!).metric + " · " + store.solutionProgress(record!).percentage : L10n.text("复用本地模型与可恢复任务，保留正在运行的实例。"))
                        .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if configured, let record {
                    Button { controller.start(record.id, store: store) } label: { Label(L10n.text("启动方案"), systemImage: "play.fill") }.buttonStyle(AccentButton()).disabled(controller.runtime(record, store: store).allReady)
                } else {
                    if controller.editingID != nil { Button(L10n.text("保存配置")) { controller.install(store: store) }.buttonStyle(.bordered).disabled(store.scanning || controller.preparingID != nil) }
                    Button { controller.install(store: store, launchWhenReady: true) } label: { Label(L10n.text(controller.editingID != nil ? "保存并启动" : "安装并启动"), systemImage: "play.fill") }.buttonStyle(AccentButton()).disabled(store.scanning || controller.preparingID != nil).accessibilityIdentifier("install-solution")
                }
            }
            if configured { Button(L10n.text("查看实例与试用")) { controller.section = .instances }.buttonStyle(PlainAction()) }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: L10n.text(controller.selectedID == "image-generation" ? "输入提示词生成图片；支持进度、取消、种子和 PNG 保存。模型加载和生成速度取决于本机配置。" : "使用麦克风逐段识别和翻译，显示实时字幕；也可以翻译音频文件。速度取决于本机模型和语音长度。" )).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L10n.text("方案模型与已有兼容服务均可替换。选择下载时固定模型版本；复用服务时保留原端口和参数。"))
                .font(.system(size: TypeScale.body)).fixedSize(horizontal: false, vertical: true)
            if controller.latest == nil { Button(L10n.text("配置方案")) { controller.section = .configuration }.buttonStyle(.bordered) }
            if let record = controller.latest, record.state == .configured {
                SolutionRuntimeCard(store: store, controller: controller, record: record)
                SolutionExperienceEntry(store: store, record: record)
                if record.solutionID == "image-generation" {
                    SolutionGatewayCard(store: store, gateway: store.gateway, deployment: record)
                }
            }
        }
    }
    private var instances: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.text("每个实例有独立配置和网关地址，可以共享模型服务。展开查看各自状态与操作。"))
                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(controller.deployments.filter { $0.solutionID == controller.selectedID }.reversed()) { record in
                SolutionInstanceCard(store: store, controller: controller, record: record) { ui.removal = record }
            }
            if controller.latest == nil { Text(verbatim: L10n.text("安装方案后在此查看组件实例。" )).foregroundStyle(Theme.muted) }
        }
    }
    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.text("移除方案只清除配置；模型、下载任务和基座可在各自页面管理。共享组件保留。"))
                .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(controller.deployments.filter { $0.solutionID == controller.selectedID }.reversed()) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: record.created.formatted(date: .abbreviated, time: .shortened)).font(.system(size: TypeScale.body))
                        Text(verbatim: L10n.text(record.stage)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if record.state == .failed || record.state == .paused { Button(L10n.text("继续安装")) { controller.retry(record.id, store: store) }.buttonStyle(.bordered) }
                    Button(L10n.text("删除实例"), role: .destructive) { ui.removal = record }.buttonStyle(.bordered).disabled(controller.preparingID != nil || !controller.startingIDs.isEmpty || !controller.removingIDs.isEmpty)
                }.padding(12).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
            let historical = controller.deployments.filter { record in !SolutionCatalog.visible.contains { $0.id == record.solutionID } }
            if !historical.isEmpty {
                DisclosureGroup(L10n.text("已隐藏方案的历史配置")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: L10n.text("旧方案暂不提供新建入口；已有服务和模型保留，可单独管理。"))
                            .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        ForEach(historical) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(verbatim: L10n.text(SolutionCatalog.all.first { $0.id == record.solutionID }?.title ?? record.solutionID)).font(.system(size: TypeScale.body, weight: .medium))
                                    Spacer()
                                    Button(L10n.text("删除实例"), role: .destructive) { ui.removal = record }.buttonStyle(.bordered)
                                }
                                ForEach(controller.services(record, store: store)) { spec in
                                    HStack { Text(verbatim: store.serviceDisplayName(spec)).lineLimit(1); Spacer(); Button(L10n.text("查看详情")) { store.showService(spec) }.buttonStyle(PlainAction()) }
                                        .font(.system(size: TypeScale.callout))
                                }
                            }.padding(12).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.top, 12)
                }
            }
        }
    }
}

@MainActor struct SolutionTrialView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var trial: SolutionTrialController
    var deployment: SolutionDeployment
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L10n.text("试用方案")).font(.system(size: TypeScale.section, weight: .semibold))
            Picker(L10n.text("试用接入方式"), selection: $trial.connection) {
                ForEach(SolutionTrialConnection.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).fixedSize().disabled(trial.busy).accessibilityIdentifier("solution-trial-connection")
            if trial.connection == .gateway {
                Text(verbatim: store.gateway.solutionEndpoint(deployment)).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !store.gateway.solutionReady(deployment) {
                    HStack {
                        Text(verbatim: L10n.text(store.gateway.ready && !store.gateway.supportsSolutionRoutes ? "重启网关后启用方案地址" : "请先启动方案网关并等待组件就绪")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        if !store.gateway.ownsProcess() { Button(L10n.text("启动网关")) { store.gateway.start(store: store) }.buttonStyle(.bordered).disabled(store.gateway.busy) }
                        else if store.gateway.ready && !store.gateway.supportsSolutionRoutes { Button(L10n.text("重启网关")) { store.gateway.restartForSolutions(store: store) }.buttonStyle(.bordered).disabled(store.gateway.busy || store.gateway.active > 0) }
                    }
                }
            }
            if deployment.solutionID != "coding" {
                HStack {
                    Button(L10n.text(deployment.solutionID == "vision" ? "选择图片…" : "选择音频文件…")) { trial.chooseFile(image: deployment.solutionID == "vision") }.buttonStyle(.bordered).disabled(trial.busy)
                    Text(trial.input?.lastPathComponent ?? L10n.text("尚未选择文件")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            if deployment.solutionID == "coding" || deployment.solutionID == "vision" { TextField(L10n.text("试用问题"), text: $trial.query, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4).disabled(trial.busy) }
            HStack {
                Button(L10n.text("开始试用")) { trial.run(deployment, store: store) }.buttonStyle(.bordered).disabled(trial.busy || deployment.state != .configured || !store.solutions.runtime(deployment, store: store).allReady || (trial.connection == .gateway && !store.gateway.solutionReady(deployment)))
                if trial.busy { ProgressView().controlSize(.small); Button(L10n.text("取消")) { trial.cancel() }.buttonStyle(.bordered) }
                Text(verbatim: L10n.text(trial.phase)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
            if !trial.transcript.isEmpty { Text(verbatim: L10n.text("识别原文")).font(.system(size: TypeScale.body, weight: .medium)); Text(trial.transcript).font(.system(size: TypeScale.body)).textSelection(.enabled) }
            if !trial.translation.isEmpty { Text(verbatim: L10n.text("模型输出")).font(.system(size: TypeScale.body, weight: .medium)); Text(trial.translation).font(.system(size: TypeScale.body)).textSelection(.enabled) }
            if let audio = trial.output { Button(L10n.text("播放生成的配音")) { NSWorkspace.shared.open(audio) }.buttonStyle(PlainAction()) }
            if let error = trial.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
        }
    }
}
