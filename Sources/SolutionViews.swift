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
                        ForEach(SolutionCatalog.all.filter { controller.search.isEmpty || L10n.text($0.title).localizedCaseInsensitiveContains(controller.search) || L10n.text($0.subtitle).localizedCaseInsensitiveContains(controller.search) }) { item in
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
                    Text(verbatim: L10n.text("内置方案 · 固定模型版本")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    ScanStatus(store: store)
                }.padding(SidebarMetrics.padding).frame(width: sidebarWidth).clipped().background(Theme.sidebar)
                SidebarResizeHandle(store: store, width: sidebarWidth)
            } else { SidebarRail(store: store) }
            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Picker(L10n.text("解决方案"), selection: $controller.section) { ForEach(SolutionSection.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 16).padding(.bottom, 20).accessibilityIdentifier("solution-sections")
                    switch controller.section {
                    case .overview: overview
                    case .configuration: configuration
                    case .instances: instances
                    case .maintenance: maintenance
                    }
                    if let message = controller.message { Text(verbatim: L10n.text(message)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled).padding(.top, 16) }
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }.id(controller.selectedID + controller.section.rawValue)
            if controller.section == .configuration {
                Divider()
                actionBar.padding(.horizontal, 30).padding(.vertical, 14).background(Theme.background)
            }
            }
        }.accessibilityIdentifier("solution-workspace")
            .alert(L10n.text("移除方案配置"), isPresented: Binding(get: { ui.removal != nil }, set: { if !$0 { ui.removal = nil } })) {
                Button(L10n.text("移除"), role: .destructive) { if let record = ui.removal { controller.remove(record.id, store: store) }; ui.removal = nil }
                Button(L10n.text("取消"), role: .cancel) { ui.removal = nil }
            } message: { Text(verbatim: L10n.text("保留模型、下载任务、引擎和其他方案使用的服务配置。")) }
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
    private func status(_ id: String) -> String {
        guard let record = controller.deployments.last(where: { $0.solutionID == id }) else { return "待安装" }
        let progress = store.solutionProgress(record)
        if progress.phase == .models, progress.fraction != nil { return L10n.text(record.stage) + " · " + progress.percentage }
        return record.stage
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let record = controller.latest, record.draft == controller.draft { deploymentProgress(record) }
            HStack {
                Text(verbatim: L10n.text("配套模型与引擎")).font(.system(size: TypeScale.section, weight: .semibold))
                Spacer()
                if controller.definition.roles.contains(.asr) {
                Picker(L10n.text("方案规格"), selection: Binding(get: { controller.draft.quality }, set: { var draft = controller.draft; draft.quality = $0; controller.setDraft(draft) })) {
                    ForEach(SolutionQuality.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220).disabled(controller.preparingID != nil).accessibilityIdentifier("solution-quality")
                }
            }
            VStack(spacing: 0) {
                ForEach(controller.definition.roles, id: \.rawValue) { role in
                    componentRow(role)
                    if role != controller.definition.roles.last { Divider().padding(.leading, 64) }
                }
            }.background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            if controller.definition.roles.contains(.tts) {
                HStack {
                    Text(verbatim: L10n.text("目标语言")).foregroundStyle(Theme.muted)
                    Picker(L10n.text("目标语言"), selection: Binding(get: { controller.draft.language }, set: { var draft = controller.draft; draft.language = $0; controller.setDraft(draft) })) {
                        ForEach(["English", "Chinese", "French", "Portuguese"], id: \.self) { value in Text(["English": "English", "Chinese": "中文", "French": "Français", "Portuguese": "Português"][value] ?? value).tag(value) }
                    }.labelsHidden().frame(width: 170)
                    Spacer()
                }.font(.system(size: TypeScale.body))
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
            if let deployment = controller.latest, deployment.state == .configured { SolutionGatewayCard(store: store, gateway: store.gateway, deployment: deployment) }
        }
    }
    private func componentRow(_ role: SolutionRole) -> some View {
        let selection = try? controller.selection(role, draft: controller.draft, store: store)
        let local = selection?.modelID.flatMap { id in store.models.first { $0.id == id } }
        let deployed = controller.latest?.draft == controller.draft ? controller.latest?.components.first { $0.role == role } : nil
        let job = deployed?.downloadID.flatMap { id in store.downloads.jobs.first { $0.id == id } }
        let inspect = local ?? deployed?.modelID.flatMap { id in store.models.first { $0.id == id } }
        let installingEngine = controller.latest?.state == .installing && controller.latest?.progress?.engineID == selection?.engineID
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: [.asr, .tts].contains(role) ? "waveform" : role == .vision ? "photo" : "cube").font(.system(size: 20)).foregroundStyle(Theme.muted).frame(width: 40, height: 40).background(Theme.line, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: L10n.text(role.rawValue)).font(.system(size: TypeScale.body, weight: .semibold))
                    Text(verbatim: local?.name ?? selection?.repository.components(separatedBy: "/").last ?? L10n.text("请重新选择模型"))
                        .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(verbatim: store.engines.first { $0.id == selection?.engineID }?.name ?? "—").font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 6)
                Text(verbatim: L10n.text(installingEngine ? "正在安装引擎" : job?.state.rawValue ?? (local == nil ? "待下载" : "可复用"))).font(.system(size: TypeScale.callout)).foregroundStyle(local == nil ? Theme.muted : Theme.successText)
                Menu(L10n.text("更换")) {
                    Button(L10n.text("自动选择并复用")) { choose(role, value: nil) }
                    Button(L10n.text("下载方案默认模型")) { choose(role, value: "download") }
                    if let inspect { Button(L10n.text("管理模型文件")) { store.showModelFile(inspect) } }
                    Divider()
                    ForEach(controller.choices(role, store: store)) { item in Button(item.model.name + " · " + item.engine.name) { choose(role, value: item.id) } }
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
        let record = controller.latest
        let configured = record?.state == .configured && record?.draft == controller.draft
        let installing = record?.draft == controller.draft && record.map { [.preparing, .installing, .downloading].contains($0.state) } == true
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: L10n.text(installing ? record!.stage : configured ? "安装完成，按需启动组件" : "安装缺少的组件并创建服务配置")).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(2)
                    Text(verbatim: installing ? store.solutionProgress(record!).metric + " · " + store.solutionProgress(record!).percentage : L10n.text("复用本地模型与可恢复任务，保留正在运行的实例。"))
                        .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if configured, let record {
                    Button { controller.start(record.id, store: store) } label: { Label(L10n.text("启动方案"), systemImage: "play.fill") }.buttonStyle(AccentButton()).disabled(controller.services(record, store: store).allSatisfy { $0.pid != nil })
                } else {
                    Button { controller.install(store: store) } label: { Label(L10n.text(installing ? "安装进行中" : record?.draft == controller.draft && (record.map { [.paused, .failed].contains($0.state) } ?? false) ? "继续安装" : "一键安装并配置"), systemImage: "arrow.down.circle") }.buttonStyle(AccentButton()).disabled(store.scanning || controller.preparingID != nil || (record?.draft == controller.draft && record?.state == .downloading)).accessibilityIdentifier("install-solution")
                }
            }
            if configured { Button(L10n.text("查看实例与试用")) { controller.section = .instances }.buttonStyle(PlainAction()) }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: L10n.text(controller.definition.id == "voice-translation" ? "选择音频文件，识别原文、翻译内容，再使用输入音频的参考音色朗读译文。" : controller.definition.id == "vision" ? "安装视觉模型，处理图片和文档截图；媒体能力由模型与运行组件共同决定。" : controller.definition.subtitle)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L10n.text("方案会固定模型版本，检查配套文件，安装缺少的基座，并配置独立端口。"))
                .font(.system(size: TypeScale.body)).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("配置方案")) { controller.section = .configuration }.buttonStyle(.bordered)
            if let record = controller.latest, record.state == .configured { SolutionTrialView(store: store, trial: store.solutionTrial, deployment: record) }
        }
    }
    private var instances: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(controller.deployments.filter { $0.solutionID == controller.selectedID }.reversed()) { record in
                Text(verbatim: record.created.formatted(date: .abbreviated, time: .shortened)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                SolutionGatewayCard(store: store, gateway: store.gateway, deployment: record)
                ForEach(controller.services(record, store: store)) { spec in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(spec.modelName).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1)
                            Spacer()
                            StateLabel(title: store.services.statusTitle(spec), color: store.services.status(spec).color)
                        }
                        Text(verbatim: "127.0.0.1:\(spec.port)/v1").font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted)
                        ServiceOriginBadges(store: store, spec: spec)
                        HStack {
                            Button(L10n.text("查看详情")) { store.showService(spec) }.buttonStyle(PlainAction())
                            Button(L10n.text("运行引擎")) { if let model = store.models.first(where: { $0.id == spec.modelID }) { store.showModelInstances(model, engineID: spec.engineID) } else { store.chooseEngine(spec.engineID); store.engineSection = .services; store.tab = .engines } }.buttonStyle(PlainAction())
                            Spacer()
                            Text(verbatim: L10n.text(record.components.contains(where: { $0.serviceID == spec.id && !$0.ownsConfiguration }) ? "复用的服务" : "方案创建的服务")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                        }
                    }.padding(18).background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1) }
                }
                HStack {
                    Button(L10n.text("启动方案")) { controller.start(record.id, store: store) }.buttonStyle(.bordered).disabled(record.state != .configured)
                    Button(L10n.text("停止本方案启动的实例")) { controller.stop(record.id, store: store) }.buttonStyle(.bordered).disabled(!record.processes.contains { owned in store.services.records.contains { $0.id == owned.serviceID && $0.pid == owned.pid && $0.processStart == owned.birth } })
                }
            }
            if controller.latest == nil { Text(verbatim: L10n.text("安装方案后在此查看组件实例。" )).foregroundStyle(Theme.muted) }
            if let record = controller.latest, record.state == .configured { Divider(); SolutionTrialView(store: store, trial: store.solutionTrial, deployment: record) }
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
                    Button(L10n.text("移除方案配置"), role: .destructive) { ui.removal = record }.buttonStyle(.bordered).disabled(controller.preparingID == record.id || controller.services(record, store: store).contains { spec in spec.pid != nil && record.components.contains { $0.serviceID == spec.id && $0.ownsConfiguration } && !controller.deployments.contains { $0.id != record.id && $0.components.contains { $0.serviceID == spec.id } } })
                }.padding(12).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
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
                Button(L10n.text("开始试用")) { trial.run(deployment, store: store) }.buttonStyle(.bordered).disabled(trial.busy || deployment.state != .configured || deployment.components.isEmpty || deployment.components.contains { component in !store.solutions.services(deployment, store: store).contains { $0.id == component.serviceID && store.services.status($0) == .running } } || (trial.connection == .gateway && !store.gateway.solutionReady(deployment)))
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
