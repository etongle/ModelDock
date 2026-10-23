import Foundation

@MainActor enum SolutionServiceChoiceChecks {
    static func run(_ store: AppStore, fixture: EngineServiceChecks.Fixture) async throws {
        let controller = store.solutions
        let drafts = controller.drafts, deployments = controller.deployments, selected = controller.selectedID
        let selectedDeployment = controller.selectedDeploymentID, editing = controller.editingID
        let reported = store.services.reportedModels, capabilities = store.services.modelCapabilities
        defer {
            controller.drafts = drafts; controller.deployments = deployments; controller.selectedID = selected
            controller.selectedDeploymentID = selectedDeployment; controller.editingID = editing
            store.services.reportedModels = reported; store.services.modelCapabilities = capabilities
            controller.save(); store.synchronizeGateway()
        }
        func require(_ condition: Bool, _ message: String) throws { try ConnectionChecks.require(condition, message) }
        let capability = ModelCapabilities(inputs: ["text"], outputs: ["text"], known: true, source: "fixture")
        for spec in [fixture.first, fixture.second] {
            store.services.reportedModels[spec.port] = ["fixture"]
            store.services.modelCapabilities[spec.port] = ["fixture": capability]
        }
        let choices = controller.serviceChoices(.chat, store: store)
        guard let first = choices.first(where: { $0.spec.id == fixture.first.id }),
              let second = choices.first(where: { $0.spec.id == fixture.second.id }) else { throw LaunchError.message("Compatible existing fixture services missing") }
        try require(first.id != second.id, "Two instances of one model were conflated")
        var draft = SolutionDraft(); draft.localChoices[SolutionRole.chat.rawValue] = second.id
        let component = try controller.selection(.chat, draft: draft, store: store)
        try require(component.serviceID == fixture.second.id && component.serviceBinding?.model == "fixture", "Explicit service or API model was ignored")
        try require(SolutionRecommendations.isCurrent(component, draft: draft), "Recipe default invalidated a compatible replacement")
        var translation = SolutionDraft(); translation.localChoices[SolutionRole.text.rawValue] = second.id
        try require(try controller.selection(.text, draft: translation, store: store).serviceID == fixture.second.id, "Non-Qwen service forced the recipe translator")
        let jobs = store.downloads.jobs.count, services = store.services.records.count
        controller.selectedID = "coding"; controller.setDraft(draft); controller.install(store: store)
        try await SolutionChecks.wait { controller.latest?.state == .configured || controller.latest?.state == .failed }
        guard let record = controller.latest else { throw LaunchError.message("No replacement deployment") }
        try require(record.state == .configured, record.error ?? "Existing service failed to configure")
        try require(record.components[0].serviceID == fixture.second.id && !record.components[0].ownsConfiguration, "Selected exact service was replaced or claimed")
        try require(store.downloads.jobs.count == jobs && store.services.records.count == services, "Reuse downloaded or duplicated a service")
        let endpoint = store.gateway.solutionEndpoint(record)
        controller.edit(record.id, store: store)
        try require(controller.draft.localChoices[SolutionRole.chat.rawValue] == second.id, "Editing lost the selected instance")
        controller.editingID = nil
        controller.replaceService(first.id, role: .chat, deploymentID: record.id, store: store)
        try await SolutionChecks.wait { controller.latest?.state == .configured || controller.latest?.state == .failed }
        let replacement = controller.latest!
        try require(replacement.id == record.id && store.gateway.solutionEndpoint(replacement) == endpoint, "Replacement changed the deployment or gateway URL")
        try require(replacement.components[0].serviceID == fixture.first.id, "Same-model replacement retained the wrong service ID")
        try require(controller.runtime(replacement, store: store).allReady, "Replacement runtime did not become ready")
        try require(store.downloads.jobs.count == jobs && store.services.records.count == services, "Replacement created resources")
        let restored = SolutionController(directory: controller.directory)
        try require(restored.deployments.first { $0.id == record.id }?.components[0].serviceBinding == replacement.components[0].serviceBinding, "Service binding did not persist")
        let transport = try SolutionTrialTransport(connection: .direct, deployment: replacement, store: store)
        try require(try transport.model(.chat, spec: fixture.first, store: store) == "fixture", "Direct trial did not use bound API model")
        store.synchronizeGateway()
        let routes = store.gateway.synchronizeSolutions([replacement], local: store.models, services: store.services)
        try require(routes[0].components[0].routeID == store.gateway.routes.first { $0.sourceID == fixture.first.id && $0.model == "fixture" }?.id && routes[0].components[0].routeID != nil, "Gateway selected another instance")
        let index = store.services.records.firstIndex { $0.id == fixture.first.id }!
        let original = store.services.records[index]
        store.services.records[index].modelName = "changed configuration"
        try require(controller.runtime(replacement, store: store).needsConfiguration, "Changed service identity remained ready")
        try require(store.gateway.synchronizeSolutions([replacement], local: store.models, services: store.services)[0].components[0].routeID == nil, "Changed service remained routed")
        store.services.records[index] = original
        store.services.records[index].modelID = "command:llama:example/Multilingual"
        store.services.records[index].modelPath = ""
        let commandChoice = controller.serviceChoices(.text, store: store).first { $0.spec.id == original.id }!
        let commandComponent = controller.serviceComponent(commandChoice, role: .text, store: store)
        try require(commandComponent.modelPath == "" && controller.boundServiceIssue(commandComponent, store: store) == nil, "Command-started service required recipe model files")
        store.services.records[index] = original
        var invalid = SolutionDraft(); invalid.localChoices[SolutionRole.chat.rawValue] = "service\nmissing\nfixture"
        do { _ = try controller.selection(.chat, draft: invalid, store: store); throw LaunchError.message("Deleted service silently fell back") }
        catch { try require(!error.localizedDescription.contains("silently fell back"), "Deleted service silently fell back") }
        store.services.modelCapabilities[fixture.first.port] = ["fixture": .init(inputs: ["text"], outputs: ["image"], known: true)]
        try require(!controller.serviceChoices(.text, store: store).contains { $0.spec.id == fixture.first.id }, "Image generator offered as translator")
        store.services.modelCapabilities[fixture.first.port] = ["fixture": capability]
        store.services.reportedModels[fixture.first.port] = ["netease-youdao/Confucius4-T3PO"]
        try require(!controller.serviceChoices(.text, store: store).contains { $0.spec.id == fixture.first.id }, "Protocol-incompatible translator offered for reuse")
        store.services.reportedModels[fixture.first.port] = ["fixture"]
        controller.remove(record.id, store: store)
        try require(processStartTime(fixture.first.pid!) == fixture.first.processStart && processStartTime(fixture.second.pid!) == fixture.second.processStart && FileManager.default.fileExists(atPath: fixture.model.path), "Replacing/removing reuse affected existing processes or weights")
        try ConnectionFiles.json(["result": "passed", "checks": ["exact service and API model selection", "no recipe download or duplicate service", "same-model instances switch independently", "fixed deployment ID and gateway URL", "binding persists and survives edit", "direct and gateway models agree", "changed/deleted service never silently falls back", "incompatible generation/protocol excluded", "reused native processes and model retained"]]).write(to: fixture.root.appendingPathComponent("service-replacements.json"))
    }
}
