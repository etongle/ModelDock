import Foundation

/// 服务随 App 启动、按已保存配置启动、参数预设。
enum ServiceBehaviorChecks {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-service-behavior").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        let script = root.appendingPathComponent("llama-server")
        try ConnectionFiles.write(Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Tests/gateway_fixture.py")), to: script, executable: true)
        let weight = root.appendingPathComponent("fixture.gguf"); try Data("GGUF".utf8).write(to: weight)
        let model = LocalModel(id: "behavior-fixture", name: "fixture", format: "GGUF", path: weight.path, kind: .language, bytes: 4, complete: true, verification: "fixture", missingFiles: [], removalPath: weight.path)
        let engine = Engine(kind: .llama, name: "Llama", version: "fixture", path: script.path, installed: true, canServe: true, installation: "fixture", description: "fixture", defaultPort: 29960, symbol: "terminal")
        store.inventory = .init(engines: [engine], models: [model], storageBytes: 4, memoryBytes: 0, chip: "fixture", roots: [root.path], warnings: [], scannedAt: Date())
        let port = try MultiModelPlanner.availablePorts(base: 29960, count: 1, occupied: NetworkProbe.portOccupied)[0]
        // 先启动再停止，得到一条已保存（带附加参数）的服务配置。
        let first = try store.services.start(engine: engine, model: model, port: port, context: 16384, extraArguments: ["--threads", "2"])
        for _ in 0..<60 { await store.services.refresh(); if store.services.status(first) == .running { break }; try await Task.sleep(nanoseconds: 150_000_000) }
        store.stop(first)
        for _ in 0..<60 { await store.services.refresh(); if !NetworkProbe.portOccupied(port) { break }; try await Task.sleep(nanoseconds: 200_000_000) }
        store.services.updateBehavior(first.id, autoStart: true)
        // 重新载入状态目录，模拟应用重启。
        let reopened = AppStore(stateDirectory: root.appendingPathComponent("state"))
        reopened.inventory = store.inventory
        try ConnectionChecks.require(reopened.services.records.first?.autoStart == true, "autoStart not persisted")
        reopened.autoStartServices()
        guard let started = reopened.services.records.first(where: { $0.id == first.id }), started.pid != nil else { throw LaunchError.message("Auto-start did not start the service: \(reopened.message ?? "")") }
        try ConnectionChecks.require(started.context == 16384 && started.extraArguments == ["--threads", "2"], "Auto-start lost saved parameters")
        for _ in 0..<60 { await reopened.services.refresh(); if reopened.services.status(started) == .running { break }; try await Task.sleep(nanoseconds: 150_000_000) }
        try reopened.services.stop(started)
        // 参数预设：保存、套用、删除并持久化。
        let draft = ServiceParameterDraft(started); draft.context = 65536; draft.inputMode = .text; draft.extra = "--threads 8"
        reopened.saveServicePreset(name: "长上下文", engine: engine, draft: draft)
        try ConnectionChecks.require(draft.error == nil && reopened.servicePresets.count == 1, "Preset not saved: \(draft.error ?? "")")
        let other = ServiceParameterDraft(started)
        reopened.applyServicePreset(reopened.servicePresets[0], to: other)
        try ConnectionChecks.require(other.context == 65536 && other.inputMode == .text && other.extra == "--threads 8", "Preset not applied")
        reopened.saveServicePreset(name: "长上下文", engine: engine, draft: other)
        try ConnectionChecks.require(reopened.servicePresets.count == 1, "Same-name preset should be replaced")
        let bad = ServiceParameterDraft(started); bad.extra = "--port 1"
        reopened.saveServicePreset(name: "坏", engine: engine, draft: bad)
        try ConnectionChecks.require(bad.error != nil && reopened.servicePresets.count == 1, "Preset with reserved flag accepted")
        let again = AppStore(stateDirectory: root.appendingPathComponent("state")); again.loadServicePresets()
        try ConnectionChecks.require(again.servicePresets.first?.name == "长上下文", "Preset not persisted")
        again.deleteServicePreset(again.servicePresets[0])
        try ConnectionChecks.require(again.servicePresets.isEmpty, "Preset not deleted")
        for _ in 0..<40 { await reopened.services.refresh(); if !NetworkProbe.portOccupied(port) { break }; try await Task.sleep(nanoseconds: 250_000_000) }
        // 命令启动的服务：按已保存配置启动时重新解析原命令，命令文本保留（引擎更新后的自动重启也走这里）。
        let commandPort = try MultiModelPlanner.availablePorts(base: port + 1, count: 1, occupied: NetworkProbe.portOccupied)[0]
        let command = try ServiceCommand.parse("\(script.path) -m \(weight.path) --port \(commandPort) -c 8192", engine: engine, models: [model])
        let launched = try reopened.services.start(command: command)
        for _ in 0..<60 { await reopened.services.refresh(); if reopened.services.status(launched) == .running { break }; try await Task.sleep(nanoseconds: 150_000_000) }
        try reopened.services.stop(launched)
        for _ in 0..<60 { await reopened.services.refresh(); if !NetworkProbe.portOccupied(commandPort) { break }; try await Task.sleep(nanoseconds: 200_000_000) }
        let saved = reopened.services.records.first { $0.id == launched.id } ?? launched
        let restarted = try reopened.startSaved(saved)
        try ConnectionChecks.require(restarted.pid != nil && restarted.commandText == saved.commandText && restarted.port == commandPort, "Command-launched service not restarted from its command")
        for _ in 0..<60 { await reopened.services.refresh(); if reopened.services.status(restarted) == .running { break }; try await Task.sleep(nanoseconds: 150_000_000) }
        try reopened.services.stop(restarted)
        for _ in 0..<40 { await reopened.services.refresh(); if !NetworkProbe.portOccupied(commandPort) { break }; try await Task.sleep(nanoseconds: 250_000_000) }
        let report = try ConnectionFiles.json(["result": "passed", "checks": ["Auto-start persists and starts with saved parameters", "Presets save, apply, replace, reject reserved flags, persist and delete", "Command-launched service restarts from its saved command"]])
        try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
    }
}
