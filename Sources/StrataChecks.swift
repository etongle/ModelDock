import Foundation
import Darwin

enum StrataChecks {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-strata-checks").appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = root.appendingPathComponent("weights"), modelRoot = root.appendingPathComponent("models")
        let assembly = modelRoot.appendingPathComponent("strata/assemblies/fixture")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        try fm.createDirectory(at: assembly.appendingPathComponent("pack/tokenizer"), withIntermediateDirectories: true)
        try fm.createDirectory(at: assembly.appendingPathComponent("mtp/rt"), withIntermediateDirectories: true)
        let weight = raw.appendingPathComponent("main.gguf"), ngram = raw.appendingPathComponent("ngram.gguf"), projection = assembly.appendingPathComponent("vision.gguf")
        for file in [weight, ngram, projection, assembly.appendingPathComponent("mtp/mtp-q2_0.gguf")] { try Data("GGUFfixture".utf8).write(to: file) }
        try Data("{}".utf8).write(to: assembly.appendingPathComponent("pack/tokenizer/vocab.json"))
        try Data("fixture".utf8).write(to: assembly.appendingPathComponent("pack/native_experts.txt"))
        let config: [String: Any] = ["backend": "metal", "exe": "unused-fixture-engine", "cwd": root.path,
            "model_name": "fixture/flash-next", "tokenizer": assembly.appendingPathComponent("pack/tokenizer").path,
            "args": ["--native", weight.path, "--ple-gguf", ngram.path, "--pack", assembly.appendingPathComponent("pack").path, "--mtp", assembly.appendingPathComponent("mtp/rt").path, "--max-context", "32768", "--spec", "2", "--vision"],
            "vision": ["mmproj": projection.path, "exe": "fixture"]]
        try ConnectionFiles.json(config).write(to: assembly.appendingPathComponent("strata.json"))
        var files: [String: [String: Any]] = [:]
        for (role, url) in [("weights", weight), ("ngram", ngram), ("vision", projection), ("draft", assembly.appendingPathComponent("mtp/mtp-q2_0.gguf")), ("tokenizer/vocab.json", assembly.appendingPathComponent("pack/tokenizer/vocab.json")), ("pack/native_experts.txt", assembly.appendingPathComponent("pack/native_experts.txt"))] {
            files[role] = ["path": url.path, "bytes": StrataModelCatalog.fileSize(url.path)]
        }
        try ConnectionFiles.json(["schema": 1, "backend": "metal", "name": "fixture/flash-next", "model": "Q2_0", "config": assembly.appendingPathComponent("strata.json").path, "files": files]).write(to: assembly.appendingPathComponent("modeldock-strata.json"))
        guard let prepared = StrataModelCatalog.model(assembly) else { throw LaunchError.message("Fixture model was not recognized") }
        try ConnectionChecks.require(prepared.complete && ModalityPolicy.local(prepared).supportsMedia, "Prepared multimodal components were not recognized")
        let original = LocalModel(id: "raw", name: "Flash-Next", format: "GGUF Q2_0", path: weight.path, kind: .language, bytes: 11, complete: true, verification: "fixture", missingFiles: [], removalPath: weight.path)
        let merged = ModelIdentity.coalesce([original, prepared])
        try ConnectionChecks.require(merged.count == 1 && merged[0].strataAssemblies == [assembly.path], "Same weight became duplicate models")
        let source = URL(fileURLWithPath: argumentValue("--fixture-script") ?? fm.currentDirectoryPath + "/Tests/strata_service_fixture.py")
        let executable = root.appendingPathComponent("modeldock-strata")
        try Data(("#!/usr/bin/python3\n" + String(decoding: try Data(contentsOf: source), as: UTF8.self)).utf8).write(to: executable); chmod(executable.path, 0o755)
        var engine = Engine(kind: .strata, name: "Strata", version: "0.1.44.1+296b59d2f73c", path: executable.path, installed: true, canServe: true, installation: "isolated fixture", description: "fixture", defaultPort: 29850, symbol: "square.3.layers.3d")
        let ports = try EnginePortPolicy.available(engine: engine, base: 29850, count: 2)
        let multimodal = try LaunchBuilder.plan(engine: engine, model: merged[0], port: ports[0], context: 32768, inputMode: .multimodal)
        try ConnectionChecks.require(multimodal.arguments.contains(prepared.strataConfig!) && multimodal.arguments.contains("multimodal"), "Multimodal launch lost assembly")
        engine.launchSettings = .init(strataDraft: false, strataSpeculation: 3)
        let text = try LaunchBuilder.plan(engine: engine, model: merged[0], port: ports[1], context: 8192, inputMode: .text)
        try ConnectionChecks.require(text.arguments.contains("off") && text.arguments.contains("3"), "Engine options not applied")
        let parsed = try ServiceCommand.parse(([engine.path] + text.arguments).map(ServiceCommand.quote).joined(separator: " "), engine: engine, models: merged)
        try ConnectionChecks.require(parsed.mode == .text && parsed.context == 8192 && parsed.modelPath == assembly.path, "Command parser lost model/context/mode")
        try ConnectionChecks.require(EngineVersionPolicy.state(installed: engine.version, available: engine.version) == .current && EngineVersionPolicy.state(installed: engine.version, available: "0.1.44.1+abcdefabcdef") == .update, "Source revision update status ambiguous")
        let store = AppStore(stateDirectory: root.appendingPathComponent("state"))
        var records: [ServiceSpec] = []
        do {
            engine.launchSettings = .init(strataDraft: true, strataSpeculation: 2)
            records.append(try store.services.start(engine: engine, model: merged[0], port: ports[0], context: 32768, inputMode: .multimodal))
            engine.launchSettings = .init(strataDraft: false, strataSpeculation: 3)
            records.append(try store.services.start(engine: engine, model: merged[0], port: ports[1], context: 8192, inputMode: .text))
            for _ in 0..<40 {
                await store.services.refresh()
                if records.allSatisfy({ store.services.status($0) == .running }) { break }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            try ConnectionChecks.require(records.allSatisfy({ store.services.status($0) == .running }), "Strata service readiness failed")
            let first = store.services.records.first { $0.id == records[0].id }!
            try ConnectionChecks.require(first.modelPath == assembly.path && ModelFileSafety.used(original, removal: weight, services: store.services.records, external: [], models: merged), "Running service did not protect external shared weights")
            let details = ServiceComponentEvidence.collect(spec: first, models: merged, log: store.services.log(first.id), capabilities: .init(inputs: ["text", "image"], known: true), status: .running)
            try ConnectionChecks.require(details?.entries.contains(where: { $0.id == "draft" && $0.confirmed && $0.state == "已启用" }) == true && details?.entries.contains(where: { $0.id == "ngram" && $0.path == ngram.path }) == true, "Auxiliary component evidence missing")
            let other = Engine(kind: .llama, name: "Llama", version: "fixture", path: "", installed: false, canServe: false, installation: "fixture", description: "fixture", defaultPort: 9931, symbol: "cube")
            try ConnectionChecks.require(store.installBlockers(other).isEmpty && !store.installBlockers(engine).isEmpty, "Strata update blockers affected another engine")
            try store.services.stop(first)
            for _ in 0..<30 { await store.services.refresh(); if !NetworkProbe.portOccupied(first.port) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            let second = await NetworkProbe.models(port: ports[1], strata: true)
            try ConnectionChecks.require(!NetworkProbe.portOccupied(first.port) && second.ready, "Stopping one Strata instance stopped the other")
            await EngineServiceChecks.cleanup(store: store)
            let report: [String: Any] = ["result": "passed", "checks": ["prepared model and image capabilities", "shared weight identity coalescing", "command/config/mode/port mapping", "MTP and speculation settings", "source revision version comparison", "two real fixture processes", "health requires loaded engine", "shared auxiliary file deletion protection", "runtime component snapshots", "update blockers isolated per engine", "one instance stops independently"], "realStrataInference": false]
            try ConnectionFiles.json(report).write(to: root.appendingPathComponent("result.json")); print(root.path)
        } catch { await EngineServiceChecks.cleanup(store: store); throw error }
    }
}
