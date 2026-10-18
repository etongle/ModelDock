import Foundation
import SwiftUI

struct EngineConfiguration: Codable, Hashable {
    var enabled: Bool? = nil
    var port: Int? = nil
    var context: Int? = nil
    var inputMode: InputMode? = nil
    var gpu: Bool? = nil
    var ane: Bool? = nil
    var draftPath: String? = nil
    var maximumLoadedModels: Int? = nil
    var strataDraft: Bool? = nil
    var strataSpeculation: Int? = nil
    var isEnabled: Bool { enabled ?? true }
}

@MainActor
final class EngineConfigurationDraft: ObservableObject, Identifiable {
    let id = UUID()
    let engine: Engine
    @Published var enabled: Bool
    @Published var port: String
    @Published var context: Int
    @Published var inputMode: InputMode
    @Published var gpu: Bool
    @Published var ane: Bool
    @Published var draftPath: String
    @Published var maximumLoadedModels: Int
    @Published var strataDraft: Bool
    @Published var strataSpeculation: Int
    @Published var error: String?
    init(engine: Engine, value: EngineConfiguration) {
        self.engine = engine; enabled = value.isEnabled; port = String(value.port ?? engine.defaultPort)
        context = value.context ?? (engine.kind == .strata ? 32768 : 8192); inputMode = value.inputMode ?? .automatic; gpu = value.gpu ?? true
        ane = value.ane ?? true; draftPath = value.draftPath ?? ""; maximumLoadedModels = value.maximumLoadedModels ?? 3
        strataDraft = value.strataDraft ?? true; strataSpeculation = value.strataSpeculation ?? 2
    }
    func value() throws -> EngineConfiguration {
        guard let port = Int(port), (1024...65535).contains(port), (1024...262144).contains(context),
              (1...16).contains(maximumLoadedModels) else { throw LaunchError.message("端口、上下文或常驻模型数量无效") }
        if !draftPath.isEmpty {
            guard let config = jsonFile(URL(fileURLWithPath: draftPath).appendingPathComponent("config.json")), DraftModelPolicy.isDraft(config),
                  FileManager.default.fileExists(atPath: URL(fileURLWithPath: draftPath).appendingPathComponent("model.safetensors").path) else { throw LaunchError.message("请选择文件齐全的 DFlash2 草稿目录") }
        }
        guard (1...4).contains(strataSpeculation) else { throw LaunchError.message("Strata 推测窗口需要在 1–4 之间") }
        return .init(enabled: enabled, port: port, context: context, inputMode: inputMode, gpu: gpu, ane: ane, draftPath: draftPath.isEmpty ? nil : draftPath, maximumLoadedModels: maximumLoadedModels, strataDraft: engine.kind == .strata ? strataDraft : nil, strataSpeculation: engine.kind == .strata ? strataSpeculation : nil)
    }
}

@MainActor extension AppStore {
    func engineEnabled(_ id: String) -> Bool { engineConfigurations[id]?.isEnabled ?? true }
    func setEngineEnabled(_ id: String, enabled: Bool) {
        do {
            var next = engineConfigurations; var value = next[id] ?? .init(); value.enabled = enabled; next[id] = value
            try JSONEncoder().encode(next).write(to: services.stateDirectory.appendingPathComponent("engine-configurations.json"), options: .atomic)
            engineConfigurations = next
            if !enabled, modelEngineFilter == id { modelEngineFilter = "" }
            if !engineEnabled(engineID), let first = enabledEngines.first { chooseEngine(first.id) }
            synchronizeGateway()
        } catch { message = "引擎设置未保存：" + error.localizedDescription }
    }
    func prepareEngineConfiguration(_ engine: Engine? = nil) {
        let target = engine ?? self.engine
        engineConfigurationDraft = .init(engine: target, value: engineConfigurations[target.id] ?? .init())
    }
    func saveEngineConfiguration(_ draft: EngineConfigurationDraft) {
        do {
            var next = engineConfigurations; next[draft.engine.id] = try draft.value()
            try JSONEncoder().encode(next).write(to: services.stateDirectory.appendingPathComponent("engine-configurations.json"), options: .atomic)
            engineConfigurations = next; engineConfigurationDraft = nil; synchronizeGateway()
            if !engineEnabled(engineID), let first = enabledEngines.first { chooseEngine(first.id) }
            else if engineID == draft.engine.id && currentService?.pid == nil { chooseEngine(engineID) }
        } catch { draft.error = error.localizedDescription }
    }
}

