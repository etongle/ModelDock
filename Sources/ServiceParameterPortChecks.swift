import Foundation

@MainActor enum ServiceParameterPortChecks {
    static func run(root: URL, engine: Engine, model: LocalModel, occupying: ServiceSpec) async throws {
        // A second controller represents an external application's listener.
        let store = AppStore(stateDirectory: root.appendingPathComponent("port-preflight-state"))
        store.inventory = .init(engines: [engine], models: [model], storageBytes: model.bytes, memoryBytes: 0, chip: "fixture", roots: [root.path], warnings: [], scannedAt: Date())
        let stopped = ServiceSpec(engineID: engine.id, modelID: model.id, modelName: model.name, modelPath: model.path, port: occupying.port)
        try store.services.registerConfiguration(stopped)
        do {
            await store.services.refresh()
            let draft = ServiceParameterDraft(stopped); draft.context = 16384; draft.extra = "--threads 3"
            store.saveServiceParameters(draft, spec: stopped, launch: true)
            try ConnectionChecks.require(draft.error?.contains("端口") == true && draft.error?.contains("恢复") != true && store.relaunchingServiceID == nil, "Stopped same-port conflict entered restart/rollback")
            try ConnectionChecks.require(store.services.records[0].context == stopped.context && store.services.records[0].pid == nil && !FileManager.default.fileExists(atPath: store.services.logURL(stopped.id).path), "Preflight changed parameters or attempted a process launch")
            try ConnectionChecks.require(processStartTime(occupying.pid!) == occupying.processStart, "Preflight stopped an external listener")
            store.useFreeServicePort(draft, spec: stopped)
            guard let free = Int(draft.port), free != occupying.port else { throw LaunchError.message("Free-port helper did not update the draft") }
            try ConnectionChecks.require(!NetworkProbe.portOccupied(free) && store.services.records[0].port == occupying.port && draft.context == 16384 && draft.extra == "--threads 3", "Free-port helper saved prematurely or lost edited parameters")
            store.saveServiceParameters(draft, spec: stopped, launch: true)
            for _ in 0..<120 { if store.relaunchingServiceID == nil { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            guard let started = store.services.records.first, started.pid != nil else { throw LaunchError.message(draft.error ?? "Free-port launch failed") }
            try ConnectionChecks.require(draft.error == nil && started.id == stopped.id && store.services.records.count == 1 && started.port == free && started.context == 16384 && started.extraArguments == ["--threads", "3"], "Free-port launch duplicated the instance or changed saved parameters")
            try ConnectionChecks.require(store.services.status(started) == .running && processStartTime(occupying.pid!) == occupying.processStart, "Free-port launch affected another process")
            // A running current service cannot exempt a different occupied port,
            // even when the external listener cache has not caught up yet.
            store.services.external = []; store.services.listeners = [:]
            try ConnectionChecks.require(store.services.portConflict(occupying.port, excluding: started.id) != nil, "Running service exempted an unrelated occupied port")
            let changed = ServiceParameterDraft(started); changed.port = String(occupying.port); changed.context = 32768
            store.saveServiceParameters(changed, spec: started, launch: true)
            try ConnectionChecks.require(changed.error?.contains("端口") == true && store.services.records[0].pid == started.pid && store.services.records[0].context == 16384, "Changed-port preflight stopped or modified the current service")
            await EngineServiceChecks.cleanup(store: store)
        } catch { await EngineServiceChecks.cleanup(store: store); throw error }
        print("SERVICE PARAMETER PORT CHECKS PASSED: external same-port preflight, preserved draft, free-port start, stable instance ID, unrelated PID isolation")
    }
}
