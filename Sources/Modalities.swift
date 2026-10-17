import Foundation
import SwiftUI
import AppKit

enum InputMode: String, Codable, CaseIterable, Identifiable {
    case automatic, text, multimodal
    var id: String { rawValue }
    var title: String { switch self { case .automatic: return "自动 · 按模型能力"; case .text: return "纯文本"; case .multimodal: return "多模态" } }
}

struct ModelCapabilities: Codable, Hashable {
    var inputs: [String] = ["text"]
    var outputs: [String] = ["text"]
    var known = false
    var source = "未声明能力"
    var context: Int?
    var supportsMedia: Bool { inputs.contains { $0 != "text" } }
    var title: String { ["text", "image", "audio", "video", "file"].filter(inputs.contains).map { ["text": "文本", "image": "图片", "audio": "音频", "video": "视频", "file": "文件"][$0]! }.joined(separator: " / ") }
    var badgeTitle: String { known ? (supportsMedia ? title : L10n.text("仅文本")) : (supportsMedia ? title + " · 待确认" : "能力待核实") }
    func applying(_ mode: InputMode) -> ModelCapabilities {
        var value = self
        if mode == .text { value.inputs = ["text"]; value.known = true; value.source = "纯文本设置" }
        return value
    }
    static func declared(_ object: [String: Any], source: String = "服务声明") -> ModelCapabilities {
        var result = ModelCapabilities(); result.source = source
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let modalities = object["modalities"] as? [String: Any] ?? [:]
        let properties = object["capabilities"] as? [String: Any] ?? [:]
        if let input = object["input_modalities"] as? [String] ?? modalities["input"] as? [String] ?? metadata["input_modalities"] as? [String] {
            result.inputs = Array(Set(["text"] + input.map { $0 == "pdf" ? "file" : $0 }.filter { ["text", "image", "audio", "video", "file"].contains($0) })).sorted(); result.known = true
        }
        let flags = object["capabilities"] as? [String] ?? []
        if flags.contains("vision") || object["vision"] as? Bool == true || modalities["vision"] as? Bool == true || properties["vision"] as? Bool == true { result.inputs += ["image"]; result.known = true }
        if flags.contains("audio") || modalities["audio"] as? Bool == true { result.inputs += ["audio"]; result.known = true }
        if flags.contains("video") || modalities["video"] as? Bool == true { result.inputs += ["video"]; result.known = true }
        if object["capabilities"] is [String] { result.known = true }
        if object["vision"] as? Bool == false || modalities["vision"] as? Bool == false || properties["vision"] as? Bool == false || flags.contains("completion") { result.known = true }
        if let output = modalities["output"] as? [String] { result.outputs = output }
        result.inputs = Array(Set(result.inputs)).sorted()
        if object["owned_by"] as? String == "modeldock-audio", let input = object["input_modalities"] as? [String] { result.inputs = input }
        result.context = object["context_length"] as? Int ?? metadata["context_length"] as? Int
        return result
    }
}

