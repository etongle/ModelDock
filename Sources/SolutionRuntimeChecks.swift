import Foundation

@MainActor enum SolutionRuntimeChecks {
    static func run(store: AppStore, deployment: SolutionDeployment) async throws {
        let controller = store.solutions
        let inventory = store.inventory, records = controller.deployments
        let selected = controller.selectedDeploymentID
        let processes = store.services.records.map { "\($0.id):\($0.pid ?? 0):\($0.processStart ?? 0)" }
        defer {
            store.inventory = inventory; controller.deployments = records
            controller.selectedDeploymentID = selected
            store.synchronizeGateway()
        }
        func require(_ value: Bool, _ message: String) throws { try ConnectionChecks.require(value, message) }
        await controller.refreshAudioProtocols(store: store)
        try require(controller.runtime(deployment, store: store).allReady, "Healthy solution was not ready")
        let asr = deployment.components.first { $0.role == .asr }!
        let service = store.services.records.first { $0.id == asr.serviceID }!
        controller.audioVersions[service.id] = 1
        var state = controller.runtime(deployment, store: store)
        try require(!state.allReady && state.needsReload && state.components.first { $0.id == asr.id }?.phase == .reload, "Running old audio helper was shown as solution-ready")
        controller.audioVersions[service.id] = 2
        controller.audioProcessStarts[service.id] = (service.processStart ?? 0) + 1
        state = controller.runtime(deployment, store: store)
        try require(!state.allReady && state.components.first { $0.id == asr.id }?.phase == .checking, "Protocol result from another process was reused")
        await controller.refreshAudioProtocols(store: store)
        try require(controller.runtime(deployment, store: store).allReady, "Audio protocol recheck did not restore readiness")

        var incompatible = store.models.first { $0.id == deployment.components.first { $0.role == .text }?.modelID }!
        incompatible.id = UUID().uuidString; incompatible.origin = nil
        incompatible.repository = "netease-youdao/Confucius4-T3PO"; incompatible.name = "Confucius4-T3PO"
        store.inventory?.models.append(incompatible)
        var old = deployment; old.id = UUID().uuidString
        old.components[old.components.firstIndex { $0.role == .text }!].modelID = incompatible.id
        controller.deployments.append(old)
        controller.selectedID = old.solutionID
        controller.selectDeployment(old.id, store: store)
        state = controller.runtime(controller.latest!, store: store)
        try require(controller.latest?.id == old.id && state.needsConfiguration && state.ready == state.total - 1, "Selected historical configuration used another configuration's status")
        try require(state.components.first { $0.component.role == .text }?.phase == .configuration, "Running incompatible model was shown as ready")
        controller.audioVersions[service.id] = 1
        try require(controller.runtime(deployment, store: store).hasSharedReload, "Shared outdated helper did not require explicit service management")
        controller.audioVersions[service.id] = 2
        controller.start(old.id, store: store)
        try await SolutionChecks.wait { !controller.startingIDs.contains(old.id) }
        try require(controller.deployments.first { $0.id == old.id }?.error != nil && store.services.records.map { "\($0.id):\($0.pid ?? 0):\($0.processStart ?? 0)" } == processes, "Invalid solution start mutated running services")
        store.synchronizeGateway()
        try require(store.gateway.solutionRoutes.first { $0.id == old.id.lowercased() }?.components.first { $0.role == "translation" }?.routeID == nil, "Incompatible translator remained exposed as a valid solution route")
        controller.selectDeployment(deployment.id, store: store)
        try require(controller.latest?.id == deployment.id && controller.runtime(controller.latest!, store: store).allReady, "Switching back did not restore selected configuration readiness")
    }
}
