import Foundation

@MainActor enum SolutionRemovalChecks {
    static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-solution-removal").appendingPathComponent(UUID().uuidString)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        let fixture = try await EngineServiceChecks.prepare(store: store, root: root)
        do {
            let engine = store.engines.first { $0.id == "llama" }!
            let ports = try MultiModelPlanner.availablePorts(base: 29780, count: 2, occupied: NetworkProbe.portOccupied)
            let exclusive = try store.services.start(engine: engine, model: fixture.model, port: ports[0], context: 8192)
            let shared = try store.services.start(engine: engine, model: fixture.model, port: ports[1], context: 8192)
            _ = try await store.services.waitForReady(exclusive); _ = try await store.services.waitForReady(shared)
            func component(_ role: SolutionRole, _ service: ServiceSpec, owned: Bool) -> SolutionComponent {
                .init(role: role, engineID: service.engineID, modelID: service.modelID, modelPath: service.modelPath, repository: fixture.model.name, revision: "", serviceID: service.id, ownsConfiguration: owned)
            }
            var owner = SolutionDeployment(solutionID: "ownership-fixture", draft: .init())
            owner.state = .configured
            owner.components = [component(.asr, shared, owned: true), component(.text, fixture.first, owned: false), component(.tts, exclusive, owned: true)]
            owner.processes = [shared, exclusive].map { .init(serviceID: $0.id, pid: $0.pid!, birth: $0.processStart!) }
            var borrower = SolutionDeployment(solutionID: "ownership-fixture", draft: .init())
            borrower.state = .configured; borrower.components = [component(.asr, shared, owned: false)]
            let controller = store.solutions
            controller.deployments = [owner, borrower]; controller.selectedID = owner.solutionID; controller.selectedDeploymentID = owner.id
            controller.save(); store.synchronizeGateway()
            let plan = controller.removalItems(owner, store: store)
            try ConnectionChecks.require(plan.filter { $0.action == .remove }.count == 1 && plan.filter { $0.action == .native }.count == 1 && plan.filter { $0.action == .shared }.count == 1, "Deletion plan confused exclusive, native and shared services")
            controller.removeInstance(owner.id, store: store, selection: .init(services: [exclusive.id]))
            try await SolutionChecks.wait { controller.removingIDs.isEmpty }
            try ConnectionChecks.require(!controller.deployments.contains { $0.id == owner.id } && !store.services.records.contains { $0.id == exclusive.id }, controller.message ?? "Exclusive instance/service was not removed")
            try ConnectionChecks.require(processStartTime(shared.pid!) == shared.processStart && processStartTime(fixture.first.pid!) == fixture.first.processStart && processStartTime(fixture.second.pid!) == fixture.second.processStart, "Deletion stopped a shared/native/unrelated service")
            try ConnectionChecks.require(controller.deployments[0].components[0].ownsConfiguration && controller.deployments[0].processes.contains { $0.serviceID == shared.id } && controller.selectedDeploymentID == borrower.id, "Shared ownership or selected instance was not transferred")
            try ConnectionChecks.require(!store.gateway.solutionRoutes.contains { $0.id == owner.id.lowercased() } && store.gateway.solutionRoutes.contains { $0.id == borrower.id.lowercased() }, "Deletion removed another instance's URL or retained the deleted URL")
            controller.removeInstance(borrower.id, store: store, selection: .init(services: [shared.id]))
            try await SolutionChecks.wait { controller.removingIDs.isEmpty }
            try ConnectionChecks.require(controller.deployments.isEmpty && !store.services.records.contains { $0.id == shared.id } && FileManager.default.fileExists(atPath: fixture.model.path), controller.message ?? "Last owner cleanup failed or deleted model weights")
            try ConnectionChecks.require(processStartTime(fixture.first.pid!) == fixture.first.processStart && processStartTime(fixture.second.pid!) == fixture.second.processStart, "Last owner deletion affected native services")
            try await SolutionCleanupChecks.run(store: store, fixture: fixture)
            await EngineServiceChecks.cleanup(store: store)
        } catch { await EngineServiceChecks.cleanup(store: store); throw error }
        print("SOLUTION INSTANCE REMOVAL CHECKS PASSED: " + root.path)
    }
}