enum ModalityPolicy {
    static func projector(model: LocalModel?, override: String?) -> String? {
        let path = override?.isEmpty == false ? override : model?.companion
        guard let path, FileManager.default.fileExists(atPath: path), let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data("GGUF".utf8) ? path : nil
    }
    static func nativeMultimodalReason(engine: Engine, model: LocalModel?, projector: String?) -> String? {
        switch engine.kind {
        case .audio: return "语音能力由具体识别或合成模型决定，请使用自动模式。"
        case .strata:
            guard let prepared = model?.preparedForStrata(.multimodal), prepared.complete else { return "请先准备包含匹配视觉编码器和投影的 Strata 模型，再开启多模态。" }
            return nil
        case .llama, .prism:
            guard model?.kind == .language else { return "此模型不是可开启多模态的对话模型。" }
            guard let path = self.projector(model: model, override: projector) else { return "多模态需要与模型匹配的 GGUF 投影文件，请先选择投影文件。" }
            if let inputs = GGUFMetadata.read(URL(fileURLWithPath: path)).inputs, !inputs.contains(where: { $0 != "text" }) { return "所选投影文件没有声明视觉或音频编码器。" }
            return nil
        case .splash:
            if model?.splashSelection == nil, let prepared = model?.preparedForSplash() { return nativeMultimodalReason(engine: engine, model: prepared, projector: projector) }
            if model?.splashSelection != nil { return model?.splashVision == "none" ? "此 Splash 组件未准备视觉文件，请通过命令行入口去掉 --language-only，准备视觉版本后启动。" : nil }
            return "本模型使用旧版 Splash packed 组件，仅支持文本，不能开启图片、PDF、音频或视频。新版 Splash 的视觉能力需要新版匹配权重。"
        case .mlx:
            guard let path = engine.visionPath, FileManager.default.isExecutableFile(atPath: path) else { return "多模态需要 MLX-VLM。请安装或更新此基座的多模态组件；MLX-LM 提供纯文本服务。" }
            guard let model, local(model).supportsMedia else { return "此模型没有图片、音频或视频组件，无法开启多模态。请选择具备相应能力的模型。" }
            return nil
        case .ollama, .lmstudio: return "加载支持视觉的具体模型后自动开启；此基座没有已核实的服务级多模态开关。纯文本输入限制可在网关按模型设置。"
        }
    }
    static func local(_ model: LocalModel) -> ModelCapabilities {
        var result = ModelCapabilities()
        if let task = AudioModelPolicy.task(model) { result.inputs = task == "asr" ? ["audio"] : AudioModelPolicy.supportsReference(model) ? ["text", "audio"] : ["text"]; result.outputs = task == "asr" ? ["text"] : ["audio"]; result.known = true; result.source = "MLX Audio 模型配置"; return result }
        if let path = model.strataConfig, let config = jsonFile(URL(fileURLWithPath: path)) {
            result.inputs = config["vision"] == nil ? ["text"] : ["text", "image"]; result.known = true; result.source = "Strata 已准备组件"; return result
        }
        if model.splashSelection != nil { result.inputs = model.splashVision == "none" ? ["text"] : ["text", "image", "file"]; result.known = true; result.source = "Splash 已准备组件"; return result }
        if model.format.hasPrefix("Splash") { result.known = true; result.source = "旧版 Splash packed 模型 · 不支持图片、PDF、音频或视频"; return result }
        if model.format.hasPrefix("GGUF"), let path = projector(model: model, override: nil) {
            if let inputs = GGUFMetadata.read(URL(fileURLWithPath: path)).inputs { result.inputs = inputs; result.known = true; result.source = "投影文件编码器声明" }
            else { result.source = "已配投影文件 · 媒体类型待服务确认" }
        }
        let config = jsonFile(URL(fileURLWithPath: model.folder).appendingPathComponent("config.json")) ?? [:]
        if config["vision_config"] != nil || config["vision_tower"] != nil { result.inputs = Array(Set(result.inputs + ["image"])).sorted(); result.known = true; result.source = "模型配置" }
        if config["audio_config"] != nil || config["audio_encoder_config"] != nil { result.inputs = Array(Set(result.inputs + ["audio"])).sorted(); result.known = true; result.source = "模型配置" }
        if model.kind == .embedding {
            result.outputs = ["embedding"]
            if !result.supportsMedia, ["bert", "nomic-bert", "roberta", "xlm-roberta"].contains(model.architecture ?? config["model_type"] as? String ?? "") { result.known = true; result.source = "模型架构声明 · 文本嵌入" }
        }
        return result
    }
    static func planned(engine: Engine, model: LocalModel?, projector: String?, mode: InputMode) -> ModelCapabilities {
        let model = engine.kind == .splash ? (model?.preparedForSplash(mode) ?? model) : engine.kind == .strata ? (model?.preparedForStrata(mode) ?? model) : model
        var value = model.map(local) ?? ModelCapabilities()
        if engine.kind == .mlx {
            if engine.visionPath != nil && (mode == .multimodal || (mode == .automatic && value.supportsMedia)) { value.source = "MLX-VLM 多模态组件 · 架构在启动时验证" }
            else { value.inputs = ["text"]; value.known = engine.canServe; value.source = engine.canServe ? "MLX-LM 文本组件" : "尚未配置 MLX 模型服务程序" }
        }
        if engine.kind == .splash && model?.format.hasPrefix("Splash") == true && model?.splashSelection == nil { value.inputs = ["text"]; value.known = true; value.source = "旧版 Splash packed 文本组件" }
        if [.llama, .prism].contains(engine.kind), let path = self.projector(model: model, override: projector) {
            if let inputs = GGUFMetadata.read(URL(fileURLWithPath: path)).inputs { value.inputs = inputs; value.known = true; value.source = "所选投影文件的编码器声明" }
        } else if [.llama, .prism].contains(engine.kind) { value.inputs = ["text"]; value.known = true; value.source = "本次启动未配置投影组件" }
        return value.applying(mode)
    }
}

