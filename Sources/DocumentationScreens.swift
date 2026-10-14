import AppKit
import Foundation

@MainActor
enum DocumentationScreens {
    static func run(_ app: AppDelegate) async throws {
        guard argumentValue("--state-dir") != nil, app.store.services.records.isEmpty, let path = argumentValue("--capture-dir") else { throw LaunchError.message("Documentation capture requires fresh isolated state") }
        let folder = URL(fileURLWithPath: path), demo = URL(fileURLWithPath: "/private/tmp/ModelDock-Demo")
        try ConnectionFiles.privateDirectory(folder)
        let store = app.store!
        // No backend, model download, native client configuration or user inventory is used.
        let mainPath = demo.appendingPathComponent("Models/Qwen3.8-27B-4bit")
        try FileManager.default.createDirectory(at: mainPath, withIntermediateDirectories: true)
        try ConnectionFiles.json(["model_type": "qwen3_5", "vision_config": ["model_type": "qwen3_5"], "quantization": ["bits": 4]]).write(to: mainPath.appendingPathComponent("config.json"))
        let model = LocalModel(id: "demo-main", name: "Qwen3.8-27B-4bit", format: "MLX 4-bit", path: mainPath.path, kind: .language, bytes: 16_080_000_000, complete: true, verification: "3 个分片与配置齐全", repository: "mlx-community/Qwen3.8-27B-4bit", missingFiles: [], removalPath: mainPath.path, origin: .init(site: .huggingface, repository: "mlx-community/Qwen3.8-27B-4bit", revision: String(repeating: "a", count: 40), files: []))
        let engines: [Engine] = [
            .init(kind: .splash, name: "Splash", version: "1.3.1", path: "/opt/modeldock/splash", installed: true, canServe: true, installation: "命令行工具", description: "面向 Apple Silicon 的本地推理引擎", defaultPort: 8000, symbol: "water.waves"),
            .init(kind: .llama, name: "Llama", version: "0.6.0_1", path: "/opt/modeldock/llama-server", installed: true, canServe: true, installation: "命令行服务", description: "使用 llama.cpp 运行本地 GGUF 模型", defaultPort: 8080, symbol: "bolt.fill"),
            .init(kind: .mlx, name: "MLX · LM / VLM", version: "0.32.0", path: "/opt/modeldock/mlx_lm.server", installed: true, canServe: true, installation: "MLX-LM / MLX-VLM 模型服务", description: "文本与多模态模型服务", defaultPort: 8083, symbol: "cpu", visionPath: "/opt/modeldock/mlx_vlm.server", visionVersion: "0.7.6"),
            .init(kind: .ollama, name: "Ollama", version: "—", path: "/opt/modeldock/ollama", installed: false, canServe: false, installation: "未安装", description: "本地模型运行与管理服务", defaultPort: 11434, symbol: "shippingbox"),
            .init(kind: .lmstudio, name: "LM Studio", version: "—", path: "/Applications/LM Studio.app", installed: false, canServe: false, installation: "未安装", description: "GGUF 与 MLX 桌面应用", defaultPort: 1234, symbol: "cube")]
        store.inventory = .init(engines: engines, models: [model], storageBytes: model.bytes, memoryBytes: 137_438_953_472, chip: "Apple Silicon", roots: [demo.appendingPathComponent("Models").path], warnings: [], scannedAt: Date())
        store.engineID = "mlx"; store.selectedModels["mlx"] = model.id; store.selectedFileID = model.id; store.context = 32768
        let spec = ServiceSpec(id: "demo-service", engineID: "mlx", modelID: model.id, modelName: "mlx-community/Qwen3.8-27B-4bit", modelPath: model.path, port: 8083, context: 32768, engineVersion: "0.32.0 · VLM 0.7.6", engineExecutable: "/opt/modeldock/mlx_vlm.server", inputMode: .multimodal)
        store.services.records = [spec]; store.services.statuses[spec.id] = .stopped; store.selectedServiceID = spec.id
        let files: [RemoteFile] = [
            .init(path: "config.json", url: URL(string: "https://example.invalid/config.json")!, bytes: 4900),
            .init(path: "tokenizer.json", url: URL(string: "https://example.invalid/tokenizer.json")!, bytes: 9_000_000),
            .init(path: "model-00001-of-00003.safetensors", url: URL(string: "https://example.invalid/model-1")!, bytes: 5_340_000_000),
            .init(path: "model-00002-of-00003.safetensors", url: URL(string: "https://example.invalid/model-2")!, bytes: 5_350_000_000),
            .init(path: "model-00003-of-00003.safetensors", url: URL(string: "https://example.invalid/model-3")!, bytes: 5_360_000_000)]
        var job = ModelDownload(id: "demo-download", site: .huggingface, repository: model.repository!, revision: "main", root: demo.appendingPathComponent("Models").path, folder: "Qwen3.8-27B-4bit", files: files, state: .downloading)
        job.finished = Set(files.prefix(3).map(\.path)); job.received = 8_200_000_000; job.currentFile = files[3].path
        job.fileReceived = [files[0].path: 4900, files[1].path: 9_000_000, files[2].path: 5_340_000_000, files[3].path: 2_850_995_100]; job.pausedFiles = Set([files[4].path])
        store.downloads.jobs = [job]; store.downloads.activeID = job.id; store.downloads.speeds[job.id] = 2_600_000; store.downloads.transferPhases[job.id] = .downloading
        store.downloads.listing = .init(site: .huggingface, repository: job.repository, revision: "main", files: files); store.downloads.selected = Set(files.map(\.path)); store.downloads.address = job.repository; store.downloads.destination = job.root
        store.resources.system = .init(cpu: 18.6, memoryUsed: 42_000_000_000, memoryTotal: 137_438_953_472, compressed: 2_000_000_000, fileCache: 4_000_000_000, diskTotal: 4_000_000_000_000, diskAvailable: 2_900_000_000_000, diskPath: demo.path, modelBytes: model.bytes, sampledAt: Date())
        for language in [AppLanguage.english, .chinese, .french, .portuguese] {
            store.language = language
            for tab in [AppTab.engines, .models, .services, .downloads, .monitor] {
                store.tab = tab; store.downloads.selectedTaskID = nil
                try await Task.sleep(nanoseconds: 450_000_000)
                try app.capture(language.rawValue + "-" + [AppTab.engines: "engines", .models: "models", .services: "services", .downloads: "downloads", .monitor: "resources"][tab]!, folder: folder)
            }
            store.tab = .downloads; store.downloads.selectedTaskID = job.id
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-download-files", folder: folder)
            app.showSettings(); try await Task.sleep(nanoseconds: 300_000_000)
            if let content = app.settingsWindow?.contentView { try app.captureView(content, name: language.rawValue + "-settings", folder: folder) }
            app.settingsWindow?.orderOut(nil)
        }
        store.language = .english
        try ConnectionFiles.json(["result": "passed", "demoData": true, "languages": ["en", "zh-Hans", "fr", "pt"], "realModelProcessesStarted": false, "realConfigurationUsed": false]).write(to: folder.appendingPathComponent("result.json"))
        store.downloads.activeID = nil
        if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }
    }
}
