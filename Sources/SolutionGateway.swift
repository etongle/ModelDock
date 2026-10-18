import Foundation

struct GatewaySolutionComponent: Codable, Hashable, Identifiable {
    var role: String
    var routeID: String?
    var id: String { role }
}
struct GatewaySolution: Codable, Hashable, Identifiable {
    var id: String
    var recipe: String
    var name: String
    var configured: Bool
    var components: [GatewaySolutionComponent]
}

extension SolutionRole {
    var gatewayModel: String {
        switch self { case .asr: return "asr"; case .text: return "translation"; case .chat: return "chat"; case .vision: return "vision"; case .tts: return "tts" }
    }
    var gatewayOperation: String {
        switch self { case .asr: return "/audio/transcriptions"; case .tts: return "/audio/speech"; default: return "/chat/completions" }
    }
}

@MainActor extension GatewayController {
    func solutionEndpoint(_ deployment: SolutionDeployment) -> String {
        "http://127.0.0.1:\(settings.port)/solutions/\(deployment.id.lowercased())/v1"
    }
    func solutionReady(_ deployment: SolutionDeployment) -> Bool {
        guard ready, supportsSolutionRoutes, let solution = solutionRoutes.first(where: { $0.id == deployment.id.lowercased() }), solution.configured, !solution.components.isEmpty else { return false }
        return solution.components.allSatisfy { component in routes.contains { $0.id == component.routeID && $0.available && $0.enabled } }
    }
    func synchronizeSolutions(_ deployments: [SolutionDeployment], local: [LocalModel], services: ServiceController) -> [GatewaySolution] {
        deployments.map { record in
            let definition = SolutionCatalog.all.first { $0.id == record.solutionID }
            let components = (definition?.roles(for: record.draft) ?? record.components.map(\.role)).map { role -> GatewaySolutionComponent in
                guard let component = record.components.first(where: { $0.role == role }),
                      let spec = services.records.first(where: { $0.id == component.serviceID && $0.engineID == component.engineID && $0.modelID == component.modelID }),
                      let path = component.modelPath else { return .init(role: role.gatewayModel) }
                let model = local.first { $0.id == component.modelID && ModelInstancePolicy.samePath($0.path, path) }
                if role == .text, let model, TranslationLanguages.modelIssue(model) != nil { return .init(role: role.gatewayModel) }
                let paths = [path] + (model.map(ModelInstancePolicy.paths) ?? [])
                guard paths.contains(where: { ModelInstancePolicy.samePath(spec.modelPath, $0) }) else { return .init(role: role.gatewayModel) }
                let candidates = routes.filter { $0.sourceID == spec.id }
                let exact = candidates.first { $0.model == spec.modelPath || $0.model == spec.modelName || $0.model == component.repository }
                return .init(role: role.gatewayModel, routeID: (exact ?? (candidates.count == 1 ? candidates.first : nil))?.id)
            }
            return .init(id: record.id.lowercased(), recipe: record.solutionID, name: definition?.title ?? record.solutionID, configured: record.state == .configured, components: components)
        }
    }
    func solutionConnection(_ deployment: SolutionDeployment) throws -> String {
        try save()
        let models = deployment.components.map { ["model": $0.role.gatewayModel, "path": $0.role.gatewayOperation] }
        return String(decoding: try ConnectionFiles.json(["baseURL": solutionEndpoint(deployment), "apiKey": settings.apiKey, "models": models]), as: UTF8.self)
    }
    func restartForSolutions(store: AppStore) {
        guard !busy, ownsProcess(), active == 0 else { error = "网关仍有请求，请等待完成后重启。"; return }
        stop()
        Task {
            for _ in 0..<60 {
                if !busy { if process == nil { start(store: store) }; return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

@MainActor extension AppStore {
    // Audio services belong in the gateway without being treated as chat benchmarks or coding assistants.
    var gatewaySourceTargets: [ConnectionTarget] {
        let audio = services.records.compactMap { spec -> ConnectionTarget? in
            guard ["audio", "mflux"].contains(spec.engineID), engineEnabled(spec.engineID), services.status(spec) == .running,
                  let pid = spec.pid, let birth = spec.processStart, birth > 0 else { return nil }
            let names = services.reportedModels[spec.port] ?? []
            guard names.count == 1, let name = names.first, ConnectionFiles.validModel(name) else { return nil }
            var target = ConnectionTarget(id: spec.id + ":" + name, engineName: spec.engineID == "mflux" ? "MFLUX" : "MLX Audio", engineID: spec.engineID, model: name, port: spec.port, pid: pid, birth: birth, context: nil)
            target.sourceID = spec.id
            var capability = services.modelCapabilities[spec.port]?[name] ?? ModelCapabilities()
            if !capability.known, let model = models.first(where: { $0.id == spec.modelID }) { capability = ModalityPolicy.local(model) }
            target.capabilities = capability.applying(spec.inputMode ?? .automatic)
            return target
        }
        return directConnectionTargets + audio + configuredGatewayTargets.filter { !($0.capabilities?.outputs ?? ["text"]).contains("text") }
    }
}