@MainActor
struct InputModeView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) { Text(verbatim: L10n.text("模型输入能力")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); ModelCapabilityBadge(capabilities: store.selectedModelCapabilities); Spacer() }
            if let spec = store.currentService, spec.pid != nil {
                HStack(spacing: 10) { Text(verbatim: L10n.text("当前服务")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); ModelCapabilityBadge(capabilities: store.serviceCapabilities(spec)); Spacer() }
                Text(verbatim: L10n.text("此实例正在运行；停止后可修改启动模式，或选择其他空闲端口启动新实例。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
            HStack {
                Text(verbatim: L10n.text("本次启动模式")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                if store.engine.independentModels && store.engine.kind != .audio {
                    Picker(L10n.text("本次启动模式"), selection: $store.inputMode) {
                        Text(verbatim: L10n.text(InputMode.automatic.title)).tag(InputMode.automatic)
                        Text(verbatim: L10n.text(InputMode.text.title)).tag(InputMode.text)
                        Text(verbatim: L10n.text(InputMode.multimodal.title)).tag(InputMode.multimodal).disabled(store.nativeInputReason != nil)
                    }.labelsHidden().frame(maxWidth: 240).disabled(store.currentService?.pid != nil).accessibilityIdentifier("model-input-mode")
                } else { Text(verbatim: L10n.text("随具体模型自动开启")).font(.system(size: TypeScale.body)) }
                Spacer()
            }
            if [EngineKind.llama, .prism].contains(store.engine.kind), store.inputMode != .text {
                HStack { Text(verbatim: L10n.text(store.projectorPath.isEmpty ? store.selectedModel?.companion.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未选择投影文件" : URL(fileURLWithPath: store.projectorPath).lastPathComponent)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(1); Spacer(); Button(L10n.text("选择投影文件…")) { store.chooseProjector() }.buttonStyle(.bordered).disabled(store.currentService?.pid != nil) }
            }
            if let reason = store.nativeInputReason { Text(verbatim: L10n.text(reason)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            else {
                HStack(spacing: 10) { Text(verbatim: L10n.text("启动后输入")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); ModelCapabilityBadge(capabilities: ModalityPolicy.planned(engine: store.engine, model: store.selectedModel, projector: store.projectorPath, mode: store.inputMode)) }
            }
            if store.engine.kind == .mlx {
                Text(verbatim: L10n.text("本次使用：" + ((store.inputMode == .multimodal || (store.inputMode == .automatic && store.selectedModelCapabilities.supportsMedia && store.engine.visionPath != nil)) ? "MLX-VLM · 多模态服务" : "MLX-LM · 文本服务"))).font(.system(size: TypeScale.body, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Text(verbatim: L10n.text(store.engine.modalityGuide.activation)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("查看此基座的官方多模态说明")) { if let url = URL(string: store.engine.modalityGuide.url) { NSWorkspace.shared.open(url) } }.buttonStyle(PlainAction()).font(.system(size: TypeScale.callout))
        }.onAppear { store.normalizeStartupMode() }.onChange(of: store.engineID) { store.normalizeStartupMode() }
    }
}

@MainActor
extension AppStore {
    func chooseProjector() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.message = L10n.text("选择与所选模型匹配的多模态投影 GGUF 文件。"); panel.prompt = L10n.text("选择投影文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ModalityPolicy.projector(model: nil, override: url.path) != nil else { message = "投影文件需要具有有效的 GGUF 文件头。"; return }
        projectorPath = url.path
    }
}
