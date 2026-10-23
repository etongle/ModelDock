import Foundation
import SwiftUI

/// An explicit service choice is independent of the recipe's download recommendation.
/// Pin both the service configuration and the API model, including multi-model servers.
struct SolutionServiceBinding: Codable, Equatable {
    var model: String
    var configurationModelID: String
    var configurationModelName: String
    var configurationModelPath: String
    var capabilities: ModelCapabilities

    func matches(_ spec: ServiceSpec) -> Bool {
        spec.modelID == configurationModelID && spec.modelName == configurationModelName && spec.modelPath == configurationModelPath
    }
}

struct SolutionServiceChoice: Identifiable {
    var spec: ServiceSpec
    var model: String
    var capabilities: ModelCapabilities
    var id: String { Self.prefix + spec.id + "\n" + model }
    static let prefix = "service\n"
    var binding: SolutionServiceBinding {
        .init(model: model, configurationModelID: spec.modelID, configurationModelName: spec.modelName,
              configurationModelPath: spec.modelPath, capabilities: capabilities)
    }
}

@MainActor extension SolutionController {
    private func reusableCapability(_ model: String, spec: ServiceSpec, store: AppStore) -> ModelCapabilities {
        if let declared = store.services.modelCapabilities[spec.port]?[model], declared.known { return declared }
        if store.services.status(spec) == .stopped,
           let saved = deployments.flatMap(\.components).first(where: { $0.serviceID == spec.id && $0.serviceBinding?.model == model && $0.serviceBinding?.matches(spec) == true })?.serviceBinding { return saved.capabilities }
        // A multi-model server must declare the chosen model's capabilities;
        // another model's metadata cannot stand in for it.
        guard (store.services.reportedModels[spec.port] ?? []).count <= 1 else { return ModelCapabilities() }
        return store.serviceCapabilities(spec)
    }
    func serviceChoices(_ role: SolutionRole, store: AppStore) -> [SolutionServiceChoice] {
        guard [.text, .chat, .vision, .image].contains(role) else { return [] }
        return store.services.records.flatMap { spec -> [SolutionServiceChoice] in
            guard store.engineEnabled(spec.engineID), ![.stopping, .conflicted, .failed].contains(store.services.status(spec)) else { return [] }
            let local = store.models.first { $0.matchesID(spec.modelID) }
            if let local, local.kind != (role == .image ? .image : .language) || !local.complete { return [] }
            if role == .text, TranslationLanguages.identityIssue(spec.modelName) != nil || local.map({ TranslationLanguages.modelIssue($0) != nil }) == true { return [] }
            let names = store.services.reportedModels[spec.port] ?? []
            let saved = deployments.flatMap(\.components).compactMap { part -> String? in
                guard part.serviceID == spec.id, let binding = part.serviceBinding, binding.matches(spec) else { return nil }
                return binding.model
            }
            let models = names.isEmpty ? Array(Set(saved + [local?.repository ?? spec.modelName])).sorted() : names
            return models.compactMap { name in
                guard ConnectionFiles.validModel(name), role != .text || TranslationLanguages.identityIssue(name) == nil else { return nil }
                let identity = name.lowercased()
                guard !["dflash", "embedding", "embed-text", "qwen3-asr", "qwen3-tts"].contains(where: identity.contains) else { return nil }
                let capability = reusableCapability(name, spec: spec, store: store)
                guard capability.known, capability.inputs.contains("text"), capability.outputs.contains(role == .image ? "image" : "text"),
                      role != .vision || capability.inputs.contains("image") else { return nil }
                return .init(spec: spec, model: name, capabilities: capability)
            }
        }.sorted {
            let left = store.services.status($0.spec) == .running, right = store.services.status($1.spec) == .running
            if left != right { return left }
            if $0.spec.port != $1.spec.port { return $0.spec.port < $1.spec.port }
            return $0.id < $1.id
        }
    }

