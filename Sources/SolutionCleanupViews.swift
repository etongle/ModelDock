import SwiftUI

@MainActor private final class SolutionCleanupViewState: ObservableObject {
    @Published var plan: SolutionCleanupPlan?
    @Published var selection = SolutionCleanupSelection()
    @Published var error: String?
}

@MainActor struct SolutionRemovalSheet: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: SolutionController
    var record: SolutionDeployment
    var dismiss: () -> Void
    @StateObject private var ui = SolutionCleanupViewState()
    private var busy: Bool { controller.preparingID != nil || !controller.startingIDs.isEmpty || !controller.removingIDs.isEmpty || store.maintaining || store.installation.running }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.text("删除方案实例")).font(.system(size: TypeScale.section, weight: .semibold))
            Text(verbatim: record.created.formatted(date: .abbreviated, time: .shortened) + " · " + String(record.id.prefix(8)))
                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            Text(verbatim: L10n.text("默认仅移除实例及其网关地址。服务配置、模型文件和基座全部保留。"))
                .font(.system(size: TypeScale.body)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    services
                    if let plan = ui.plan {
                        Divider()
                        models(plan)
                        Divider()
                        engines(plan)
                    } else { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text("正在检查资源归属与引用…")) }.padding(.vertical, 12) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 440)
            if let error = ui.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Text(verbatim: L10n.format("已选 {0} 项额外清理；未勾选的项目保留", [String(ui.selection.count)]))
                    .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button(L10n.text("取消"), action: dismiss).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button(L10n.text(ui.selection.count == 0 ? "只删除实例" : "删除并清理所选项"), role: .destructive, action: confirm)
                    .buttonStyle(.bordered).disabled(busy || ui.plan == nil).accessibilityIdentifier("confirm-remove-solution-instance")
            }
        }.padding(24).frame(width: 660).accessibilityIdentifier("solution-instance-removal")
            .task(id: record.id) { ui.plan = await controller.cleanupPlan(record, store: store) }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L10n.text("可选：停止并删除服务配置")).font(.system(size: TypeScale.body, weight: .semibold))
            Text(verbatim: L10n.text("只允许选择此实例独占创建的服务；权重与基座由下方选项单独控制。"))
                .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
            ForEach(controller.removalItems(record, store: store)) { item in
                let blocker = controller.cleanupServiceBlocker(item.id, record: record, store: store)
                cleanupToggle(title: item.service.modelName + " · " + String(item.service.port), detail: blocker ?? "仅删除服务配置，模型文件保留", selected: binding(item.id, group: .services), blocker: blocker, id: "cleanup-service-" + item.id)
            }
        }
    }

    private func models(_ plan: SolutionCleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L10n.text("可选：模型文件移至废纸篓")).font(.system(size: TypeScale.body, weight: .semibold))
            Text(verbatim: L10n.text("只处理选中的模型版本；其他版本及共享缓存保留，可从废纸篓恢复。"))
                .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
            ForEach(plan.models) { item in
                let blocker = controller.cleanupModelBlocker(item, record: record, selection: ui.selection, store: store)
                cleanupToggle(title: item.model.name, detail: blocker ?? "未发现其他引用，可选清理", selected: binding(item.id, group: .models), blocker: blocker, id: "cleanup-model-" + item.id)
            }
            if plan.models.isEmpty { Text(verbatim: L10n.text("未找到可单独清理的模型文件")).foregroundStyle(Theme.muted) }
        }
    }

    private func engines(_ plan: SolutionCleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L10n.text("可选：卸载基座程序")).font(.system(size: TypeScale.body, weight: .semibold))
            Text(verbatim: L10n.text("模型、缓存与个人设置保留。Homebrew 程序由包管理器卸载，恢复需重新安装。"))
                .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
            ForEach(plan.engines) { engine in
                let blocker = controller.cleanupEngineBlocker(engine, record: record, selection: ui.selection, store: store)
                cleanupToggle(title: engine.engine.name + " · " + engine.engine.version, detail: blocker ?? "未发现其他引用，可选清理", selected: binding(engine.engine.id, group: .engines), blocker: blocker, id: "cleanup-engine-" + engine.engine.id)
            }
            if plan.engines.isEmpty { Text(verbatim: L10n.text("未找到可独立卸载的程序，请在运行引擎页管理")).foregroundStyle(Theme.muted) }
        }
    }

    private enum Group { case services, models, engines }
    private func binding(_ id: String, group: Group) -> Binding<Bool> {
        Binding(get: {
            switch group { case .services: return ui.selection.services.contains(id); case .models: return ui.selection.models.contains(id); case .engines: return ui.selection.engines.contains(id) }
        }, set: { selected in
            ui.error = nil
            switch group {
            case .services: if selected { ui.selection.services.insert(id) } else { ui.selection.services.remove(id) }
            case .models: if selected { ui.selection.models.insert(id) } else { ui.selection.models.remove(id) }
            case .engines: if selected { ui.selection.engines.insert(id) } else { ui.selection.engines.remove(id) }
            }
        })
    }

    private func cleanupToggle(title: String, detail: String, selected: Binding<Bool>, blocker: String?, id: String) -> some View {
        Toggle(isOn: selected) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(2)
                Text(verbatim: L10n.text(detail)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 4)
        }.toggleStyle(.checkbox).disabled(blocker != nil && !selected.wrappedValue).accessibilityIdentifier(id)
    }

    private func confirm() {
        guard let plan = ui.plan else { return }
        do {
            try controller.validateCleanup(plan, selection: ui.selection, store: store)
            if controller.removeInstance(record.id, store: store, plan: plan, selection: ui.selection) { dismiss() }
            else { ui.error = controller.message ?? "请等待当前方案操作完成" }
        } catch { ui.error = error.localizedDescription }
    }
}