@MainActor struct GlobalEngineSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(verbatim: L10n.text("全局引擎设置")).font(.system(size: TypeScale.section, weight: .bold)); Spacer(); Button(L10n.text("完成")) { store.showGlobalEngines = false } }
            Text(verbatim: L10n.text("禁用的基座从引擎列表、模型启动和网关接入中隐藏。在这里可随时重新启用。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            ScrollView { VStack(spacing: 8) {
                ForEach(store.engines) { engine in
                    HStack(spacing: 14) {
                        EngineIcon(engine: engine, size: 42)
                        VStack(alignment: .leading, spacing: 5) { Text(verbatim: L10n.text(engine.name)).font(.system(size: TypeScale.body, weight: .semibold)); Text(verbatim: L10n.text(engine.installation)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                        Spacer()
                        Toggle(L10n.text("启用"), isOn: Binding(get: { store.engineEnabled(engine.id) }, set: { store.setEngineEnabled(engine.id, enabled: $0) })).toggleStyle(.switch).accessibilityIdentifier("global-engine-" + engine.id)
                    }.padding(14).background(Theme.line.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                }
            } }
            Text(verbatim: L10n.text("禁用不会卸载引擎或删除模型。已运行服务继续保留在服务管理页，便于停止。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        }.padding(26).frame(width: 650, height: 660).background(Theme.background)
    }
}

@MainActor struct EngineConfigurationView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var draft: EngineConfigurationDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { EngineIcon(engine: draft.engine, size: 44); Text(verbatim: L10n.text(draft.engine.name + " 配置")).font(.system(size: TypeScale.section, weight: .bold)); Spacer() }
            Toggle(L10n.text("启用此模型基座"), isOn: $draft.enabled).toggleStyle(.switch)
            Text(verbatim: L10n.text("停用后不能新建服务或接入网关。已运行的服务保持原设置，可在模型服务页面停止。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                        GridRow { Text(verbatim: L10n.text("默认端口")); TextField(L10n.text("1024–65535"), text: $draft.port).textFieldStyle(.roundedBorder).frame(width: 150) }
                        if ![.audio, .mflux].contains(draft.engine.kind) {
                            GridRow { Text(verbatim: L10n.text("默认上下文")); Picker(L10n.text("默认上下文"), selection: $draft.context) { ForEach([2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144], id: \.self) { Text(verbatim: L10n.text($0.formatted() + " tokens")).tag($0) } }.labelsHidden() }
                            GridRow { Text(verbatim: L10n.text("默认输入模式")); Picker(L10n.text("默认输入模式"), selection: $draft.inputMode) { ForEach(InputMode.allCases) { Text(verbatim: L10n.text($0.title)).tag($0) } }.labelsHidden() }
                        }
                    }.font(.system(size: TypeScale.body))
                    Text(verbatim: L10n.text("启动时仍核对模型和运行组件是否支持所选模式。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    if [.llama, .prism].contains(draft.engine.kind) { Toggle(L10n.text("使用 GPU 加速"), isOn: $draft.gpu).toggleStyle(.checkbox) }
                    if draft.engine.kind == .ollama { Stepper("最多常驻 \(draft.maximumLoadedModels) 个模型", value: $draft.maximumLoadedModels, in: 1...16) }
                    if [.splash, .mlx].contains(draft.engine.kind) {
                        let modern = SplashRuntime.current(draft.engine)?.supportsPacked == false
                        if draft.engine.kind == .splash {
                            Toggle(L10n.text("启用 Neural Engine（ANE）"), isOn: $draft.ane).toggleStyle(.checkbox).disabled(!modern)
                            Text(verbatim: L10n.text(modern ? "关闭会传入 --disable-ane，预填充由 GPU 完成。" : "旧 packed 组件未核实此选项，配置不会传入该组件。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        }
                        Divider(); Text(verbatim: L10n.text("推测解码草稿")).font(.system(size: TypeScale.body, weight: .semibold))
                        Text(verbatim: L10n.text(draft.engine.kind == .splash ? "新版 Splash 必须加载匹配的草稿，默认自动选择。旧 packed 使用自己的配套组件。" : "MLX-VLM 支持 DFlash2；未选择时关闭草稿。MLX-LM 不能加载此格式。可在主模型设置中覆盖本默认值。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        Picker(L10n.text("本地草稿组件"), selection: $draft.draftPath) {
                            Text(verbatim: L10n.text(draft.engine.kind == .splash ? "自动选择已登记组件" : "关闭草稿")).tag("")
                            ForEach(store.models.filter { $0.kind == .draft && $0.complete }) { Text(verbatim: L10n.text($0.name)).tag($0.path) }
                        }.disabled(draft.engine.kind == .splash ? !modern : draft.engine.visionPath == nil)
                        Text(verbatim: L10n.text("本地 DFlash2 先核对主模型尺寸，再由引擎验证加载。每个模型可保存自己的组件关联。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    }
                    if draft.engine.kind == .strata {
                        Toggle(L10n.text("启用已准备的 MTP 草稿"), isOn: $draft.strataDraft).toggleStyle(.checkbox)
                        Stepper("推测窗口：\(draft.strataSpeculation)", value: $draft.strataSpeculation, in: 1...4)
                        Text(verbatim: L10n.text("自动使用本模型准备的 MTP；小内存流式模型可能未启用 MTP。关闭后只运行主模型。每个服务独立保存启动配置，修改只影响后续启动。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    }
                    if draft.engine.kind == .lmstudio { Text(verbatim: L10n.text("通过原应用或外部服务启动；实际参数和能力以原服务为准。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                }.padding(.trailing, 5)
            }.disabled(!draft.enabled)
            if let error = draft.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText) }
            Divider()
            HStack { Button(L10n.text("取消")) { store.engineConfigurationDraft = nil }; Spacer(); Button(L10n.text("保存配置")) { store.saveEngineConfiguration(draft) }.buttonStyle(.borderedProminent).tint(Theme.accent) }
        }.padding(26).frame(width: 670, height: 650).background(Theme.background)
    }
}
