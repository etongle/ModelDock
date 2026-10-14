import Foundation
import SwiftUI
import AppKit

enum DraftSelectionMode: String, Codable, CaseIterable, Identifiable {
    case automatic, local, disabled
    var id: String { rawValue }
    var title: String { switch self { case .automatic: return "按引擎默认"; case .local: return "指定本地草稿"; case .disabled: return "关闭草稿（支持时）" } }
}
struct ModelAssociation: Codable, Hashable {
    var draftMode: DraftSelectionMode = .automatic
    var draftPath: String? = nil
    var projectorPath: String? = nil
}
enum ModelAssociationPolicy {
    static func draftPath(model: LocalModel?, engine: Engine) throws -> String? {
        guard let model else { return nil }
        if model.association?.draftMode == .disabled { return nil }
        let path = model.association?.draftMode == .local ? model.association?.draftPath : engine.launchSettings?.draftPath
        guard let path else { return nil }
        guard !path.isEmpty, path.hasPrefix("/") else { throw LaunchError.message("关联的草稿目录无效，请重新选择") }
        let draft = LocalModel(id: path, name: "本地草稿", format: "DFlash2 草稿", path: path, kind: .draft, bytes: 0, complete: FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("model.safetensors").path), verification: "", missingFiles: [], removalPath: path)
        guard DraftModelPolicy.matches(draft, target: model) else { throw LaunchError.message("关联草稿缺失或与主模型尺寸不匹配，请修复文件或重新选择") }
        return path
    }
}
@MainActor final class ModelAssociationDraft: ObservableObject, Identifiable {
    let id = UUID()
    let model: LocalModel
    @Published var mode: DraftSelectionMode
    @Published var draftPath: String
    @Published var projectorPath: String
    @Published var error: String?
    init(model: LocalModel) {
        self.model = model; mode = model.association?.draftMode ?? .automatic
        draftPath = model.association?.draftPath ?? ""; projectorPath = model.association?.projectorPath ?? ""
    }
}
@MainActor extension AppStore {
    func prepareAssociation(_ model: LocalModel) { associationDraft = .init(model: model) }
    func saveAssociation(_ draft: ModelAssociationDraft) {
        do {
            let value = ModelAssociation(draftMode: draft.mode, draftPath: draft.mode == .local ? draft.draftPath : nil, projectorPath: draft.projectorPath.isEmpty ? nil : draft.projectorPath)
            var model = draft.model; model.association = value
            if draft.mode == .local {
                guard !draft.draftPath.isEmpty else { throw LaunchError.message("请选择已下载的匹配草稿") }
                var engine = self.engine; engine.launchSettings = nil
                _ = try ModelAssociationPolicy.draftPath(model: model, engine: engine)
            }
            if !draft.projectorPath.isEmpty {
                guard ModalityPolicy.projector(model: model, override: draft.projectorPath) != nil else { throw LaunchError.message("视觉投影文件缺失或不是有效 GGUF") }
            }
            var next = modelAssociations; next[model.id] = value
            try JSONEncoder().encode(next).write(to: services.stateDirectory.appendingPathComponent("model-associations.json"), options: .atomic)
            modelAssociations = next; associationDraft = nil
            message = "配套组件已保存，下次启动生效。运行中的服务保持原组件。"
        } catch { draft.error = error.localizedDescription }
    }
}
@MainActor struct ModelAssociationEntry: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var draftName: String {
        guard let path = model.association?.draftPath else { return "未选择" }
        return store.models.first(where: { $0.path == path })?.name ?? ModelOrigin.displayName(folder: URL(fileURLWithPath: path)) ?? URL(fileURLWithPath: path).lastPathComponent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(verbatim: L10n.text("关联启动组件")).font(.system(size: 20, weight: .semibold)); Spacer(); Button(L10n.text("配置组件…")) { store.prepareAssociation(model) }.buttonStyle(.bordered).accessibilityIdentifier("model-association") }
            if model.format.hasPrefix("GGUF") {
                Text(verbatim: L10n.text("视觉投影：" + (model.companion.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未关联；多模态启动前需要选择"))).font(.system(size: 13))
            } else if model.format.hasPrefix("Splash 4-bit") {
                Text(verbatim: L10n.text("旧 packed 模型使用对应旧版引擎的内置配套组件。")).font(.system(size: 13))
            } else {
                Text(verbatim: L10n.text("tokenizer / 视觉配置：随主模型加载")).font(.system(size: 13))
                Text(verbatim: L10n.text("草稿模型：" + (model.association?.draftMode == .local ? draftName : model.association?.draftMode == .disabled ? "已关闭；新版 Splash 必须开启" : "按引擎默认；Splash 使用已登记组件"))).font(.system(size: 13))
            }
            Text(verbatim: L10n.text("选择的组件随本模型保存。已启动的服务记录实际路径；后续修改只影响新启动。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }.padding(18).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}
@MainActor struct ModelAssociationView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var draft: ModelAssociationDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: L10n.text("模型与配套组件")).font(.system(size: 24, weight: .bold))
            Text(verbatim: L10n.text(draft.model.name)).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
            Divider()
            if draft.model.format.hasPrefix("GGUF") {
                Text(verbatim: L10n.text("视觉投影（mmproj）")).font(.system(size: 16, weight: .semibold))
                Picker(L10n.text("投影文件"), selection: $draft.projectorPath) {
                    Text(verbatim: L10n.text("使用自动匹配的投影")).tag("")
                    if let path = draft.model.companion { Text(verbatim: L10n.text(URL(fileURLWithPath: path).lastPathComponent)).tag(path) }
                    ForEach(store.models.filter { $0.kind == .adapter && $0.format.hasPrefix("GGUF") && $0.path != draft.model.companion }) { Text(verbatim: L10n.text($0.name)).tag($0.path) }
                }
                Button(L10n.text("选择其他投影文件…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let file = panel.url { draft.projectorPath = file.path }
                }.buttonStyle(.bordered)
                Text(verbatim: L10n.text("Llama / llama.cpp 多模态启动会传入这个投影文件。请选择同一模型发布的配套投影，不能只根据文件大小判断匹配。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else if draft.model.format.hasPrefix("Splash 4-bit") {
                Text(verbatim: L10n.text("此模型是旧 packed 封装，由匹配的旧版 Splash 加载自己的配套组件，不能另外指定 DFlash2。请下载新版主模型，在新版主模型中关联草稿与视觉组件。")).font(.system(size: 14)).foregroundStyle(Theme.muted)
            } else {
                Text(verbatim: L10n.text("tokenizer 和视觉组件来自主模型目录；DFlash2 共用主模型 tokenizer，不单独补下载。")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Text(verbatim: L10n.text("草稿加速")).font(.system(size: 16, weight: .semibold))
                Picker(L10n.text("草稿模式"), selection: $draft.mode) { ForEach(DraftSelectionMode.allCases) { Text(verbatim: L10n.text($0.title)).tag($0) } }
                if draft.mode == .local {
                    Picker(L10n.text("匹配草稿"), selection: $draft.draftPath) {
                        Text(verbatim: L10n.text("选择本地组件")).tag("")
                        ForEach(store.models.filter { DraftModelPolicy.matches($0, target: draft.model) }) { Text(verbatim: L10n.text($0.name)).tag($0.path) }
                    }
                    if !draft.draftPath.isEmpty { Text(verbatim: L10n.text(draft.draftPath)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(4) }
                }
                Text(verbatim: L10n.text("DFlash2 可交给新版 Splash 或支持 DFlash 的 MLX-VLM 多模态组件。MLX-LM 不支持此格式；新版 Splash 必须使用草稿。尺寸检查通过后，仍由引擎验证主模型家族是否匹配。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(verbatim: L10n.text("按引擎默认：优先引擎配置；Splash 复用已登记草稿，MLX-VLM 未指定时不开启草稿。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let error = draft.error { Text(verbatim: L10n.text(error)).font(.system(size: 13)).foregroundStyle(Theme.errorText) }
            Text(verbatim: L10n.text("保存不会重启或替换正在运行的服务。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Divider()
            HStack { Button(L10n.text("取消")) { store.associationDraft = nil }; Spacer(); Button(L10n.text("保存关联")) { store.saveAssociation(draft) }.buttonStyle(.borderedProminent).tint(Theme.accent) }
        }.padding(26).frame(width: 690, height: 540).background(Theme.background)
    }
}
