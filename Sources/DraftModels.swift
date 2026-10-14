import Foundation
import SwiftUI

enum DraftModelPolicy {
    static func isDraft(_ config: [String: Any]) -> Bool {
        (config["architectures"] as? [String])?.contains("DFlash2DraftModel") == true && config["dflash_config"] is [String: Any]
    }
    static func configuration(_ model: LocalModel) -> [String: Any] {
        let folder = URL(fileURLWithPath: model.folder)
        if model.splashSelection != nil, let record = jsonFile(folder.appendingPathComponent("model.json")),
           let path = (record["files"] as? [String: [String: Any]])?["target/config.json"]?["path"] as? String, path.hasPrefix("/") { return jsonFile(URL(fileURLWithPath: path)) ?? [:] }
        return jsonFile(folder.appendingPathComponent("config.json")) ?? [:]
    }
    static func matches(_ draft: LocalModel, target: LocalModel) -> Bool {
        guard draft.kind == .draft, draft.complete, target.kind == .language, !target.format.hasPrefix("Splash 4-bit") else { return false }
        let dc = configuration(draft), tc = configuration(target)
        let text = tc["text_config"] as? [String: Any] ?? tc
        guard isDraft(dc) else { return false }
        for (draftKey, targetKey) in [("hidden_size", "hidden_size"), ("num_target_layers", "num_hidden_layers"), ("vocab_size", "vocab_size")] {
            guard let a = dc[draftKey] as? NSNumber, let b = text[targetKey] as? NSNumber, a == b else { return false }
        }
        return true
    }
}

@MainActor
struct DraftModelInfo: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: L10n.text("草稿加速组件")).font(.system(size: TypeScale.section, weight: .semibold))
            Text(verbatim: L10n.text(model.usageExplanation)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            Text(verbatim: L10n.text("本仓库的必需文件：config.json、model.safetensors。tokenizer 由主模型提供。")).font(.system(size: TypeScale.body))
            let targets = store.models.filter { DraftModelPolicy.matches(model, target: $0) }
            Text(verbatim: L10n.text(targets.isEmpty ? "尚未找到尺寸匹配的本地主模型。" : "尺寸匹配的主模型")).font(.system(size: TypeScale.body, weight: .medium))
            ForEach(targets) { target in
                HStack { Text(verbatim: L10n.text(target.name)).lineLimit(2); Spacer(); Button(L10n.text("查看主模型")) { store.showModelFile(target) }.buttonStyle(.bordered) }.font(.system(size: TypeScale.body))
            }
            Text(verbatim: L10n.text("可在主模型的“关联启动组件”中选择本草稿。新版 Splash 和支持 DFlash 的 MLX-VLM 能加载此组件；MLX-LM 不支持此格式。尺寸匹配后仍由引擎验证模型家族。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            Link("查看 DFlash2 模型说明", destination: URL(string: "https://huggingface.co/incoai/Qwen3.8-27B-DFlash2")!).font(.system(size: TypeScale.body))
        }.padding(18).background(Theme.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}
