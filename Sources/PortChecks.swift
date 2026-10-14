import Foundation
import Darwin

@MainActor
enum PortChecks {
    static func run() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-port-checks").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state")
        let controller = ServiceController(stateDirectory: state)
        let source = URL(fileURLWithPath: argumentValue("--fixture-script") ?? fm.currentDirectoryPath + "/Tests/model_service_fixture.py")
        let fixture = String(decoding: try Data(contentsOf: source), as: UTF8.self)
        func executable(_ name: String, delay: Bool = false) throws -> String {
            let file = root.appendingPathComponent(name)
            try Data(("#!/usr/bin/python3\n" + (delay ? "import time\ntime.sleep(1.5)\n" : "") + fixture).utf8).write(to: file)
            chmod(file.path, 0o755); return file.path
        }
        let engines = Scanner.engines()
        var mlx = engines.first { $0.kind == .mlx }!; mlx.canServe = true; mlx.installed = true
        let actualSplash = try executable("splash")
        let actualMLX = try executable("mlx_lm.server")
        let delayed = try executable("delayed-server", delay: true)
        let folder = root.appendingPathComponent("model")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = LocalModel(id: "port-fixture", name: "Port fixture", format: "MLX", path: folder.path, kind: .language, bytes: 0, complete: true, verification: "fixture", missingFiles: [], removalPath: folder.path)
        let ports = try MultiModelPlanner.availablePorts(base: 29500, count: 5)
        var started: [ServiceSpec] = []; var checks: [String] = []
        func waitReady(_ specs: [ServiceSpec]) async throws {
            for _ in 0..<50 {
                await controller.refresh()
                if specs.allSatisfy({ controller.status($0) == .running }) { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw LaunchError.message("Fixture readiness failed")
        }
        func clean() async {
            for spec in started where controller.records.first(where: { $0.id == spec.id })?.pid != nil { try? controller.stop(spec) }
            for _ in 0..<40 {
                if ports.allSatisfy({ !NetworkProbe.portOccupied($0) }) && started.allSatisfy({ spec in spec.pid.map { kill($0, 0) != 0 } ?? true }) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        do {
            // Identical APIs with intentionally incorrect saved engine metadata.
            mlx.path = actualSplash
            let splash = try controller.start(engine: mlx, model: model, port: ports[0], context: 8192); started.append(splash)
            mlx.path = actualMLX
            let native = try controller.start(engine: mlx, model: model, port: ports[1], context: 8192); started.append(native)
            try await waitReady([splash, native])
            try FeatureChecks.require(controller.records.first { $0.id == splash.id }?.engineID == "splash", "Actual Splash process mislabeled as MLX")
            try FeatureChecks.require(controller.identifies(engineID: "splash", port: ports[0]) && !controller.identifies(engineID: "mlx", port: ports[0]), "Port overrode engine identity")
            checks.append("Same API: verified Splash process repairs incorrect saved MLX label")
            controller.records.append(ServiceSpec(engineID: "ollama", modelID: "old", modelName: "Stopped history", modelPath: "", port: ports[0]))
            await controller.refresh()
            try FeatureChecks.require(controller.status(splash) == .running && controller.reportedModels[ports[0]] == ["fixture"], "Stopped history altered active probing")
            checks.append("Stopped history cannot change active identity or probe protocol")
            let index = controller.records.firstIndex { $0.id == native.id }!
            controller.records[index].port = ports[0]
            await controller.refresh()
            try FeatureChecks.require(controller.status(native) == .conflicted && controller.status(splash) == .running, "Unrelated process accepted another listener's readiness")
            let conflicted = AppStore(stateDirectory: state)
            conflicted.inventory = .init(engines: [mlx], models: [model], storageBytes: 0, memoryBytes: 0, chip: "Fixture", roots: [], warnings: [], scannedAt: Date())
            conflicted.engineID = "mlx"; conflicted.selectedModels["mlx"] = model.id; conflicted.port = String(ports[0])
            await conflicted.services.refresh()
            try FeatureChecks.require(!conflicted.canStart && conflicted.benchmarkTargets.allSatisfy { $0.engineID != "mlx" }, "Conflicted MLX remained startable or benchmarkable")
            checks.append("Wrong listener causes conflict, disables startup and excludes wrong-engine benchmarks")
            controller.records[index].port = ports[1]
            try await waitReady([splash, native])
            let outside = ServiceController(stateDirectory: root.appendingPathComponent("external"))
            outside.records = [ServiceSpec(engineID: "mlx", modelID: "old", modelName: "History", modelPath: "", port: ports[0])]
            await outside.refresh()
            try FeatureChecks.require(outside.external.first { $0.port == ports[0] }?.engineID == "splash", "External Splash inherited stopped MLX metadata")
            checks.append("External Splash recognized despite stopped MLX history")
            mlx.path = delayed
            let pending = try controller.start(engine: mlx, model: model, port: ports[2], context: 8192); started.append(pending)
            try FeatureChecks.require(controller.portReserved(ports[2]) && !NetworkProbe.portOccupied(ports[2]), "Pending launch did not reserve port")
            do { _ = try controller.start(engine: mlx, model: model, port: ports[2], context: 8192); throw LaunchError.message("Duplicate port accepted") }
            catch LaunchError.message(let text) where text.contains("已由") { }
            try await waitReady([pending])
            let unknown = ServiceController(stateDirectory: root.appendingPathComponent("unknown"))
            unknown.records = [ServiceSpec(engineID: "mlx", modelID: "old", modelName: "History", modelPath: "", port: ports[2])]
            await unknown.refresh()
            try FeatureChecks.require(unknown.external.first { $0.port == ports[2] }?.engineID == nil && unknown.external.first { $0.port == ports[2] }?.ready == true, "Unknown interpreter guessed as MLX")
            checks.append("Pending launch reserves port; unknown external engine stays unidentified despite working API")
            let splashEngine = engines.first { $0.kind == .splash }!
            let allocated = try EnginePortPolicy.available(engine: splashEngine, base: 8079, count: 4, occupied: { _ in false })
            try FeatureChecks.require(allocated == [8079, 8082, 8083, 8084], "Allocation reused Prism/MLX defaults")
            let reservation = try EnginePortPolicy.available(engine: mlx, base: ports[2], count: 1, occupied: { controller.portReserved($0) })
            try FeatureChecks.require(reservation == [ports[3]], "Planner ignored active reservations")
            let store = AppStore(stateDirectory: root.appendingPathComponent("selection"))
            store.inventory = .init(engines: [splashEngine, mlx], models: [model], storageBytes: 0, memoryBytes: 0, chip: "Fixture", roots: [], warnings: [], scannedAt: Date())
            store.services.records = controller.records; store.selectedModels["mlx"] = model.id
            store.chooseEngine("mlx")
            try FeatureChecks.require(store.port == String(ports[1]), "Engine switch lost own service port")
            store.port = String(ports[0]); await store.services.refresh()
            try FeatureChecks.require(!store.canStart && store.portConflict?.contains("Splash") == true, "Conflict did not name actual owner")
            store.useFreePort()
            try FeatureChecks.require(store.parsedPort != ports[0] && store.portConflict == nil, "Choose free port did not resolve conflict")
            checks.append("Allocation skips other defaults and reservations; switch restores own service; GUI names owner and resolves conflict")
            if CommandLine.arguments.contains("--check-existing-splash") {
                let userState = Scanner.home.appendingPathComponent("Library/Application Support/ModelManager/services.json")
                var live = try JSONDecoder().decode([ServiceSpec].self, from: Data(contentsOf: userState))
                guard let index = live.firstIndex(where: { $0.engineID == "splash" && $0.pid != nil }) else { throw LaunchError.message("Existing Splash missing") }
                let saved = live[index]; live[index].engineID = "mlx"
                let observed = ServiceController(stateDirectory: root.appendingPathComponent("existing-readonly-copy")); observed.records = live
                await observed.refresh()
                try FeatureChecks.require(observed.records[index].engineID == "splash" && observed.status(saved) == .running && observed.records[index].pid == saved.pid, "Real Splash identity recovery failed")
                checks.append("Real Splash read-only verification: copied MLX label corrected, PID preserved and endpoint ready")
            }
            await clean()
            try FeatureChecks.require(started.allSatisfy { $0.pid.map { kill($0, 0) != 0 } ?? true }, "Fixture processes not stopped")
        } catch { await clean(); throw error }
        let report: [String: Any] = ["result": "passed", "checks": checks, "fixture_ports": ports, "real_service_stopped": false, "real_model_files_changed": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self)); print("Evidence: \(root.path)")
    }
}
