import Foundation

enum SolutionRecommendations {
    static let lightweightChoice = "lightweight"
    static let baseline = SolutionModel(repository: "mlx-community/Qwen3.8-27B-4bit", revision: "10c35caafbb80f7dc6a7a432cdd11af10a6d4818")

    static func usesBaseline(_ role: SolutionRole) -> Bool { [.text, .chat, .vision].contains(role) }

    static func source(_ role: SolutionRole, draft: SolutionDraft) -> SolutionModel {
        if role == .image, draft.localChoices[role.rawValue] == "heretic" { return ImageModelPolicy.heretic }
        if usesBaseline(role), draft.localChoices[role.rawValue] == lightweightChoice {
            return role == .vision
                ? .init(repository: "mlx-community/Qwen3-VL-4B-Instruct-4bit", revision: "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b")
                : .init(repository: "mlx-community/Qwen3.5-4B-4bit", revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c")
        }
        return SolutionCatalog.model(role, quality: draft.quality)
    }

    static func matches(_ model: LocalModel, role: SolutionRole, draft: SolutionDraft) -> Bool {
        let source = source(role, draft: draft)
        if usesBaseline(role), draft.localChoices[role.rawValue] != lightweightChoice {
            // Match the standard checkpoint across quantizations/engines. Finetunes,
            // drafters and a larger parameter count are not evidence of an upgrade.
            let identity = model.origin?.repository ?? model.repository ?? URL(fileURLWithPath: model.path).lastPathComponent
            return isBaseline(identity)
        }
        return model.repository == source.repository && model.origin?.revision == source.revision
    }

    private static func isBaseline(_ identity: String) -> Bool {
        let name = String(identity.split(separator: "/").last ?? "").lowercased()
        return name.range(of: #"^qwen3\.8-27b(?:[-_.](?:mlx|gguf|[48]bit|bf16|fp16|mxfp[48]|nvfp4|q[4-9][a-z0-9_]*|iq[4-9][a-z0-9_]*))*$"#, options: .regularExpression) != nil
    }

    static func isCurrent(_ component: SolutionComponent, draft: SolutionDraft) -> Bool {
        if component.serviceBinding != nil { return true }
        guard usesBaseline(component.role) else { return true }
        let choice = draft.localChoices[component.role.rawValue] ?? ""
        if choice == lightweightChoice {
            let expected = source(component.role, draft: draft)
            return component.repository == expected.repository && component.revision == expected.revision
        }
        if !choice.isEmpty && choice != "download" { return true }
        return isBaseline(component.repository)
    }

    static func label(_ role: SolutionRole, draft: SolutionDraft, model: LocalModel?) -> String {
        if draft.localChoices[role.rawValue]?.hasPrefix(SolutionServiceChoice.prefix) == true { return "复用已有兼容服务" }
        if draft.localChoices[role.rawValue] == lightweightChoice { return "轻量备选" }
        if let model, !matches(model, role: role, draft: draft) { return "手动选择 · 用途需核实" }
        return "推荐基准"
    }
}
