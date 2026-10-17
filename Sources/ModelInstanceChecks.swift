import Foundation

@MainActor
enum ModelInstanceChecks {
    static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-instances").appendingPathComponent(UUID().uuidString)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        let fixture = try await EngineServiceChecks.prepare(store: store, root: root)
        do { try await exercise(store, fixture: fixture); await EngineServiceChecks.cleanup(store: store) }
        catch { await EngineServiceChecks.cleanup(store: store); throw error }
        try ConnectionFiles.json(["result": "passed", "checks": ["two same-model running instances counted independently", "stop updates running/stopped counts without affecting other PID", "delete updates counts and preserves other instance", "model versions and same names do not merge", "engine-scoped navigation and clear-filter", "model selection and launch context follow navigation", "known registration aliases and legacy file paths match", "unverified external names and engine identities excluded", "loading and failures are not reported as paused"], "realServicesModified": false]).write(to: root.appendingPathComponent("result.json"))
        print("MODEL INSTANCE CHECKS PASSED: \(root.path)")
    }
    static func exercise(_ store: AppStore, fixture: EngineServiceChecks.Fixture) async throws {
        let model = fixture.model, first = fixture.first, second = fixture.second
        var other = model; other.id = "another-revision"; other.path = fixture.root.appendingPathComponent("other.gguf").path
        try Data("GGUFother".utf8).write(to: URL(fileURLWithPath: other.path)); store.inventory?.models.append(other)
        let otherSpec = ServiceSpec(id: "other-model", engineID: "llama", modelID: other.id, modelName: model.name, modelPath: other.path, port: 29993)
        store.services.records.append(otherSpec)
        var counts = store.modelInstanceCounts(model)
        try ConnectionChecks.require(counts.total == 2 && counts.running == 2 && counts.stopped == 0 && store.modelInstanceCounts(other).stopped == 1, "Same-name revisions or stopped models were mixed")
        store.selectedModels["llama"] = other.id; store.showModelInstances(model, engineID: "llama")
        try ConnectionChecks.require(store.tab == .engines && store.engineSection == .services && store.engineID == "llama" && store.selectedModels["llama"] == model.id && Set(store.visibleEngineServices("llama").map(\.id)) == Set([first.id, second.id]), "Instance link did not route to the selected model's engine instances")
        store.engineInstanceFilter = nil
        try ConnectionChecks.require(store.visibleEngineServices("llama").count == 3, "Clear filter lost other model instances")
        store.showModelInstances(model, engineID: "llama"); store.chooseEngine("llama")
        try ConnectionChecks.require(store.engineInstanceFilter == nil, "Normal engine navigation kept a stale model filter")
        try await EngineServiceChecks.stopAndWait(first, store: store)
        counts = store.modelInstanceCounts(model, engineID: "llama")
        try ConnectionChecks.require(counts.total == 2 && counts.running == 1 && counts.stopped == 1 && processStartTime(second.pid!) == second.processStart, "Stopping one instance changed other model state")
        store.removeServiceConfiguration(first)
        counts = store.modelInstanceCounts(model)
        try ConnectionChecks.require(counts.total == 1 && counts.running == 1 && processStartTime(second.pid!) == second.processStart, "Deleting stopped instance affected the remaining one")
        var loading = second; loading.id = "loading-fixture"; loading.pid = nil
        store.services.records.append(loading); store.services.statuses[loading.id] = .starting
        counts = store.modelInstanceCounts(model)
        try ConnectionChecks.require(counts.starting == 1 && counts.stopped == 0 && counts.running == 1, "Loading was counted as stopped")
        store.services.statuses[loading.id] = .failed
        try ConnectionChecks.require(store.modelInstanceCounts(model).failed == 1 && store.modelInstanceCounts(model).stopped == 0, "Failure was counted as paused")
        store.services.records.removeAll { $0.id == loading.id }; store.services.statuses[loading.id] = nil
        let link = fixture.root.appendingPathComponent("model-alias.gguf"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: model.path))
        let legacy = ServiceSpec(id: "legacy", engineID: "llama", modelID: "unrecognized-legacy-id", modelName: model.name, modelPath: link.path, port: 29994)
        try ConnectionChecks.require(ModelInstancePolicy.matches(legacy, model: model, models: store.models, loaded: []), "Legacy path alias lost its local model")
        var distinct = legacy; distinct.modelID = other.id
        try ConnectionChecks.require(!ModelInstancePolicy.matches(distinct, model: model, models: store.models, loaded: []), "Known different revision was attributed by shared path")
        let alias = LocalModel(id: "old-registration", name: model.name, format: "Splash", path: fixture.root.path, kind: .language, bytes: model.bytes, complete: true, verification: "fixture", missingFiles: [], removalPath: fixture.root.path)
        var registered = model; registered.splashRegistrations = [.init(alias)]
        var splash = legacy; splash.engineID = "splash"; splash.modelID = alias.id; splash.modelPath = alias.path
        try ConnectionChecks.require(ModelInstancePolicy.matches(splash, model: registered, models: [registered], loaded: []) && ModelInstancePolicy.matches(splash, model: model, models: [registered], loaded: []), "Splash registration alias or refreshed model filter was not attributed")
        store.services.external = [.init(port: 29995, engineName: "Llama", models: [model.name], ready: true, engineID: "llama"), .init(port: 29996, engineName: "Unknown", models: [model.path], ready: true)]
        try ConnectionChecks.require(store.modelInstanceCounts(model).total == 1, "Ambiguous external model name or unknown engine was counted")
        store.services.external.append(.init(port: 29997, engineName: "Llama", models: [model.path], ready: true, engineID: "llama"))
        try ConnectionChecks.require(store.modelInstanceCounts(model).running == 2, "Confirmed external model path was not counted")
        store.showModelInstances(model, engineID: "llama")
        try ConnectionChecks.require(store.visibleExternalEngineServices("llama").map(\.port) == [29997], "Instance filter showed unrelated external services")
        store.services.external = []
    }
}
