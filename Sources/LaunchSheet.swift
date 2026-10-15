import SwiftUI

/// The single "start a model service" flow. Engine and model pickers sit above the existing LaunchPanel,
/// which keeps owning port, context, input mode, components and validation. Once the service has a
/// process, the sheet closes and Services shows its startup progress.
@MainActor
struct LaunchSheet: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: L10n.text("启动模型服务")).font(.system(size: TypeScale.section, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(verbatim: L10n.text("运行引擎")).foregroundStyle(.secondary)
                    Picker(L10n.text("运行引擎"), selection: Binding(get: { store.engineID }, set: { store.chooseEngine($0) })) {
                        ForEach(store.enabledEngines) { Text(verbatim: L10n.text($0.name)).tag($0.id) }
                    }.labelsHidden().fixedSize()
                }
                GridRow {
                    Text(verbatim: L10n.text("模型文件")).foregroundStyle(.secondary)
                    if store.compatibleModels.isEmpty {
                        Text(verbatim: L10n.text("没有兼容的本地模型")).foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.text("模型文件"), selection: Binding(get: { store.selectedModel?.id ?? "" }, set: { id in if let model = store.compatibleModels.first(where: { $0.id == id }) { store.selectModel(model) } })) {
                            ForEach(store.compatibleModels) { Text($0.name).tag($0.id) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }.font(.system(size: TypeScale.body))
            LaunchPanel(store: store, services: services)
            HStack { Spacer(); Button(L10n.text("完成")) { store.showLaunch = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 760).environment(\.locale, L10n.locale)
        .onChange(of: store.currentService?.pid) { _, pid in
            guard pid != nil, let spec = store.currentService else { return }
            store.showLaunch = false; store.showService(spec)
        }
    }
}
