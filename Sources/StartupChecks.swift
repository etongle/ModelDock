import Foundation

enum StartupChecks {
    static func parserChecks() throws {
        let previous = "\n—— previous · 启动 ——\nReady · http://127.0.0.1:8000\n"
        let download = "\n—— current · 启动 ——\nFetching 1 file(s), 3.85 GB, from incoai/Qwen3.8-27B-DFlash2@015e795645c7; cached files are reused.\rFetching 2 files: 0%| | 0/2 [00:00<?, ?it/s]"
        let first = ServiceStartupProgress.parse(log: previous + download, status: .starting)
        try ConnectionChecks.require(first.stage == .downloading && first.percentage == 0 && first.measurement == "文件完成进度" && first.detail.contains("DFlash2"), "Draft download stage or retry reset incorrect")
        let middle = ServiceStartupProgress.parse(log: previous + download + "\rFetching 2 files: 50%| | 1/2 [00:20<00:20, 20s/it]", status: .starting)
        try ConnectionChecks.require(middle.percentage == 50 && middle.detail.contains("1 / 2"), "Real file progress not parsed")
        let loading = ServiceStartupProgress.parse(log: download + "\nLoading model...\n", status: .starting)
        try ConnectionChecks.require(loading.stage == .loading && loading.percentage == nil, "Old download percentage leaked into unmeasured loading")
        let weights = ServiceStartupProgress.parse(log: "Loading checkpoint shards: 66.7%| | 2/3 [00:03<00:02]", status: .starting)
        try ConnectionChecks.require(weights.stage == .loading && weights.percentage == 66.7, "Shard loading percentage ignored")
        let initializing = ServiceStartupProgress.parse(log: download + "\nLoading\nKernel policy for GPU family 9 with 40 cores.\n", status: .starting)
        try ConnectionChecks.require(initializing.stage == .initializing && initializing.percentage == nil, "Kernel initialization stage incorrect")
        let awaiting = ServiceStartupProgress.parse(log: download + "\nReady · http://127.0.0.1:8000\n", status: .starting)
        try ConnectionChecks.require(awaiting.stage == .checking && awaiting.percentage == nil, "Log alone fabricated verified readiness")
        let ready = ServiceStartupProgress.parse(log: download, status: .running)
        try ConnectionChecks.require(ready.stage == .ready && ready.percentage == 100, "Verified readiness did not finish progress")
        let failed = ServiceStartupProgress.parse(log: download + "\nerror: connection failed\n", status: .failed)
        try ConnectionChecks.require(failed.stage == .downloading && failed.percentage != 100, "Failure falsely completed startup")
    }
    static func cachedDraftChecks(_ root: URL) throws {
        let revision = String(repeating: "a", count: 40), blob = String(repeating: "b", count: 64), config = String(repeating: "c", count: 40)
        let repo = root.appendingPathComponent("models--fixture--Qwen-DFlash2")
        let blobs = repo.appendingPathComponent("blobs"), trees = repo.appendingPathComponent("trees")
        try ConnectionFiles.privateDirectory(blobs); try ConnectionFiles.privateDirectory(trees)
        try ConnectionFiles.json(["files": ["model.safetensors": ["size": 65536, "lfs_sha256": blob], "config.json": ["size": 4096, "blob_id": config]]]).write(to: trees.appendingPathComponent(revision + ".json"))
        try Data(repeating: 1, count: 4096).write(to: blobs.appendingPathComponent(config))
        let stale = blobs.appendingPathComponent(blob + ".old.incomplete"), current = blobs.appendingPathComponent(blob + ".current.incomplete")
        try Data(repeating: 1, count: 60000).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: stale.path)
        let start = Date(timeIntervalSinceNow: -20)
        try Data(repeating: 1, count: 32768).write(to: current)
        let log = "Fetching 1 file(s), 0.01 GB, from fixture/Qwen-DFlash2@aaaaaaaaaaaa; cached files are reused."
        let progress = ServiceStartupProgress.cachedDraft(log: log, root: root, startedAt: start)
        try ConnectionChecks.require(progress?.received == 36864 && progress?.total == 69632, "Stale retry fragments were counted, or current disk progress missing")
        try ConnectionChecks.require(ServiceStartupProgress.cachedDraft(log: log.replacingOccurrences(of: "aaaaaaaaaaaa", with: "dddddddddddd"), root: root, startedAt: start) == nil, "Wrong model revision contributed progress")
    }

    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        try parserChecks()
        try ConnectionFiles.privateDirectory(root)
        try cachedDraftChecks(root.appendingPathComponent("cache-check"))
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Tests/mlx_fixture.py")
        let text = root.appendingPathComponent("mlx_lm.server"), vision = root.appendingPathComponent("mlx_vlm.server")
        try ConnectionFiles.write(Data(contentsOf: fixture), to: text, executable: true)
        try ConnectionFiles.write(Data(contentsOf: fixture), to: vision, executable: true)
        let folder = root.appendingPathComponent("models--mlx-community--Qwen3.8-27B-4bit/snapshots/0123456789abcdef")
        try ConnectionFiles.privateDirectory(folder)
        try ConnectionFiles.json(["model_type": "qwen3_5", "vision_config": ["model_type": "qwen3_5"]]).write(to: folder.appendingPathComponent("config.json"))
        let oldFolder = root.appendingPathComponent("old-packed"); try ConnectionFiles.privateDirectory(oldFolder)
        let model = LocalModel(id: folder.path, name: ModelOrigin.displayName(folder: folder) ?? "invalid", format: "MLX 4-bit", path: folder.path, kind: .language, bytes: 16_050_000_000, complete: true, verification: "3 个分片与配置齐全", missingFiles: [], removalPath: folder.path)
        let old = LocalModel(id: oldFolder.path, name: "Qwen3.8-27B", format: "Splash 4-bit", path: oldFolder.path, kind: .language, bytes: 17_380_000_000, complete: true, verification: "文件检查通过", repository: "incoai/Qwen3.8-27B-Splash", missingFiles: [], removalPath: oldFolder.path)
        let engine = Engine(kind: .mlx, name: "MLX · LM / VLM", version: "0.32.0 · VLM 0.7.6", path: text.path, installed: true, canServe: true, installation: "MLX-LM / MLX-VLM 模型服务", description: "苹果芯片文本与多模态推理组件", defaultPort: 30320, symbol: "cpu", visionPath: vision.path, visionVersion: "0.7.6")
        let guide = Scanner.engines().filter { $0.kind != .mlx }
        store.inventory = .init(engines: [engine] + guide, models: [old, model], storageBytes: old.bytes + model.bytes, memoryBytes: 128_000_000_000, chip: "Apple Silicon", roots: [root.path], warnings: [], scannedAt: Date())
        let ports = try MultiModelPlanner.availablePorts(base: 30320, count: 2, occupied: NetworkProbe.portOccupied)
        try ConnectionChecks.require(model.name == "Qwen3.8-27B-4bit" && LocalModelVersions.related(model, models: store.models).count == 2, "Friendly snapshot name or legacy/new version grouping incorrect")
        let multi = try LaunchBuilder.plan(engine: engine, model: model, port: ports[0], context: 32768, inputMode: .multimodal)
        let automatic = try LaunchBuilder.plan(engine: engine, model: model, port: ports[0], inputMode: .automatic)
        let plain = try LaunchBuilder.plan(engine: engine, model: model, port: ports[1], inputMode: .text)
        try ConnectionChecks.require(multi.executable == vision.path && multi.engineVersion == "0.7.6" && multi.arguments.suffix(2) == ["--max-kv-size", "32768"] && automatic.executable == vision.path && plain.executable == text.path, "Startup did not select actual MLX text/vision component")
        var missing = engine; missing.visionPath = nil
        do { _ = try LaunchBuilder.plan(engine: missing, model: model, port: ports[0], inputMode: .multimodal); throw LaunchError.message("Missing vision component accepted") }
        catch LaunchError.message(let error) where error.contains("MLX-VLM") { }
        let command = try ServiceCommand.parse(ServiceCommand.quote(vision.path) + " --model " + ServiceCommand.quote(model.path) + " --port \(ports[0]) --max-kv-size 32768", engine: engine, models: [model])
        try ConnectionChecks.require(command.plan.executable == vision.path && command.mode == .multimodal && command.context == 32768, "Vision command lost executable, context or input mode")
        try ConnectionChecks.require(PortIdentity.engineID(executable: "/usr/bin/python3", arguments: ["python3", "-m", "mlx_vlm.server"]) == "mlx", "Vision process identity not recognized")
        store.launch(model: model, engine: engine); store.port = String(ports[0]); store.inputMode = .multimodal
        try ConnectionChecks.require(store.canStart && store.nativeInputReason == nil, "Multimodal start button still disabled")
        try await capture?("mlx-vlm-startup")
        store.showModelFile(model); try await capture?("model-launch-and-versions")
        do {
            let media = try store.services.start(engine: engine, model: model, port: ports[0], context: 32768, inputMode: .multimodal)
            let plain = try store.services.start(engine: engine, model: model, port: ports[1], context: 8192, inputMode: .text)
            for _ in 0..<60 { await store.services.refresh(); if store.services.status(media) == .running && store.services.status(plain) == .running { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(store.services.status(media) == .running && store.services.status(plain) == .running && store.services.identifies(engineID: "mlx", port: ports[0]), "App-managed component did not start or retain process ownership")
            try ConnectionChecks.require(store.serviceCapabilities(media).supportsMedia && !store.serviceCapabilities(plain).supportsMedia, "Anonymous models endpoint mixed text and vision instance capabilities")
            try ConnectionChecks.require(ModelFileSafety.used(model, removal: folder, services: store.services.records, external: []) && !ModelFileSafety.used(old, removal: oldFolder, services: store.services.records, external: []), "Active/new model deletion protection leaked to unused old version")
            let before = store.services.records
            store.showModelFile(old)
            try ConnectionChecks.require(store.selectedFileID == old.id && store.services.records == before, "Selecting another model switched running service unexpectedly")
            try await capture?("model-old-version-selection")
            store.showService(media); try await capture?("mlx-vlm-ready")
            // Isolated log preview exercises each phase without running a large model.
            let preview = ServiceSpec(id: "startup-preview", engineID: "splash", modelID: model.id, modelName: "mlx-community/Qwen3.8-27B-4bit", modelPath: model.path, port: 30329, startedAt: Date(), engineVersion: "1.3.1")
            store.services.records.append(preview); store.services.statuses[preview.id] = .starting
            store.showService(preview)
            for (name, log) in [
                ("startup-draft-download", "Fetching 1 file(s), 3.85 GB, from fixture/Qwen3.8-27B-DFlash2@015e795645c7; cached files are reused.\rFetching 2 files: 50%| | 1/2 [00:20<00:20, 20s/it]"),
                ("startup-loading-weights", "Loading checkpoint shards: 66.7%| | 2/3 [00:03<00:02]"),
                ("startup-initializing", "Loading\nKernel policy for GPU family 9 with 40 cores."),
                ("startup-checking-api", "Ready · http://127.0.0.1:30329")
            ] {
                try Data(("\n—— preview · 启动 ——\n" + log).utf8).write(to: store.services.logURL(preview.id)); store.services.logRevision += 1
                try await capture?(name)
            }
            store.services.records.removeAll { $0.id == preview.id }; store.services.statuses[preview.id] = nil
            await EngineServiceChecks.cleanup(store: store)
            let report: [String: Any] = ["result": "passed", "checks": ["latest launch progress only", "actual percentage and unmeasured phases", "readiness requires API verification", "MLX-LM and MLX-VLM executable selection", "multimodal startup enabled", "vision command and process identity", "anonymous API capability isolated per pinned component", "snapshot friendly name", "legacy and new models coexist", "selecting version preserves running services", "owned fixtures cleaned up"], "realServicesTouched": false]
            let data = try ConnectionFiles.json(report); try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
        } catch { await EngineServiceChecks.cleanup(store: store); throw error }
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-startup").appendingPathComponent(UUID().uuidString)
        try await exercise(store: AppStore(stateDirectory: root.appendingPathComponent("state")), root: root)
    }
}
