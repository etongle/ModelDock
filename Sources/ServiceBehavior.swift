import Foundation
import SwiftUI
import AppKit

/// 一组可复用的启动参数：上下文、输入模式和引擎原生附加参数。附加参数只对同类引擎有效。
struct ServicePreset: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var engineKind: String
    var context: Int
    var inputMode: InputMode
    var extraArguments: [String]
}

@MainActor extension AppStore {
    /// 按已保存的配置启动一个已停止的服务：命令启动的服务重新解析原命令，其余使用保存的参数。
    @discardableResult
    func startSaved(_ saved: ServiceSpec) throws -> ServiceSpec {
        let spec = services.records.first { $0.id == saved.id } ?? saved
        guard spec.pid == nil else { return spec }
        guard let engine = engines.first(where: { $0.id == spec.engineID }) else { throw LaunchError.message("未找到引擎") }
        if let text = spec.commandText {
            return try services.start(command: ServiceCommand.parse(text, engine: engine, models: models))
        }
        let model = models.first { $0.id == spec.modelID || $0.path == spec.modelPath }
        guard model != nil || engine.kind == .ollama else { throw LaunchError.message("未找到服务使用的模型文件。") }
        return try services.start(engine: engine, model: model, port: spec.port, context: spec.context, maximumLoadedModels: spec.maximumLoadedModels ?? 3,
                                  inputMode: spec.inputMode ?? .automatic, projectorPath: spec.projectorPath, extraArguments: spec.extraArguments)
    }

    /// 应用启动后启动标记为“随 App 启动”的服务；端口被占用或已在运行的跳过，失败汇总提示。
    func autoStartServices() {
        var failures: [String] = []
        for spec in services.records where spec.autoStart == true && spec.pid == nil {
            if NetworkProbe.portOccupied(spec.port) { continue }
            do { try startSaved(spec) } catch { failures.append("端口 \(spec.port) · \(spec.modelName)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { message = L10n.text("以下服务未能随 ModelDock 自动启动：") + "\n" + failures.joined(separator: "\n") }
    }

    var servicePresetsURL: URL { services.stateDirectory.appendingPathComponent("service-presets.json") }
    func loadServicePresets() {
        servicePresets = (try? Data(contentsOf: servicePresetsURL)).flatMap { try? JSONDecoder().decode([ServicePreset].self, from: $0) } ?? []
    }
    private func saveServicePresets(_ next: [ServicePreset]) throws {
        try JSONEncoder().encode(next).write(to: servicePresetsURL, options: .atomic)
        servicePresets = next
    }
    /// 把参数卡当前的值存成预设；同名同引擎的预设被覆盖。
    func saveServicePreset(name: String, engine: Engine, draft: ServiceParameterDraft) {
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 40 else { throw LaunchError.message("预设名称需要 1–40 个字符") }
            let extras = try ServiceExtraArguments.parse(draft.extra, engine: engine)
            let preset = ServicePreset(name: trimmed, engineKind: engine.kind.rawValue, context: draft.context, inputMode: draft.inputMode, extraArguments: extras)
            try saveServicePresets(servicePresets.filter { !($0.name == trimmed && $0.engineKind == preset.engineKind) } + [preset])
            draft.notice = L10n.text("已保存预设“\(trimmed)”"); draft.error = nil
        } catch { draft.error = error.localizedDescription }
    }
    func deleteServicePreset(_ preset: ServicePreset) {
        do { try saveServicePresets(servicePresets.filter { $0.id != preset.id }) } catch { message = error.localizedDescription }
    }
    /// 预设只填入参数卡，仍需用户点“保存”或“保存并重启”。
    func applyServicePreset(_ preset: ServicePreset, to draft: ServiceParameterDraft) {
        draft.context = preset.context; draft.inputMode = preset.inputMode
        draft.extra = ServiceExtraArguments.display(preset.extraArguments)
        draft.error = nil; draft.notice = L10n.text("已填入预设“\(preset.name)”，保存后生效。")
    }
}

/// 参数卡中的预设菜单。
@MainActor struct ServicePresetMenu: View {
    @ObservedObject var store: AppStore
    var engine: Engine
    @ObservedObject var draft: ServiceParameterDraft
    var presets: [ServicePreset] { store.servicePresets.filter { $0.engineKind == engine.kind.rawValue } }
    var body: some View {
        Menu {
            if presets.isEmpty { Text(verbatim: L10n.text("此引擎还没有预设")) }
            ForEach(presets) { preset in Button(preset.name) { store.applyServicePreset(preset, to: draft) } }
            Divider()
            Button(L10n.text("将当前参数存为预设…")) { askName() }
            if !presets.isEmpty {
                Menu(L10n.text("删除预设")) { ForEach(presets) { preset in Button(preset.name, role: .destructive) { store.deleteServicePreset(preset) } } }
            }
        } label: { Label(L10n.text("参数预设"), systemImage: "slider.horizontal.3") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("service-presets")
    }
    private func askName() {
        let alert = NSAlert(); alert.messageText = L10n.text("保存参数预设")
        alert.informativeText = L10n.text("保存上下文、输入模式和附加启动参数，可用于同类引擎的其他服务。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.placeholderString = L10n.text("例如：长上下文")
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L10n.text("保存")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.saveServicePreset(name: field.stringValue, engine: engine, draft: draft)
    }
}

/// 参数卡中的“运行方式”：随 App 启动、空闲自动停止。修改立即保存，不重启服务。
@MainActor struct ServiceBehaviorView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var spec: ServiceSpec
    static let idleChoices = [0, 10, 30, 60, 120]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L10n.text("运行方式")).font(.system(size: TypeScale.body))
            Toggle(L10n.text("随 ModelDock 启动"), isOn: Binding(get: { spec.autoStart == true }, set: { services.updateBehavior(spec.id, autoStart: $0) }))
                .toggleStyle(.checkbox).font(.system(size: TypeScale.body))
            HStack(spacing: 10) {
                Text(verbatim: L10n.text("空闲自动停止")).font(.system(size: TypeScale.body))
                Picker(L10n.text("空闲自动停止"), selection: Binding(get: { spec.idleMinutes ?? 0 }, set: { services.updateBehavior(spec.id, idleMinutes: .some($0 == 0 ? nil : $0)) })) {
                    ForEach(Self.idleChoices, id: \.self) { Text(verbatim: $0 == 0 ? L10n.text("关闭") : L10n.text("\($0) 分钟")).tag($0) }
                }.labelsHidden().fixedSize()
            }
            Text(verbatim: L10n.text(spec.idleMinutes == nil ? "开启后，服务在设定时间内没有请求且 CPU 空闲时自动停止以释放内存。" : "经统一网关的请求会自动唤醒服务，首个请求需等待模型加载；直接访问服务端口不会唤醒。"))
                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            if spec.sleeping == true && spec.pid == nil {
                Label(L10n.text("因空闲已自动停止，等待网关请求唤醒"), systemImage: "moon.zzz").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
        }
    }
}
