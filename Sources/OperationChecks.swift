import Foundation
import Darwin

enum OperationChecks {
    @MainActor static func liveMulti() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-live-multi").appendingPathComponent(UUID().uuidString)
        let inventory = Scanner.scan()
        guard let engine = inventory.engines.first(where: { $0.kind == .prism }) else { throw LaunchError.message("Prism engine unavailable") }
        let candidates = inventory.models.filter { $0.kind == .language && $0.compatible(with: engine) }.sorted { $0.bytes < $1.bytes }
        let models = Array(candidates.prefix(2))
        guard models.count == 2 else { throw LaunchError.message("Two compatible models unavailable") }
        let controller = ServiceController(stateDirectory: root)
        let items = try MultiModelPlanner.plan(engine: engine, models: models, base: 19400, context: 2048)
        var created: [ServiceSpec] = []
        do {
            for item in items { created.append(try controller.start(engine: engine, model: item.model, port: item.port, context: 2048)) }
            for index in 0..<120 {
                await controller.refresh()
                if created.allSatisfy({ controller.status($0) == .running }) { break }
                if let failed = created.first(where: { controller.status($0) == .failed }) { throw LaunchError.message(controller.log(failed.id)) }
                if index % 20 == 0 { print("Two-model readiness: \(created.map { controller.status($0).title })"); fflush(stdout) }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            try FeatureChecks.require(created.allSatisfy { controller.status($0) == .running }, "Two real models did not become ready")
            for spec in created {
                let response = await NetworkProbe.models(port: spec.port)
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(spec.port)/v1/chat/completions")!)
                request.httpMethod = "POST"; request.timeoutInterval = 45; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": response.models.first ?? spec.modelName, "messages": [["role": "user", "content": "Reply with OK."]], "max_tokens": 8, "temperature": 0])
                let (data, http) = try await URLSession.shared.data(for: request)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                try FeatureChecks.require((http as? HTTPURLResponse)?.statusCode == 200 && !(object?["choices"] as? [[String: Any]] ?? []).isEmpty, "Real inference failed")
            }
            try controller.stop(created[0])
            for _ in 0..<30 { if !NetworkProbe.portOccupied(created[0].port) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            let other = await NetworkProbe.models(port: created[1].port)
            try FeatureChecks.require(other.ready && !NetworkProbe.portOccupied(created[0].port), "Stopping one real model interrupted the other")
        } catch {
            for spec in created where spec.pid != nil { try? controller.stop(spec) }; try? await Task.sleep(nanoseconds: 4_500_000_000); throw error
        }
        for spec in created where controller.records.first(where: { $0.id == spec.id })?.pid != nil { try? controller.stop(spec) }
        for _ in 0..<50 { if created.allSatisfy({ !NetworkProbe.portOccupied($0.port) }) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        try FeatureChecks.require(created.allSatisfy { !NetworkProbe.portOccupied($0.port) }, "Live test services not released")
        let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "engine": engine.name, "models": models.map(\.name), "ports": items.map(\.port), "checks": ["two models running simultaneously", "real inference on both models", "stop one while the other stays ready", "test services stopped and ports released"]], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("live-multi-result.json")); print(String(decoding: data, as: UTF8.self))
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-operation-checks").appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default; try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []
        let ports = try MultiModelPlanner.availablePorts(base: 8000, count: 3, occupied: { [8000, 8002].contains($0) })
        try FeatureChecks.require(ports == [8001, 8003, 8004], "Occupied ports were reused")
        do { _ = try MultiModelPlanner.availablePorts(base: 65535, count: 2, occupied: { _ in false }); throw LaunchError.message("Port overflow accepted") }
        catch LaunchError.message(let value) where value.contains("没有足够") { }
        checks.append("Multi-model ports skip occupied listeners and respect valid ranges")

        let engines = Scanner.engines()
        let catalogRoot = root.appendingPathComponent("brew")
        try fm.createDirectory(at: catalogRoot.appendingPathComponent("Cellar/splash/1.0"), withIntermediateDirectories: true)
        let release = EngineRelease(kind: .splash, version: "1.0.3", source: "fixture", method: .brew)
        let splash = engines.first { $0.kind == .splash }!
        let upgrade = EngineCatalog.plan(engine: splash, release: release, brew: catalogRoot.appendingPathComponent("bin/brew").path, prefix: catalogRoot.path)
        try FeatureChecks.require(upgrade.commands.first?.arguments == ["upgrade", "--formula", "incoai/tap/splash"], "Existing tap formula was not upgraded")
        let missingBrew = EngineCatalog.plan(engine: splash, release: release, brew: nil)
        try FeatureChecks.require(!missingBrew.blockers.isEmpty, "Missing package manager was not blocked")
        var llama = engines.first { $0.kind == .llama }!
        let llamaRelease = EngineRelease(kind: .llama, version: "0.44.0", source: "fixture", method: .brew)
        let llamaInstall = EngineCatalog.plan(engine: llama, release: llamaRelease, brew: "/opt/homebrew/bin/brew", prefix: catalogRoot.path)
        try FeatureChecks.require(llamaInstall.commands.count == 2 && llamaInstall.commands.last?.arguments.contains("llama-app") == true && llamaInstall.commands.first?.arguments.contains("llama.cpp") == true, "Desktop and CLI update were not both planned")
        try fm.createDirectory(at: catalogRoot.appendingPathComponent("Caskroom/lm-studio/old"), withIntermediateDirectories: true)
        var studio = engines.first { $0.kind == .lmstudio }!; studio.appPath = nil; studio.installed = false
        let studioRelease = EngineRelease(kind: .lmstudio, version: "0.4.26", source: "fixture", method: .brew)
        let repair = EngineCatalog.plan(engine: studio, release: studioRelease, brew: "/opt/homebrew/bin/brew", prefix: catalogRoot.path)
        try FeatureChecks.require(repair.commands.first?.arguments == ["reinstall", "--cask", "lm-studio"], "Missing app with a retained receipt was not reinstalled")
        studio.appPath = root.path
        let caskUpgrade = EngineCatalog.plan(engine: studio, release: studioRelease, brew: "/opt/homebrew/bin/brew", prefix: catalogRoot.path)
        try FeatureChecks.require(caskUpgrade.commands.first?.arguments.contains("--greedy-auto-updates") == true, "Auto-updating cask skipped explicit update")
        let studioChoices = try StudioModelCatalog.choices("[{\"modelKey\":\"owner/model\",\"variants\":[{\"path\":\"owner/model/a.gguf\",\"sizeBytes\":1024},{\"path\":\"owner/model/b.gguf\",\"sizeBytes\":2048}]}]", models: [], engine: studio)
        try FeatureChecks.require(studioChoices.map(\.id) == ["owner/model/a.gguf", "owner/model/b.gguf"] && studioChoices.last?.bytes == 2048, "LM Studio registered variants not mapped to load keys")
        var ollama = engines.first { $0.kind == .ollama }!
        ollama.path = "/usr/bin/true"; ollama.installed = true; ollama.canServe = true
        let plan = try LaunchBuilder.plan(engine: ollama, model: nil, port: 29200, context: 16384, maximumLoadedModels: 4)
        try FeatureChecks.require(plan.environment["OLLAMA_CONTEXT_LENGTH"] == "16384" && plan.environment["OLLAMA_MAX_LOADED_MODELS"] == "4", "Ollama settings not mapped")
        checks.append("Allowlisted Homebrew formula/cask actions, existing tap updates, missing dependency blockers and Ollama settings")

        for listing in ["../escape\n", "/absolute\n", "dir/../../escape\n"] {
            do { try InstallExecutor.validateArchive(listing); throw LaunchError.message("Archive traversal accepted") }
            catch LaunchError.message(let value) where value.contains("无效路径") { }
        }
        do { try InstallExecutor.validateLinks("lrwxr-xr-x 0 user 0 file -> ../../outside"); throw LaunchError.message("Escaping archive link accepted") }
        catch LaunchError.message(let value) where value.contains("安装目录外") { }
        try InstallExecutor.validateLinks("lrwxr-xr-x 0 user 0 libggml.dylib -> libggml.0.dylib")
        let owned = root.appendingPathComponent("engines")
        let old = owned.appendingPathComponent("prism/old/server")
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("#!/bin/sh\nexit 0\n".utf8).write(to: old); chmod(old.path, 0o755)
        try InstallExecutor.publish(.init(kind: .prism, version: "old", executable: "old/server", source: "fixture", installedAt: Date()), root: owned)
        do { try InstallExecutor.publish(.init(kind: .prism, version: "new", executable: "../outside", source: "fixture", installedAt: Date()), root: owned); throw LaunchError.message("Invalid engine entry published") }
        catch LaunchError.message(let value) where value.contains("入口无效") { }
        try FeatureChecks.require(EnginePaths.manifest(.prism, root: owned)?.version == "old", "Failed update replaced the active engine")
        checks.append("Archive traversal/link checks and atomic publication preserve the prior active engine on failure")

        let source = URL(fileURLWithPath: argumentValue("--fixture-script") ?? fm.currentDirectoryPath + "/Tests/model_service_fixture.py")
        let executable = root.appendingPathComponent("fixture-server")
        let script = "#!/usr/bin/python3\n" + String(decoding: try Data(contentsOf: source), as: UTF8.self)
        try Data(script.utf8).write(to: executable); chmod(executable.path, 0o755)
        let files = ["alpha.gguf", "beta.gguf"].map { root.appendingPathComponent($0) }
        for file in files { try Data("GGUFfixture".utf8).write(to: file) }
        let models = files.map { file in LocalModel(id: file.path, name: file.lastPathComponent, format: "GGUF Q4_0", path: file.path, kind: .language, bytes: 11, complete: true, verification: "fixture", missingFiles: [], removalPath: file.path, prismRequired: false) }
        llama.path = executable.path; llama.installed = true; llama.canServe = true
        let base = try MultiModelPlanner.availablePorts(base: 29200, count: 3)
        let items = try MultiModelPlanner.plan(engine: llama, models: models, base: base[0], context: 8192)
        let controller = ServiceController(stateDirectory: root.appendingPathComponent("state"))
        var created: [ServiceSpec] = []
        do {
            for item in items { created.append(try controller.start(engine: llama, model: item.model, port: item.port, context: 8192)) }
            for _ in 0..<40 { await controller.refresh(); if created.allSatisfy({ controller.status($0) == .running }) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try FeatureChecks.require(created.count == 2 && created.allSatisfy { controller.status($0) == .running }, "Independent fixture services did not both start")
            let restored = ServiceController(stateDirectory: root.appendingPathComponent("state")); await restored.refresh()
            try FeatureChecks.require(restored.records.filter { $0.pid != nil }.count == 2, "Multiple services did not restore")
            try controller.stop(created[0])
            for _ in 0..<30 { if !NetworkProbe.portOccupied(created[0].port) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            let other = await NetworkProbe.models(port: created[1].port)
            try FeatureChecks.require(!NetworkProbe.portOccupied(created[0].port) && other.ready, "Stopping one service interrupted another")
            checks.append("Two real fixture processes, separate endpoints, persisted service recovery and stopping one without affecting the other")
            var native = ollama; native.path = executable.path
            let nativePort = try MultiModelPlanner.availablePorts(base: base.last! + 1, count: 1)[0]
            let nativeSpec = try controller.start(engine: native, model: nil, port: nativePort, context: 16384, maximumLoadedModels: 4); created.append(nativeSpec)
            for _ in 0..<40 { if await NetworkProbe.models(port: nativePort, ollama: true).ready { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try await NativeModelAPI.load(name: "alpha:latest", port: nativePort, context: 16384)
            try await NativeModelAPI.load(name: "beta:latest", port: nativePort, context: 16384)
            await controller.refresh()
            try FeatureChecks.require(controller.loadedModels[nativePort]?.count == 2 && controller.loadedModels[nativePort]?.allSatisfy { $0.context_length == 16384 } == true, "Multiple native models or contexts not reflected in actual residency")
            try await NativeModelAPI.load(name: "alpha:latest", port: nativePort, context: 16384, unload: true)
            let remaining = await NativeModelAPI.loaded(port: nativePort)
            try FeatureChecks.require(remaining?.map(\.name) == ["beta:latest"], "Unloading one model affected another")
            checks.append("Actual HTTP model load requests, native multi-model residency and scoped unloading; fixture models only")
        } catch {
            for spec in created where spec.pid != nil { try? controller.stop(spec) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            throw error
        }
        for spec in created where controller.records.first(where: { $0.id == spec.id })?.pid != nil { try? controller.stop(spec) }
        for _ in 0..<40 { if created.allSatisfy({ !NetworkProbe.portOccupied($0.port) }) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        try FeatureChecks.require(created.allSatisfy { !NetworkProbe.portOccupied($0.port) }, "Fixture listeners not released")

        var installed: [[String: String]] = []
        if CommandLine.arguments.contains("--network-installer-checks") {
            for kind in [EngineKind.prism, .mlx] {
                let release = try await EngineCatalog.release(kind)
                let engine = engines.first { $0.kind == kind }!
                let plan = EngineCatalog.plan(engine: engine, release: release)
                try FeatureChecks.require(plan.blockers.isEmpty, "Isolated install preconditions failed")
                let isolated = root.appendingPathComponent("isolated-installs")
                try await InstallExecutor.install(plan, root: isolated) { value in
                    if value.contains("正在") || value.contains("验证通过") { print(value) }
                }
                try FeatureChecks.require(EnginePaths.manifest(kind, root: isolated)?.version == release.version, "Verified install not published")
                installed.append(["engine": kind.rawValue, "version": release.version])
            }
            checks.append("Real official Prism download/SHA-256/executable verification and MLX-LM isolated environment install; system engines preserved")
        }
        let report: [String: Any] = ["result": "passed", "checks": checks, "fixtures": root.path, "isolated_installs": installed, "real_engines_upgraded": false, "real_model_files_changed": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
    }
}
