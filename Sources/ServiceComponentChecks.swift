import Foundation

enum ServiceComponentChecks {
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store.services.pauseMonitoring()
        for _ in 0..<80 { if !store.services.polling { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        let realRoot = Scanner.home.appendingPathComponent("Library/Application Support/ModelManager")
        let records = try JSONDecoder().decode([ServiceSpec].self, from: Data(contentsOf: realRoot.appendingPathComponent("services.json")))
        let inventory = Scanner.scan(); store.inventory = inventory
        var reportRows: [[String: Any]] = [], previews: [ServiceSpec] = []
        for original in records where original.pid != nil && original.engineID == "splash" {
            let probe = await NetworkProbe.models(port: original.port)
            guard probe.ready else { continue }
            let log = String(decoding: try Data(contentsOf: realRoot.appendingPathComponent("logs/" + original.id + ".log")), as: UTF8.self)
            let capabilities = probe.capabilities[original.modelName] ?? ModelCapabilities()
            guard let value = ServiceComponentEvidence.collect(spec: original, models: inventory.models, log: log, capabilities: capabilities, status: .running) else { throw LaunchError.message("Actual service component information missing") }
            try ConnectionChecks.require(value.entries.contains { $0.id == "draft" && $0.name == "incoai/Qwen3.8-27B-DFlash2" && $0.state == "已启用" && $0.path != nil }, "Actual DFlash2 draft was not recognized")
            try ConnectionChecks.require(value.entries.contains { $0.id == "vision" && $0.state == "已启用" } && value.entries.contains { $0.id == "tokenizer" && $0.path != nil }, "Actual vision/tokenizer information missing")
            // Preview records deliberately cannot own any real process.
            var preview = original; preview.pid = 999999; preview.processStart = 999999; preview.componentSnapshot = nil
            store.services.records = [preview]; store.services.statuses[preview.id] = .running
            store.services.modelCapabilities[preview.port] = probe.capabilities
            store.services.reportedModels[preview.port] = probe.models
            try Data(log.utf8).write(to: store.services.logURL(preview.id))
            store.inventory = nil; store.captureServiceComponents()
            try ConnectionChecks.require(store.services.records.first?.componentSnapshot == nil, "Incomplete inventory was pinned before component paths were available")
            store.inventory = inventory
            store.captureServiceComponents()
            guard let saved = store.services.records.first, saved.componentSnapshot != nil else { throw LaunchError.message("Component snapshot was not saved") }
            let reopened = ServiceController(stateDirectory: store.services.stateDirectory)
            try ConnectionChecks.require(reopened.records.first?.componentSnapshot?.entries == saved.componentSnapshot?.entries, "Component snapshot did not survive reopening")
            if let draft = inventory.models.first(where: { $0.origin?.repository == "incoai/Qwen3.8-27B-DFlash2" }) {
                try ConnectionChecks.require(ModelFileSafety.used(draft, removal: URL(fileURLWithPath: draft.path), services: [saved], external: [], models: inventory.models), "Captured automatic draft was not protected from deletion")
            }
            for model in store.models { store.modelAssociations[model.id] = .init(draftMode: .disabled) }
            try ConnectionChecks.require(store.serviceComponents(saved)?.entries.contains { $0.id == "draft" && $0.state == "已启用" } == true, "New model configuration changed active service components")
            let nextLog = log + "\n—— next launch ——\nLoading main model only\n"
            var next = preview; next.commandText = "splash serve --model " + original.modelName + " --language-only"; next.inputMode = .text
            let nextValue = ServiceComponentEvidence.collect(spec: next, models: inventory.models, log: nextLog, capabilities: .init(inputs: ["text"], known: true, source: "fixture"), status: .starting)
            try ConnectionChecks.require(nextValue?.entries.contains { $0.id == "draft" } != true && nextValue?.entries.first { $0.id == "vision" }?.state == "未启用", "Old launch draft/vision leaked into current attempt")
            reportRows.append(["port": original.port, "model": original.modelName, "draft": "incoai/Qwen3.8-27B-DFlash2", "vision": true, "tokenizer": "main model"])
            previews.append(saved)
        }
        try ConnectionChecks.require(!previews.isEmpty, "No live Splash service available for read-only component verification")
        store.services.records = previews
        for preview in previews { store.services.statuses[preview.id] = .running }
        let managedPorts = Set(previews.map(\.port))
        store.services.external.removeAll { managedPorts.contains($0.port) }
        store.showService(previews.last!); try await capture?("service-components")
        store.engineID = "splash"; store.tab = .engines; try await capture?("engine-components-summary")
        store.services.records = []
        let report: [String: Any] = ["result": "passed", "actualServices": reportRows, "realServicesModified": false, "checks": ["actual startup log and API draft/vision/tokenizer recognition", "old command services without explicit draft arguments", "snapshot persistence", "wait for inventory before pinning component paths", "captured automatic draft deletion protected", "later model association does not alter active components", "new launch does not inherit old draft logs", "pure text is visibly disabled", "preview records cannot own real processes"]]
        try ConnectionFiles.json(report).write(to: root.appendingPathComponent("result.json")); print(root.path)
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/service-component-checks").appendingPathComponent(UUID().uuidString)
        try await exercise(store: AppStore(stateDirectory: root.appendingPathComponent("state")), root: root)
    }
}
