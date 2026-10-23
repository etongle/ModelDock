import Foundation
import Darwin

enum ServiceFilterChecks {
    @MainActor static func run() throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-service-filters").appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let store = AppStore(stateDirectory: root)
        func spec(_ id: String, _ engine: String = "splash", _ port: Int = 29000) -> ServiceSpec {
            .init(id: id, engineID: engine, modelID: "fixture", modelName: "fixture", modelPath: "", port: port)
        }
        let running = spec("running"), stopped = spec("stopped"), starting = spec("starting", "llama"), stopping = spec("stopping", "llama"), failed = spec("failed", "llama")
        var owned = spec("owned-conflict", "splash", 29001); owned.pid = getpid(); owned.processStart = processStartTime(getpid())
        var stale = spec("stale"); stale.pid = getpid(); stale.processStart = processStartTime(getpid()) + 1
        store.services.records = [running, stopped, starting, stopping, failed, owned, stale]
        store.services.statuses = [running.id: .running, stopped.id: .stopped, starting.id: .starting, stopping.id: .stopping, failed.id: .failed, owned.id: .conflicted, stale.id: .stopped]
        let available = ObservedService(port: 29002, engineName: "Splash", models: ["fixture"], ready: true, engineID: "splash")
        let occupied = ObservedService(port: 29003, engineName: "Llama", models: [], ready: false, engineID: "llama")
        store.services.external = [available, occupied]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(store.services.records)
        func ids() -> Set<String> { Set(store.visibleServices.map(\.id)) }
        var checks: [String] = []
        try ConnectionChecks.require(ids().count == 7 && store.visibleExternalServices.count == 2, "All filter hid service configurations")
        store.serviceStateFilter = .started
        try ConnectionChecks.require(ids() == ["running", "starting", "stopping", "owned-conflict"] && store.visibleExternalServices.map(\.port) == [available.port], "Started filter mishandled loading, stopping or unverified ports")
        store.serviceStateFilter = .stopped
        try ConnectionChecks.require(ids() == ["stopped", "failed", "stale"] && store.visibleExternalServices.isEmpty, "Stopped filter hid failed configurations or showed active listeners")
        try ConnectionChecks.require(!ServiceStateFilter.stopped.matches(.failed, hasProcess: true), "Failed live process classified as stopped")
        checks.append("All/started/stopped distinguish active lifecycle, failed exited processes, live conflicts and recycled PIDs")
        store.serviceEngineFilter = "splash"
        try ConnectionChecks.require(ids() == ["stopped", "stale"], "Engine filter did not compose with stopped filter")
        store.serviceStateFilter = .started
        try ConnectionChecks.require(ids() == ["running", "owned-conflict"] && store.visibleExternalServices.count == 1, "Combined engine and started filters incorrect")
        store.serviceEngineFilter = "not-installed"; store.selectVisibleService()
        try ConnectionChecks.require(store.visibleServices.isEmpty && store.visibleExternalServices.isEmpty && store.selectedServiceID == nil && store.selectedExternal == nil, "Empty filter kept a hidden selection")
        store.clearServiceFilters()
        try ConnectionChecks.require(!store.hasServiceFilters && ids().count == 7, "Reset did not clear both filters")
        checks.append("Engine/state intersection, empty state and reset preserve configurations")
        store.selectedServiceID = running.id; store.serviceStateFilter = .stopped
        try ConnectionChecks.require(store.selectedServiceID == stopped.id, "Filter left detail selection on a hidden service")
        store.services.statuses[stopped.id] = .starting; store.selectVisibleService()
        try ConnectionChecks.require(!ids().contains(stopped.id) && store.selectedServiceID == failed.id, "Starting a stopped instance did not update the filtered selection")
        store.services.statuses[stopped.id] = .stopped
        store.serviceStateFilter = .started; store.showService(stopped)
        try ConnectionChecks.require(store.serviceStateFilter == .all && store.selectedServiceID == stopped.id, "Direct navigation hid the requested instance")
        store.serviceStateFilter = .stopped; store.showService(stopped)
        try ConnectionChecks.require(store.serviceStateFilter == .stopped, "Direct navigation unnecessarily cleared a matching filter")
        store.showExternalService(available)
        try ConnectionChecks.require(store.serviceStateFilter == .all && store.selectedExternal == available.port && !store.gatewaySelected, "External navigation kept a conflicting filter")
        store.serviceStateFilter = .stopped; store.showPortOwner(owned.port)
        try ConnectionChecks.require(store.serviceStateFilter == .all && store.selectedServiceID == owned.id && store.selectedExternal == nil, "Port owner remained hidden by state filter")
        checks.append("Status transitions repair selection; direct links reveal the requested managed/external service")
        store.serviceStateFilter = .stopped; store.showEngineServices("llama")
        try ConnectionChecks.require(store.serviceStateFilter == .all && store.serviceEngineFilter == "llama", "Engine service navigation kept a stale status filter")
        let unchanged = try encoder.encode(store.services.records)
        try ConnectionChecks.require(unchanged == original, "Filtering mutated service configuration")
        let report = try ConnectionFiles.json(["result": "passed", "checks": checks, "realServicesModified": false])
        try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
    }
}
