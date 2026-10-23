import SwiftUI

@MainActor private final class SolutionInstanceViewState: ObservableObject { @Published var expanded = false; @Published var hovered = false }

@MainActor struct SolutionInstanceCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: SolutionController
    var record: SolutionDeployment
    var onRemove: () -> Void
    @StateObject private var ui = SolutionInstanceViewState()
    private var snapshot: SolutionRuntimeSnapshot { controller.runtime(record, store: store) }
    private var busy: Bool { controller.preparingID != nil || !controller.startingIDs.isEmpty || !controller.removingIDs.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if ui.expanded {
            VStack(alignment: .leading, spacing: 16) {
                if record.state == .configured {
                    SolutionRuntimeCard(store: store, controller: controller, record: record)
                    SolutionGatewayCard(store: store, gateway: store.gateway, deployment: record)
                } else { SolutionInstallationCard(store: store, controller: controller, record: record) }
                DisclosureGroup(L10n.text("服务与端口详情")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.services(record, store: store)) { service in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(verbatim: store.serviceDisplayName(service)).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(2)
                                    Spacer(minLength: 6)
                                    StateLabel(title: store.services.statusTitle(service), color: store.services.status(service).color)
                                }
                                Text(verbatim: "127.0.0.1:\(service.port)/v1").font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted)
                                HStack {
                                    ServiceOriginBadges(store: store, spec: service)
                                    Spacer(minLength: 6)
                                    Text(verbatim: L10n.format("被 {0} 个实例使用", [String(store.serviceOrigin(service).uses.count)]))
                                        .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                                }
                                HStack {
                                    Button(L10n.text("查看详情")) { store.showService(service) }.buttonStyle(PlainAction())
                                    Button(L10n.text("运行引擎")) { store.chooseEngine(service.engineID); store.engineSection = .services; store.tab = .engines }.buttonStyle(PlainAction())
                                }
                            }.padding(12).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.top, 10)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
                Text(verbatim: L10n.text("停止只影响此实例独占启动的进程；删除时可单独勾选清理项目。"))
                    .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 16)
            }
        }.padding(12).background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
            .accessibilityIdentifier("solution-instance-" + record.id)
            .onAppear { if controller.selectedDeploymentID == record.id { ui.expanded = true } }
    }
    private var header: some View {
        Button { ui.expanded.toggle() } label: {
            HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(verbatim: L10n.format("实例 {0}", [String(record.id.prefix(8))])).font(.system(size: TypeScale.body, weight: .semibold))
                    if controller.latest?.id == record.id { Text(verbatim: L10n.text("当前使用")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.linkColor) }
                    Spacer(minLength: 4)
                    if controller.removingIDs.contains(record.id) { ProgressView().controlSize(.small) }
                }
                Text(verbatim: record.created.formatted(date: .abbreviated, time: .shortened) + (record.solutionID == "image-generation" ? "" : " · " + TranslationLanguages.title(record.draft.language)))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                Text(verbatim: record.state == .configured ? snapshot.title : L10n.text(record.stage))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(snapshot.allReady ? Theme.successText : Theme.muted)
            }
            Label(L10n.text(ui.expanded ? "收起" : "展开"), systemImage: ui.expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: TypeScale.callout, weight: .medium)).foregroundStyle(Theme.linkColor)
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(12)
                .background(ui.hovered ? Theme.line.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { ui.hovered = $0 }
            .accessibilityValue(L10n.text(ui.expanded ? "已展开" : "已折叠"))
            .accessibilityIdentifier("toggle-solution-instance-" + record.id)
    }
    @ViewBuilder private var actions: some View {
        if record.state == .configured {
            Button(L10n.text(snapshot.allReady ? "使用此实例" : snapshot.actionTitle)) {
                if snapshot.allReady { store.openSolutionExperience(record) }
                else { controller.activate(record, store: store) }
            }.buttonStyle(AccentButton()).disabled(busy).accessibilityIdentifier("start-solution-instance-" + record.id)
            Button(L10n.text("停止独占服务")) { controller.stop(record.id, store: store) }
                .buttonStyle(.bordered).disabled(busy || controller.stoppableServices(record, store: store).isEmpty)
        } else if [.failed, .paused].contains(record.state) {
            Button(L10n.text("继续安装")) { controller.retry(record.id, store: store) }.buttonStyle(.bordered).disabled(busy)
        }
        Button(L10n.text("删除实例"), role: .destructive, action: onRemove).buttonStyle(.bordered).disabled(busy)
            .accessibilityIdentifier("remove-solution-instance-" + record.id)
    }
}