    func boundServiceIssue(_ component: SolutionComponent, store: AppStore) -> String? {
        guard store.engineEnabled(component.engineID) else { return "方案需要的基座已禁用，请在全局引擎设置中启用" }
        guard let binding = component.serviceBinding,
              let spec = store.services.records.first(where: { $0.id == component.serviceID && $0.engineID == component.engineID }),
              binding.matches(spec) else { return "所选服务已删除或模型配置已变化，请重新选择替代服务。" }
        if component.role == .text, let issue = TranslationLanguages.identityIssue(binding.model) ?? TranslationLanguages.identityIssue(binding.configurationModelName) ?? TranslationLanguages.identityIssue(component.repository) { return issue }
        if store.services.status(spec) == .running {
            let names = store.services.reportedModels[spec.port] ?? []
            guard names.contains(binding.model) else { return "所选服务未提供已绑定的模型，请检查服务或重新选择。" }
            let capability = reusableCapability(binding.model, spec: spec, store: store)
            guard capability.known, capability.inputs.contains("text"), capability.outputs.contains(component.role == .image ? "image" : "text"),
                  component.role != .vision || capability.inputs.contains("image") else { return "所选服务当前未提供此组件需要的能力，请重新选择。" }
        }
        return nil
    }

    func serviceComponent(_ choice: SolutionServiceChoice, role: SolutionRole, store: AppStore) -> SolutionComponent {
        let local = store.models.first { $0.matchesID(choice.spec.modelID) }
        return .init(role: role, engineID: choice.spec.engineID, modelID: local?.id ?? choice.spec.modelID,
                     modelPath: local?.path ?? choice.spec.modelPath, repository: local?.repository ?? choice.model,
                     revision: local?.origin?.revision ?? "", serviceID: choice.spec.id, serviceBinding: choice.binding)
    }

    func replaceService(_ choiceID: String, role: SolutionRole, deploymentID: String, store: AppStore) {
        guard preparingID == nil, removingIDs.isEmpty, !startingIDs.contains(deploymentID),
              let record = deployments.first(where: { $0.id == deploymentID }),
              let choice = serviceChoices(role, store: store).first(where: { $0.id == choiceID }) else { message = "所选服务已删除或模型配置已变化，请重新选择替代服务。"; return }
        do {
            store.solutionTrial.reset(); store.realtimeTranslation.cancel()
            var draft = record.draft; draft.localChoices[role.rawValue] = choice.id
            let components = record.components.map { $0.role == role ? serviceComponent(choice, role: role, store: store) : $0 }
            try replaceConfiguration(record.id, components: components, draft: draft, store: store, launchWhenReady: false)
            drafts[record.solutionID] = draft; save()
            store.synchronizeGateway()
        } catch { message = error.localizedDescription }
    }
}

@MainActor struct SolutionReplacementMenu: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: SolutionController
    var record: SolutionDeployment
    var component: SolutionComponent
    var body: some View {
        Menu {
            let choices = controller.serviceChoices(component.role, store: store)
            if !choices.isEmpty {
                Section(L10n.text("复用已有兼容服务")) {
                    ForEach(choices) { choice in
                        Button(serviceChoiceTitle(choice, store: store)) { controller.replaceService(choice.id, role: component.role, deploymentID: record.id, store: store) }
                    }
                }
            } else { Text(verbatim: L10n.text("暂无可替代的兼容服务")) }
            Divider()
            Button(L10n.text("选择其他本地模型或下载…")) { controller.edit(record.id, store: store) }
        } label: { Label(L10n.text("替换模型或服务…"), systemImage: "arrow.triangle.2.circlepath") }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(controller.preparingID != nil || controller.startingIDs.contains(record.id) || !controller.removingIDs.isEmpty)
            .accessibilityIdentifier("replace-solution-service-" + component.role.gatewayModel)
    }
}

@MainActor func serviceChoiceTitle(_ choice: SolutionServiceChoice, store: AppStore) -> String {
    let engine = store.engines.first { $0.id == choice.spec.engineID }?.name ?? choice.spec.engineID
    return choice.model + " · " + engine + " · " + String(choice.spec.port) + " · " + L10n.text(store.services.statusTitle(choice.spec))
}
