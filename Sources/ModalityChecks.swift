import Foundation
import Darwin

enum ModalityChecks {
    static func gguf(_ entries: [String: Bool]) -> Data {
        var data = Data("GGUF".utf8)
        func number(_ value: UInt64, _ width: Int) { for index in 0..<width { data.append(UInt8((value >> (8 * index)) & 255)) } }
        number(3, 4); number(0, 8); number(UInt64(entries.count), 8)
        for key in entries.keys.sorted() { number(UInt64(key.utf8.count), 8); data.append(Data(key.utf8)); number(7, 4); number(entries[key] == true ? 1 : 0, 1) }
        return data
    }
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        try ConnectionFiles.privateDirectory(root)
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Tests/modality_fixture.py")
        let script = root.appendingPathComponent("llama-server"), splashScript = root.appendingPathComponent("splash")
        try ConnectionFiles.write(Data(contentsOf: fixture), to: script, executable: true)
        try ConnectionFiles.write(Data(contentsOf: fixture), to: splashScript, executable: true)
        let weight = root.appendingPathComponent("fixture.gguf"); try Data("GGUF".utf8).write(to: weight)
        let image = root.appendingPathComponent("mmproj-image.gguf"), audio = root.appendingPathComponent("mmproj-audio.gguf"), neither = root.appendingPathComponent("mmproj-neither.gguf"), partial = root.appendingPathComponent("mmproj-partial.gguf")
        try gguf(["clip.has_vision_encoder": true, "clip.has_audio_encoder": false]).write(to: image)
        try gguf(["clip.has_vision_encoder": false, "clip.has_audio_encoder": true]).write(to: audio)
        try gguf(["clip.has_vision_encoder": false, "clip.has_audio_encoder": false]).write(to: neither)
        try gguf(["clip.has_audio_encoder": false]).write(to: partial)
        var model = LocalModel(id: "image-fixture", name: "视觉测试模型", format: "GGUF", path: weight.path, kind: .language, bytes: 4, complete: true, verification: "测试文件", missingFiles: [], companion: image.path, removalPath: weight.path)
        let packed = LocalModel(id: "packed-fixture", name: "Splash 文本测试模型", format: "Splash 4-bit", path: root.path, kind: .language, bytes: 4, complete: true, verification: "测试文件", repository: "fixture/text-only", missingFiles: [], removalPath: root.path)
        let engine = Engine(kind: .llama, name: "Llama", version: "测试", path: script.path, installed: true, canServe: true, installation: "测试", description: "模型能力与启动配置验证", defaultPort: 30300, symbol: "terminal")
        let splash = Engine(kind: .splash, name: "Splash", version: "旧 packed 测试组件", path: splashScript.path, installed: true, canServe: true, installation: "测试", description: "旧 packed 模型仅支持文本", defaultPort: 30300, symbol: "water.waves")
        let ports = try MultiModelPlanner.availablePorts(base: 30300, count: 4, occupied: NetworkProbe.portOccupied)
        let guide = Scanner.engines().filter { $0.kind != .llama && $0.kind != .splash }
        store.inventory = .init(engines: [splash, engine] + guide, models: [packed, model], storageBytes: 8, memoryBytes: 0, chip: "测试环境", roots: [root.path], warnings: [], scannedAt: Date())
        try ConnectionChecks.require(ModalityPolicy.local(packed).badgeTitle == L10n.text("仅文本"), "Packed model was not clearly marked text-only")
        try ConnectionChecks.require(ModalityPolicy.local(model).inputs == ["text", "image"], "Image projector metadata lost")
        model.companion = audio.path
        try ConnectionChecks.require(ModalityPolicy.local(model).inputs == ["text", "audio"], "Audio projector was incorrectly marked as image")
        model.companion = image.path
        try ConnectionChecks.require(GGUFMetadata.read(partial).inputs == nil, "Incomplete negative flags claimed text-only")
        try ConnectionChecks.require(ModelCapabilities.declared(["capabilities": ["vision": true]]).inputs.contains("image"), "LM Studio capabilities dictionary ignored")
        try ConnectionChecks.require(ModelCapabilities.declared(["capabilities": ["vision": false]]).badgeTitle == L10n.text("仅文本"), "LM Studio text-only declaration ignored")
        var unknown = model; unknown.companion = nil; unknown.name = "Qwen-VL-视觉-模型"
        try ConnectionChecks.require(!ModalityPolicy.local(unknown).known && !ModalityPolicy.local(unknown).supportsMedia, "Model name fabricated vision capability")
        do { _ = try LaunchBuilder.plan(engine: engine, model: model, port: ports[0], inputMode: .multimodal, projectorPath: neither.path); throw LaunchError.message("Projector without encoders accepted") }
        catch LaunchError.message(let text) where text.contains("编码器") { }
        let textPlan = try LaunchBuilder.plan(engine: engine, model: model, port: ports[0], inputMode: .text)
        let mediaPlan = try LaunchBuilder.plan(engine: engine, model: model, port: ports[0], inputMode: .multimodal)
        try ConnectionChecks.require(textPlan.arguments.contains("--no-mmproj") && !textPlan.arguments.contains("--mmproj") && textPlan.environment["LLAMA_ARG_MMPROJ_URL"] == "", "Text launch did not disable projector or inherited URL")
        try ConnectionChecks.require(mediaPlan.arguments.contains(image.path), "Media launch did not pass image projector")
        _ = try MultiModelPlanner.plan(engine: engine, models: [unknown], base: ports[2], context: 8192, inputMode: .multimodal, projectorPaths: [unknown.id: image.path], occupied: { _ in false })
        do { _ = try LaunchBuilder.plan(engine: splash, model: packed, port: ports[0], inputMode: .multimodal); throw LaunchError.message("Packed vision was accepted") }
        catch LaunchError.message(let text) where text.contains("仅支持文本") { }
        var studioProcess: Process?; var studioBirth: UInt64 = 0
        do {
            store.engineID = splash.id; store.selectedModels[splash.id] = packed.id; store.port = String(ports[0]); store.inputMode = .automatic; store.tab = .engines
            try ConnectionChecks.require(store.nativeInputReason != nil && store.canStart, "Text-only input controls prevented ordinary startup")
            try await capture?("splash-text-startup")
            store.engineID = engine.id; store.selectedModels[engine.id] = model.id; store.port = String(ports[0]); store.inputMode = .multimodal
            try ConnectionChecks.require(store.nativeInputReason == nil && store.canStart, "Image startup was not available")
            try await capture?("llama-image-startup")
            store.inputMode = .text; try await capture?("llama-text-startup")
            try ConnectionChecks.require(store.modelCapabilities(model).supportsMedia && !ModalityPolicy.planned(engine: engine, model: model, projector: nil, mode: .text).supportsMedia, "Text mode removed intrinsic model capability")
            let media = try store.services.start(engine: engine, model: model, port: ports[0], context: 8192, inputMode: .multimodal)
            let text = try store.services.start(engine: engine, model: model, port: ports[1], context: 8192, inputMode: .text)
            for _ in 0..<60 { await store.services.refresh(); if store.services.status(media) == .running && store.services.status(text) == .running { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(store.services.status(media) == .running && store.services.status(text) == .running, "Input fixtures did not become ready")
            try ConnectionChecks.require(store.serviceCapabilities(media).supportsMedia && store.serviceCapabilities(text).badgeTitle == L10n.text("仅文本"), "Separate instances were mislabeled")
            let restored = ServiceController(stateDirectory: store.services.stateDirectory)
            try ConnectionChecks.require(restored.records.first { $0.id == media.id }?.inputMode == .multimodal && restored.records.first { $0.id == text.id }?.inputMode == .text, "Input settings did not persist")
            store.port = String(ports[0]); store.inputMode = .multimodal; try await capture?("llama-active-inputs")
            store.multiModel = MultiModelDraft(engine: engine, mode: .independent, choices: [.init(id: model.id, name: model.name, bytes: model.bytes, model: model)], selected: [model.id], port: ports[2], context: 8192)
            store.multiModel?.inputMode = .multimodal; try await capture?("multimodal-batch-preview"); store.multiModel = nil
            store.tab = .models; store.selectedFileID = packed.id; try await capture?("splash-model-capability")
            store.selectedFileID = model.id; try await capture?("llama-model-capability")
            let studio = Process(); studio.executableURL = Bundle.main.executableURL; studio.arguments = ["--child-exec", "/usr/bin/python3", script.path, "--port", String(ports[3]), "--studio"]; studio.standardOutput = FileHandle.nullDevice; studio.standardError = FileHandle.nullDevice
            try studio.run(); studioProcess = studio; studioBirth = processStartTime(studio.processIdentifier)
            for _ in 0..<40 { if NetworkProbe.portOccupied(ports[3]) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            let ambiguous = await NetworkProbe.models(port: ports[3])
            try ConnectionChecks.require(ambiguous.capabilities.values.allSatisfy { !$0.known }, "One shared props endpoint assigned vision to all models")
            let native = await NetworkProbe.models(port: ports[3], studio: true)
            try ConnectionChecks.require(native.capabilities["text-model"]?.badgeTitle == L10n.text("仅文本") && native.capabilities["vision-alias"]?.supportsMedia == true && native.capabilities["vision-alias"]?.context == 16384, "LM Studio model-specific native capabilities or context lost")
            await EngineServiceChecks.cleanup(store: store)
            if processStartTime(studio.processIdentifier) == studioBirth { _ = kill(-studio.processIdentifier, SIGTERM) }
            let report: [String: Any] = ["result": "passed", "checks": ["Packed text-only labels and unsupported image option", "Image/audio/no-encoder/unknown projector metadata", "Names never fabricate model capabilities", "Native text command explicitly disables projector and inherited URL", "Native image command loads selected projector", "Batch preserves custom per-model projector", "Separate text/image instances expose independent input modes", "Intrinsic model capability survives text instance", "Settings persist after reopening", "LM Studio native metadata maps each loaded model without shared-props leakage", "Owned fixtures cleaned up"], "realModelsLoaded": false, "realServicesStopped": false]
            let data = try ConnectionFiles.json(report); try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
        } catch {
            store.multiModel = nil; await EngineServiceChecks.cleanup(store: store)
            if let studioProcess, processStartTime(studioProcess.processIdentifier) == studioBirth { _ = kill(-studioProcess.processIdentifier, SIGTERM) }
            throw error
        }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-modalities").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try await exercise(store: AppStore(stateDirectory: root.appendingPathComponent("state")), root: root)
    }
}
