import Foundation

/// Isolated resources only: no installed engine, user model, or system Trash is changed.
@MainActor enum SolutionCleanupChecks {
    static func run(store: AppStore, fixture: EngineServiceChecks.Fixture) async throws {
        let controller = store.solutions, fm = FileManager.default
        func require(_ ok: Bool, _ text: String) throws { try ConnectionChecks.require(ok, text) }
        func deployment(_ service: ServiceSpec) -> SolutionDeployment {
            var record = SolutionDeployment(solutionID: "cleanup-fixture", draft: .init())
            record.state = .configured
            record.components = [.init(role: .text, engineID: service.engineID, modelID: service.modelID, modelPath: service.modelPath,
                repository: service.modelName, revision: "fixture", serviceID: service.id, ownsConfiguration: true)]
            if let pid = service.pid, let birth = service.processStart { record.processes = [.init(serviceID: service.id, pid: pid, birth: birth)] }
            return record
        }
        let engine = store.engines.first { $0.id == "llama" }!
        let port = try MultiModelPlanner.availablePorts(base: 29810, count: 1, occupied: NetworkProbe.portOccupied)[0]
        let retained = try store.services.start(engine: engine, model: fixture.model, port: port, context: 8192)
        _ = try await store.services.waitForReady(retained)
        let detached = deployment(retained)
        controller.deployments = [detached]; controller.selectedID = detached.solutionID; controller.save()
        try require(SolutionCleanupSelection().count == 0, "Optional cleanup must default to empty")
        try require(controller.removeInstance(detached.id, store: store), "Default instance deletion was rejected")
        try await SolutionChecks.wait { controller.removingIDs.isEmpty }
        try require(controller.deployments.isEmpty && processStartTime(retained.pid!) == retained.processStart && fm.fileExists(atPath: fixture.model.path), "Default deletion removed/stopped a service or model")
        let persisted = ServiceController(stateDirectory: store.services.stateDirectory)
        let saved = persisted.records.first { $0.id == retained.id }
        try require(saved?.solutionCreated == true && store.serviceOrigin(saved!).detached, "Retained solution-created service lost its manageable origin")
        try await EngineServiceChecks.stopAndWait(retained, store: store)
        try store.services.removeConfiguration(retained)

        let library = fixture.root.appendingPathComponent("cleanup-library"), modelURL = library.appendingPathComponent("candidate")
        let program = fixture.root.appendingPathComponent("cleanup-program/mflux")
        let cache = fixture.root.appendingPathComponent("shared-cache.bin")
        try fm.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: program, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelURL.appendingPathComponent("model.safetensors"))
        try Data("program".utf8).write(to: program.appendingPathComponent("runner"))
        try Data("shared cache".utf8).write(to: cache)
        let model = LocalModel(id: "cleanup-model", name: "cleanup-model", format: "MLX", path: modelURL.path, kind: .language,
            bytes: 7, complete: true, verification: "fixture", missingFiles: [], removalPath: modelURL.path)
        let base = Engine(kind: .mflux, name: "MFLUX", version: "fixture", path: program.appendingPathComponent("runner").path,
            installed: true, canServe: true, installation: "fixture", description: "fixture", defaultPort: 29820, symbol: "photo")
        store.inventory?.models.append(model); store.inventory?.engines.append(base)
        store.inventory?.roots = [library.path, URL(fileURLWithPath: fixture.model.path).path]
        controller.cleanupEnginePlanner = { engine, _ in
            let items = FileIdentity.read(program.path).map { [RemovalItem(path: program.path, group: .executable, note: "fixture", bytes: 7, identity: $0, formula: nil)] } ?? []
            return MaintenancePlan(engine: engine, mode: .uninstall, items: items, preserved: [library.path, cache.path], notes: [], blockers: [])
        }
        let trash = fixture.root.appendingPathComponent("fixture-trash"); try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        controller.cleanupTrash = { path in
            guard path.path == modelURL.path || path.path == program.path else { throw LaunchError.message("Fixture attempted cleanup outside its own resources") }
            try fm.moveItem(at: path, to: trash.appendingPathComponent(path.lastPathComponent))
        }
        defer { controller.cleanupEnginePlanner = nil; controller.cleanupTrash = nil }
        let stopped = ServiceSpec(engineID: base.id, modelID: model.id, modelName: model.name, modelPath: model.path, port: 29820)
        try store.services.registerConfiguration(stopped)
        let record = deployment(stopped); controller.deployments = [record]; controller.save()
        var plan = await controller.cleanupPlan(record, store: store)
        try require(plan.models.count == 1 && plan.engines.count == 1, "Cleanup inventory omitted model/base")
        let selected = SolutionCleanupSelection(services: [stopped.id], models: [model.id], engines: [base.id])
        func blocked(_ selection: SolutionCleanupSelection) -> Bool {
            do { try controller.validateCleanup(plan, selection: selection, store: store); return false } catch { return true }
        }
        try require(blocked(.init(models: [model.id])) && blocked(.init(engines: [base.id])), "Retained stopped configuration did not protect model/base")
        try require(!ModelFileSafety.used(model, removal: modelURL, services: [fixture.first, fixture.second], external: [], models: store.models, includingStopped: true), "Embedded GGUF tokenizer incorrectly protects unrelated sibling models")
        try controller.validateCleanup(plan, selection: selected, store: store)
        var borrower = record; borrower.id = UUID().uuidString; borrower.components[0].ownsConfiguration = false
        controller.deployments.append(borrower)
        try require(blocked(selected), "Another instance did not protect shared resources")
        try require(!controller.removeInstance(record.id, store: store, plan: plan, selection: selected) && fm.fileExists(atPath: model.path), "Failed preflight mutated resources")
        controller.deployments.removeLast()
        var other = stopped; other.id = UUID().uuidString; other.port += 1
        try store.services.registerConfiguration(other)
        try require(blocked(selected), "Another stopped service did not protect model/base")
        try store.services.removeConfiguration(other)
        var auxiliary = fixture.model; auxiliary.id = "auxiliary-reference"; auxiliary.association = .init(draftMode: .local, draftPath: model.path)
        store.inventory?.models.append(auxiliary); store.modelAssociations[auxiliary.id] = auxiliary.association
        try require(blocked(selected), "Auxiliary model reference did not protect weights")
        store.inventory?.models.removeAll { $0.id == auxiliary.id }; store.modelAssociations[auxiliary.id] = nil
        let download = ModelDownload(site: .huggingface, repository: "fixture/model", revision: "fixture", root: library.path, folder: "candidate",
            files: [.init(path: "model.safetensors", url: URL(string: "https://fixture.invalid/model")!, bytes: 7)], state: .paused)
        store.downloads.jobs.append(download)
        try require(blocked(selected), "Paused download did not protect model")
        store.downloads.jobs.removeAll { $0.id == download.id }
        store.services.external.append(.init(port: 29822, engineName: base.name, models: [], ready: true, statusCode: 200, engineID: base.id))
        try require(blocked(selected), "External service did not protect base")
        store.services.external.removeAll { $0.port == 29822 }
        // A swapped directory must invalidate the old preview even with the same path/name.
        let old = library.appendingPathComponent("old-candidate")
        try fm.moveItem(at: modelURL, to: old); try fm.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try require(blocked(selected), "Replaced model directory retained stale cleanup permission")
        try fm.removeItem(at: modelURL); try fm.moveItem(at: old, to: modelURL)
        plan = await controller.cleanupPlan(record, store: store)
        try controller.validateCleanup(plan, selection: selected, store: store)
        // Service-only opt-in leaves model, engine, cache and other native services intact.
        try require(controller.removeInstance(record.id, store: store, plan: plan, selection: .init(services: [stopped.id])), "Service-only cleanup rejected")
        try await SolutionChecks.wait { controller.removingIDs.isEmpty }
        try require(!store.services.records.contains { $0.id == stopped.id } && fm.fileExists(atPath: model.path) && fm.fileExists(atPath: program.path), controller.message ?? "Service-only cleanup removed resources")
        var disposable = stopped; disposable.id = UUID().uuidString
        try store.services.registerConfiguration(disposable)
        let final = deployment(disposable); controller.deployments = [final]; controller.save()
        let finalPlan = await controller.cleanupPlan(final, store: store)
        try require(controller.removeInstance(final.id, store: store, plan: finalPlan,
            selection: .init(services: [disposable.id], models: [model.id], engines: [base.id])), "Explicit resource cleanup rejected")
        try await SolutionChecks.wait { controller.removingIDs.isEmpty }
        try require(controller.message == nil && !fm.fileExists(atPath: model.path) && !fm.fileExists(atPath: program.path) && fm.fileExists(atPath: cache.path), controller.message ?? "Explicit cleanup failed or touched shared cache")
        try require(fm.fileExists(atPath: trash.appendingPathComponent("candidate/model.safetensors").path) && fm.fileExists(atPath: trash.appendingPathComponent("mflux/runner").path), "Selected resources were not recoverably moved")
        try require(processStartTime(fixture.first.pid!) == fixture.first.processStart && processStartTime(fixture.second.pid!) == fixture.second.processStart && fm.fileExists(atPath: fixture.model.path), "Cleanup affected unrelated native services/models")
        print("SOLUTION CLEANUP CHECKS PASSED: defaults, shared/stopped/auxiliary/download/external references, stale preview, service-only and opt-in resources")
    }
}
