import Foundation
import SwiftUI
import AppKit

extension Engine {
    var modalityGuide: (summary: String, activation: String, url: String) {
        switch kind {
        case .strata: return ("官方 Strata 主线面向 Windows/Linux，可通过兼容 API 接入。", "图片由原服务的视觉组件决定；Mac Metal PR 已关闭且未合并，当前不自动安装实验分支。", "https://github.com/Niko1221/Strata")
        case .splash: return ("新版 Splash 支持匹配模型的图片和 PDF；旧 packed 模型仅支持文本。", "新版默认加载兼容视觉组件；纯文本使用 --language-only。当前旧 packed 模型不能通过开关增加视觉能力。", "https://github.com/incoai/splash/blob/main/DEVELOPMENT.md#vision")
        case .llama, .prism: return ("支持带匹配投影组件的视觉或音频模型，具体模态由模型和引擎版本决定。", "多模态加载所选 GGUF 投影文件；纯文本使用 --no-mmproj，不加载视觉或音频编码器。投影文件与主模型的匹配由引擎启动时验证。", "https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md")
        case .ollama: return ("支持视觉模型；普通文本模型仍仅支持文本。", "加载带 vision 能力的注册模型后自动启用图片；没有统一的 serve --vision 开关。启动后的模型能力由 /api/show 核实，纯文本输入限制在网关按模型设置。", "https://docs.ollama.com/capabilities/vision")
        case .mlx: return ("文本模式使用 MLX-LM，多模态模式使用 MLX-VLM；自动模式按模型能力选择组件。", "图片等媒体能力取决于具体模型和 MLX-VLM 版本。可以使用已下载的本地权重启动，服务支持直接连接或通过统一网关接入。", "https://github.com/Blaizzy/mlx-vlm#server-fastapi")
        case .lmstudio: return ("GGUF / MLX 视觉模型由 LM Studio 对应运行时加载。", "在 LM Studio 中加载 VLM 后自动启用图片；lms load 的公开参数未提供统一的视觉开关。模型及加载组件决定能力，纯文本输入限制可通过网关配置。", "https://lmstudio.ai/docs/python/llm-prediction/image-input")
        }
    }
}

struct ModelCapabilityBadge: View {
    var capabilities: ModelCapabilities
    var prefix = ""
    var body: some View {
        Label(L10n.text(prefix + capabilities.badgeTitle), systemImage: capabilities.known && capabilities.supportsMedia ? "photo.on.rectangle" : "text.alignleft")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(capabilities.known ? Theme.linkColor : Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 5).background(Theme.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            .help(L10n.text(capabilities.source)).accessibilityLabel(L10n.text(prefix + capabilities.badgeTitle + "。" + capabilities.source))
    }
}

@MainActor
extension AppStore {
    func normalizeStartupMode() {
        if engine.kind == .mlx && currentService?.pid == nil && engine.visionPath == nil && inputMode == .multimodal { inputMode = .text }
    }
    func modelCapabilities(_ model: LocalModel) -> ModelCapabilities {
        let local = ModalityPolicy.local(model)
        if !local.known {
            for spec in services.records where model.matchesID(spec.modelID) && spec.pid != nil && services.status(spec) == .running {
                if let names = services.reportedModels[spec.port], names.count == 1,
                   var actual = services.modelCapabilities[spec.port]?[names[0]], actual.known && actual.supportsMedia {
                    actual.source = "已验证运行实例的媒体能力 · " + actual.source; return actual
                }
            }
        }
        return local
    }
    func serviceCapabilities(_ spec: ServiceSpec) -> ModelCapabilities {
        let names = services.reportedModels[spec.port] ?? []
        if spec.pid != nil && services.status(spec) == .running,
           names.count == 1, let value = services.modelCapabilities[spec.port]?[names[0]], value.known { return value }
        let model = models.first { $0.matchesID(spec.modelID) }
        if spec.pid != nil && spec.inputMode != .text && spec.engineID != "splash" && spec.engineID != "mlx" { return ModelCapabilities(source: "服务尚未明确声明当前输入能力") }
        guard let engine = engines.first(where: { $0.id == spec.engineID }) else { return ModelCapabilities() }
        var servingEngine = engine
        if engine.kind == .mlx {
            let executable = spec.engineExecutable ?? ""
            if URL(fileURLWithPath: executable).lastPathComponent == "mlx_vlm.server" { servingEngine.visionPath = executable }
            else { servingEngine.visionPath = nil }
        }
        return ModalityPolicy.planned(engine: servingEngine, model: model, projector: spec.projectorPath, mode: spec.inputMode ?? .automatic)
    }
    var selectedModelCapabilities: ModelCapabilities {
        guard let model = selectedModel else { return ModelCapabilities() }
        if [.llama, .prism].contains(engine.kind), !projectorPath.isEmpty { return ModalityPolicy.planned(engine: engine, model: model, projector: projectorPath, mode: .automatic) }
        return modelCapabilities(model)
    }
    var nativeInputReason: String? { ModalityPolicy.nativeMultimodalReason(engine: engine, model: selectedModel, projector: projectorPath) }
    func selectModel(_ model: LocalModel) {
        guard selectedModels[engineID] != model.id else { return }
        selectedModels[engineID] = model.id; projectorPath = ""; inputMode = .automatic
    }
}
