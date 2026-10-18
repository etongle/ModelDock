import Foundation
import Darwin

func processStartTime(_ pid: Int32) -> UInt64 { mm_process_start_time(pid) }

enum EngineKind: String, Codable { case splash, llama, prism, ollama, mlx, lmstudio, strata, audio }
enum ModelKind: String, Codable { case language, embedding, adapter, speech, draft }

struct Engine: Identifiable, Codable, Hashable {
    var id: String { kind.rawValue }
    var kind: EngineKind
    var name: String
    var version: String
    var path: String
    var appPath: String?
    var installed: Bool
    var canServe: Bool
    var installation: String
    var description: String
    var defaultPort: Int
    var symbol: String
    var visionPath: String? = nil
    var visionVersion: String? = nil
    var launchSettings: EngineConfiguration? = nil
}

struct LocalModel: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var format: String
    var path: String
    var kind: ModelKind
    var bytes: Int64
    var complete: Bool
    var verification: String
    var repository: String?
    var missingFiles: [String]
    var companion: String?
    var removalPath: String
    var architecture: String? = nil
    var prismRequired: Bool? = nil
    var origin: ModelOrigin? = nil
    var splashSelection: String? = nil
    var splashVision: String? = nil
    var association: ModelAssociation? = nil
    var splashRegistrations: [SplashRegistration]? = nil
    var strataConfig: String? = nil
    var strataAssemblies: [String]? = nil

    var folder: String { URL(fileURLWithPath: path).hasDirectoryPath || (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path }
    func compatible(with engine: Engine) -> Bool {
        compatibility(with: engine).selectable
    }
}

struct Inventory: Codable {
    var engines: [Engine]
    var models: [LocalModel]
    var storageBytes: Int64
    var memoryBytes: UInt64
    var chip: String
    var roots: [String]
    var warnings: [String]
    var scannedAt: Date
}

func sizeLabel(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.2f GB", locale: L10n.locale, Double(bytes) / 1e9) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", locale: L10n.locale, Double(bytes) / 1e6) }
    if bytes >= 1000 { return String(format: "%.1f KB", locale: L10n.locale, Double(bytes) / 1000) }
    return "\(bytes) B"
}

func jsonFile(_ url: URL) -> [String: Any]? {
    guard let size = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8_000_000,
          let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func runText(_ executable: String, _ arguments: [String]) -> String {
    let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
    do {
        try task.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if task.isRunning { task.terminate() } }
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch { return "" }
}

enum Scanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let defaultRoot = home.appendingPathComponent("workspace_llm/models")

    static func version(_ path: String, fallback: String = "—") -> String {
        let parts = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        if let index = parts.firstIndex(of: "Cellar"), parts.count > index + 2 { return parts[index + 2] }
        return fallback
    }

    static func engines() -> [Engine] {
        let fm = FileManager.default
        func present(_ path: String) -> Bool { fm.isExecutableFile(atPath: path) }
        let llama = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server", home.appendingPathComponent(".local/bin/llama").path].first(where: present) ?? home.appendingPathComponent(".local/bin/llama").path
        let prism = EnginePaths.executable(.prism) ?? home.appendingPathComponent("workspace_llm/llama.cpp-prism/build/bin/llama-server").path
        let mlx = ([EnginePaths.executable(.mlx)].compactMap { $0 } + [home.appendingPathComponent(".local/bin/mlx_lm.server").path, "/opt/homebrew/bin/mlx_lm.server"]).first(where: present)
        let mlxVersion = (try? fm.contentsOfDirectory(atPath: "/opt/homebrew/Cellar/mlx"))?.sorted().last
        let mlxVision = EnginePaths.manifest(.mlx, record: "vision.json")
        let visionPath = mlxVision.map { EnginePaths.root.appendingPathComponent("mlx").appendingPathComponent($0.executable).path }
        let llamaInfo = NSDictionary(contentsOfFile: "/Applications/Llama.app/Contents/Info.plist")
        let lmInfo = NSDictionary(contentsOfFile: "/Applications/LM Studio.app/Contents/Info.plist")
        let hasLMComponents = fm.fileExists(atPath: home.appendingPathComponent(".lmstudio/extensions/backends").path)
        return [
            Engine(kind: .splash, name: "Splash", version: version("/opt/homebrew/bin/splash"), path: "/opt/homebrew/bin/splash", installed: present("/opt/homebrew/bin/splash"), canServe: present("/opt/homebrew/bin/splash"), installation: "命令行工具", description: "面向 Apple Silicon 的本地推理引擎", defaultPort: 8000, symbol: "water.waves"),
            Engine(kind: .llama, name: "Llama", version: version(llama, fallback: llamaInfo?["CFBundleShortVersionString"] as? String ?? "—"), path: llama, appPath: fm.fileExists(atPath: "/Applications/Llama.app") ? "/Applications/Llama.app" : nil, installed: present(llama) || llamaInfo != nil, canServe: present(llama), installation: present(llama) ? "应用 / 命令行服务" : "原生应用 · 未发现命令行", description: "使用 llama.cpp 运行本地 GGUF 模型", defaultPort: 9931, symbol: "sparkles"),
            Engine(kind: .ollama, name: "Ollama", version: version("/opt/homebrew/bin/ollama"), path: "/opt/homebrew/bin/ollama", installed: present("/opt/homebrew/bin/ollama"), canServe: present("/opt/homebrew/bin/ollama"), installation: "命令行工具", description: "本地模型运行与管理服务", defaultPort: 11434, symbol: "shippingbox"),
            Engine(kind: .mlx, name: "MLX · LM / VLM", version: (EnginePaths.manifest(.mlx)?.version ?? mlxVersion ?? "—") + (mlxVision.map { " · VLM " + $0.version } ?? ""), path: mlx ?? visionPath ?? "/opt/homebrew/Cellar/mlx", installed: mlxVersion != nil || mlx != nil || visionPath != nil, canServe: mlx != nil || visionPath != nil, installation: visionPath != nil ? "MLX-LM / MLX-VLM 模型服务" : mlx == nil ? "推理库 · 未发现服务程序" : "MLX-LM 模型服务", description: "苹果芯片文本与多模态推理组件", defaultPort: 8081, symbol: "cpu", visionPath: visionPath, visionVersion: mlxVision?.version),
            Engine(kind: .lmstudio, name: "LM Studio", version: lmInfo?["CFBundleShortVersionString"] as? String ?? "—", path: home.appendingPathComponent(".lmstudio").path, appPath: lmInfo == nil ? nil : "/Applications/LM Studio.app", installed: lmInfo != nil, canServe: false, installation: lmInfo == nil ? (hasLMComponents ? "仅残留组件" : "未安装") : "桌面应用", description: "模型管理与 MLX / llama.cpp 推理组件", defaultPort: 1234, symbol: "cube"),
            Engine(kind: .prism, name: "llama.cpp · Prism", version: EnginePaths.manifest(.prism)?.version ?? "本地编译版", path: prism, installed: present(prism), canServe: present(prism), installation: EnginePaths.manifest(.prism) == nil ? "本地编译工具" : "官方发行包 · 本工具管理", description: "支持 Bonsai 三值量化的 llama.cpp 引擎", defaultPort: 8080, symbol: "leaf"),
            Engine(kind: .strata, name: "Strata", version: EnginePaths.manifest(.strata)?.version ?? "—", path: EnginePaths.executable(.strata) ?? "", installed: EnginePaths.executable(.strata) != nil, canServe: EnginePaths.executable(.strata) != nil, installation: "Apple Silicon · Metal 源码编译", description: "Niko1221/Strata · Flash-Next 推理与兼容 API", defaultPort: 8095, symbol: "square.3.layers.3d"),
            Engine(kind: .audio, name: "MLX Audio", version: EnginePaths.manifest(.audio)?.version ?? "—", path: EnginePaths.executable(.audio) ?? "", installed: EnginePaths.executable(.audio) != nil, canServe: EnginePaths.executable(.audio) != nil, installation: "独立语音运行环境", description: "Apple Silicon 语音识别与语音合成", defaultPort: 8096, symbol: "waveform")
        ]
    }

    static func scan(extraRoots: [String] = []) -> Inventory {
        let fm = FileManager.default
        var roots = [defaultRoot.path] + extraRoots
        if !fm.fileExists(atPath: defaultRoot.path) {
            roots = [home.appendingPathComponent(".cache/huggingface/hub").path, home.appendingPathComponent(".lmstudio/models").path, home.appendingPathComponent(".ollama/models").path] + extraRoots
        }
        roots += [".cache/huggingface/hub", ".lmstudio/models", ".ollama/models", "Library/Application Support/Splash/models"].map { home.appendingPathComponent($0).path }.filter { fm.fileExists(atPath: $0) }
        roots = Array(Set(roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })).sorted()
        roots = roots.filter { root in !roots.contains { $0 != root && root.hasPrefix($0 + "/") } }
        var files: [URL] = []; var warnings: [String] = []; var identities = Set<String>(); var total: Int64 = 0
        for root in roots {
            guard fm.fileExists(atPath: root) else { warnings.append("目录不存在：\(root)"); continue }
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { url, error in warnings.append("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"); return true }) else { continue }
            while let file = enumerator.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory != true else { continue }
                files.append(file)
            }
            // Include download fragments and hidden cache files in actual disk usage.
            if let all = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) {
                while let file = all.nextObject() as? URL {
                    var statValue = stat()
                    if lstat(file.path, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFREG {
                        let key = "\(statValue.st_dev):\(statValue.st_ino)"
                        if identities.insert(key).inserted { total += Int64(statValue.st_blocks) * 512 }
                    }
                }
            }
        }
        var models: [LocalModel] = []; var modelIdentities = Set<String>()
        func add(_ model: LocalModel) { if modelIdentities.insert(model.id).inserted { models.append(model) } }
        func actualSize(_ url: URL) -> Int64 { Int64((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let normalizedFiles = Dictionary(grouping: files, by: { $0.deletingLastPathComponent().path })
        func tensorFormat(_ folder: URL, _ config: [String: Any]) -> String {
            let quant = config["quantization"] as? [String: Any] ?? config["quantization_config"] as? [String: Any] ?? [:]
            let method = quant["quant_method"] as? String
            let isMLX = (method == nil || method == "mlx") && ((quant["bits"] != nil && quant["group_size"] != nil) || folder.path.lowercased().contains("mlx-community") || folder.path.lowercased().contains("-mlx"))
            return isMLX ? (quant["bits"] as? Int).map { "MLX \($0)-bit" } ?? "MLX" : "Safetensors"
        }
        func configurationMissing(_ folder: URL) -> [String] {
            if let config = jsonFile(folder.appendingPathComponent("config.json")), let missing = AudioModelPolicy.missing(folder, config: config) { return missing }
            var missing: [String] = []
            if !fm.fileExists(atPath: folder.appendingPathComponent("config.json").path) { missing.append("config.json") }
            if !["tokenizer.json", "tokenizer.model", "vocab.json"].contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) { missing.append("tokenizer 文件") }
            return missing
        }

        for file in files where file.lastPathComponent == "manifest.json" {
            guard let manifest = jsonFile(file), let artifacts = manifest["artifacts"] as? [[String: Any]], !artifacts.isEmpty,
                  let format = manifest["format"] as? [String: Any], (format["name"] as? String)?.hasPrefix("splash-packed") == true else { continue }
            let folder = file.deletingLastPathComponent(); var missing: [String] = []; var bytes: Int64 = 0
            for artifact in artifacts {
                guard let relative = artifact["path"] as? String else { continue }
                guard DownloadPaths.safeRelative(relative) else { missing.append("清单路径无效"); continue }
                let item = folder.appendingPathComponent(relative)
                guard fm.fileExists(atPath: item.path), actualSize(item) == (artifact["size"] as? NSNumber)?.int64Value else { missing.append(relative); continue }
                bytes += actualSize(item)
            }
            let pathParts = folder.pathComponents
            let repositoryPart = pathParts.first(where: { $0.hasPrefix("models--") })
            let repository = repositoryPart.map { String($0.dropFirst(8)).replacingOccurrences(of: "--", with: "/") }
            let deletion = repositoryPart.flatMap { part -> String? in
                guard let index = pathParts.firstIndex(of: part) else { return nil }; return NSString.path(withComponents: Array(pathParts[...index]))
            } ?? folder.path
            add(LocalModel(id: "splash:\(folder.path)", name: manifest["model"] as? String ?? repository?.components(separatedBy: "/").last ?? folder.lastPathComponent, format: "Splash 4-bit", path: folder.path, kind: .language, bytes: bytes, complete: missing.isEmpty, verification: "\(artifacts.count - missing.count) / \(artifacts.count) 文件齐全", repository: repository, missingFiles: missing, removalPath: deletion))
        }

        for file in files where file.lastPathComponent == "model.safetensors.index.json" {
            guard let index = jsonFile(file), let map = index["weight_map"] as? [String: String] else { continue }
            let folder = file.deletingLastPathComponent(); let shards = Set(map.values).sorted()
            if folder.lastPathComponent == "speech_tokenizer", let parent = jsonFile(folder.deletingLastPathComponent().appendingPathComponent("config.json")), AudioModelPolicy.task(parent) == "tts" { continue }
            let missing = shards.filter { !DownloadPaths.safeRelative($0) || !fm.fileExists(atPath: folder.appendingPathComponent($0).path) } + configurationMissing(folder)
            let config = jsonFile(folder.appendingPathComponent("config.json")) ?? [:]
            var name = ModelOrigin.displayName(folder: folder) ?? folder.lastPathComponent
            if name.hasSuffix("-bit") { name = folder.deletingLastPathComponent().lastPathComponent }
            let bytes = shards.filter(DownloadPaths.safeRelative).reduce(Int64(0)) { $0 + actualSize(folder.appendingPathComponent($1)) }
            add(LocalModel(id: "mlx:\(folder.path)", name: name, format: tensorFormat(folder, config), path: folder.path, kind: AudioModelPolicy.task(config) == nil ? .language : .speech, bytes: bytes, complete: missing.isEmpty, verification: missing.isEmpty ? "\(shards.count) 个分片与配置齐全" : "缺少 \(missing.count) 项文件", missingFiles: missing, removalPath: folder.path))
        }

        for file in files where file.lastPathComponent == "model.safetensors" && !file.path.contains("/laya/") {
            let folder = file.deletingLastPathComponent()
            if folder.lastPathComponent == "speech_tokenizer", let parent = jsonFile(folder.deletingLastPathComponent().appendingPathComponent("config.json")), AudioModelPolicy.task(parent) == "tts" { continue }
            guard !fm.fileExists(atPath: folder.appendingPathComponent("model.safetensors.index.json").path) else { continue }
            let config = jsonFile(folder.appendingPathComponent("config.json")) ?? [:]
            let draft = DraftModelPolicy.isDraft(config)
            let missing = draft ? (fm.fileExists(atPath: folder.appendingPathComponent("config.json").path) ? [] : ["config.json"]) : configurationMissing(folder)
            add(LocalModel(id: "tensor:\(folder.path)", name: ModelOrigin.displayName(folder: folder) ?? folder.lastPathComponent, format: draft ? "DFlash2 草稿" : tensorFormat(folder, config), path: folder.path, kind: draft ? .draft : AudioModelPolicy.task(config) == nil ? .language : .speech, bytes: actualSize(file), complete: missing.isEmpty, verification: missing.isEmpty ? (draft ? "草稿权重与配置齐全 · 共用主模型 tokenizer" : "权重与配置齐全") : "缺少配置或 tokenizer", missingFiles: missing, removalPath: folder.path))
        }

        for file in files where file.pathExtension.lowercased() == "gguf" {
            let name = file.lastPathComponent.lowercased()
            if name.contains("qwen3.8-flash-next"), name.range(of: #"-0000[2-6]-of-0000[2-6]\.gguf$"#, options: .regularExpression) != nil { continue }
            guard !name.contains("mmproj"), !name.hasPrefix("mtp-"), !name.hasPrefix("ggml-vocab-") else { continue }
            let actual = file.resolvingSymlinksInPath()
            let folder = file.deletingLastPathComponent()
            let siblings = normalizedFiles[folder.path] ?? []
            let projectors = siblings.filter { $0.lastPathComponent.lowercased().contains("mmproj") && $0.pathExtension.lowercased() == "gguf" }
            let companion = projectors.count == 1 ? projectors.first : nil
            let associated = siblings.filter { $0.lastPathComponent.lowercased().hasPrefix("mmproj") || $0.lastPathComponent.lowercased().hasPrefix("mtp-") }
            let kind: ModelKind = name.contains("lora") || file.path.contains("/adapters/") ? .adapter : name.contains("embed") ? .embedding : .language
            let quant = ["UD-Q4_K_XL", "UD-Q5_K_XL", "UD-Q6_K_XL", "IQ3_XXS", "IQ3_S", "PQ2_0", "PTQ1_0", "Q1_0", "Q8_0", "Q6_K", "Q5_K_M", "Q4_K_M", "Q4_K_S", "Q4_0", "Q3_K_M", "Q2_0", "Q2_K", "MXFP4"].first { file.lastPathComponent.contains($0) } ?? "GGUF"
            var label = file.deletingPathExtension().lastPathComponent
            if quant != "GGUF" { label = label.replacingOccurrences(of: "-\(quant)", with: "").replacingOccurrences(of: ".\(quant)", with: "") }
            var weights = [file], missing: [String] = []
            if name.contains("qwen3.8-flash-next"), let split = ServiceStartupProgress.match(#"^(.*)-00001-of-([0-9]{5})\.gguf$"#, in: file.lastPathComponent), let count = Int(split[2]), (2...6).contains(count) {
                weights = (1...count).map { folder.appendingPathComponent(split[1] + String(format: "-%05d-of-%05d.gguf", $0, count)) }
                missing = weights.filter { !fm.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
                label = label.replacingOccurrences(of: String(format: "-00001-of-%05d", count), with: "")
            }
            var valid = false
            if let handle = try? FileHandle(forReadingFrom: file) { valid = (try? handle.read(upToCount: 4)) == Data("GGUF".utf8); try? handle.close() }
            let metadata = valid ? GGUFMetadata.read(file) : (architecture: nil as String?, prism: nil as Bool?, inputs: nil as [String]?)
            add(LocalModel(id: "gguf:\(actual.path)", name: label, format: "GGUF \(quant == "GGUF" ? "" : quant)", path: file.path, kind: kind, bytes: weights.reduce(Int64(0)) { $0 + actualSize($1) } + (kind == .language ? associated.reduce(0) { $0 + actualSize($1) } : 0), complete: valid && missing.isEmpty, verification: !missing.isEmpty ? "缺少 \(missing.count) 项文件" : valid ? "文件存在 · GGUF 头部有效" : "文件头部异常", missingFiles: missing, companion: companion?.path, removalPath: actual.path, architecture: metadata.architecture, prismRequired: metadata.prism))
        }

        for (directory, entries) in normalizedFiles {
            let onnx = entries.filter { $0.pathExtension == "onnx" }
            guard !onnx.isEmpty else { continue }
            let folder = URL(fileURLWithPath: directory)
            let bytes = onnx.reduce(Int64(0)) { $0 + actualSize($1) }
            add(LocalModel(id: "speech:\(directory)", name: folder.lastPathComponent, format: "ONNX", path: directory, kind: folder.path.contains("/jetbrains/") ? .embedding : .speech, bytes: bytes, complete: true, verification: "\(onnx.count) 个权重文件", missingFiles: [], removalPath: directory))
        }
        for file in files where file.lastPathComponent == "model.safetensors" && file.path.contains("/laya/") {
            add(LocalModel(id: "embedding:\(file.resolvingSymlinksInPath().path)", name: "Laya 多语言编码器", format: "Safetensors", path: file.path, kind: .embedding, bytes: actualSize(file), complete: true, verification: "文件存在", missingFiles: [], removalPath: file.deletingLastPathComponent().path))
        }

        // Ollama's registry manifests reference complete blobs; no network or model load.
        for file in files where file.path.contains("/manifests/") {
            guard let manifest = jsonFile(file), let layers = manifest["layers"] as? [[String: Any]] else { continue }
            guard let ollamaRoot = ModelFileCatalog.ollamaRoot(file), let modelName = ModelFileCatalog.ollamaName(file) else { continue }
            var missing: [String] = []; var bytes: Int64 = 0
            let config = (manifest["config"] as? [String: Any]).map { [$0] } ?? []
            for layer in config + layers {
                guard let digest = layer["digest"] as? String, ModelFileCatalog.validDigest(digest) else { missing.append("无效模型层标识"); continue }
                let blob = ollamaRoot.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
                if !fm.fileExists(atPath: blob.path) || (layer["size"] as? NSNumber).map({ $0.int64Value != actualSize(blob) }) == true { missing.append(digest) }; bytes += actualSize(blob)
            }
            add(LocalModel(id: "ollama:\(file.path)", name: modelName, format: "Ollama", path: file.path, kind: .language, bytes: bytes, complete: missing.isEmpty, verification: missing.isEmpty ? "模型层文件齐全" : "缺少模型层", repository: modelName, missingFiles: missing, removalPath: file.path))
        }
        for model in SplashAssemblyCatalog.scan() { add(model) }
        for model in StrataModelCatalog.scan(roots: roots) { add(model) }
        for index in models.indices {
            if let origin = ModelOrigin.read(models[index]) {
                models[index].origin = origin
                if models[index].repository == nil { models[index].repository = origin.repository }
            }
        }
        models = ModelIdentity.coalesce(models)
        models.sort { left, right in
            if left.kind != right.kind { return left.kind == .language || (left.kind.rawValue < right.kind.rawValue && right.kind != .language) }
            if left.format.hasPrefix("Splash") != right.format.hasPrefix("Splash") { return left.format.hasPrefix("Splash") }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        var memory: UInt64 = 0; var length = MemoryLayout<UInt64>.size; sysctlbyname("hw.memsize", &memory, &length, nil, 0)
        let chip = runText("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        return Inventory(engines: engines(), models: models, storageBytes: total, memoryBytes: memory, chip: chip.isEmpty ? "Apple Silicon" : chip, roots: roots, warnings: warnings, scannedAt: Date())
    }
}

struct ServiceSpec: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var engineID: String
    var modelID: String
    var modelName: String
    var modelPath: String
    var port: Int
    var context: Int = 8192
    var pid: Int32?
    var processStart: UInt64?
    var startedAt: Date?
    var maximumLoadedModels: Int?
    var engineVersion: String? = nil
    var engineExecutable: String? = nil
    var inputMode: InputMode? = nil
    var projectorPath: String? = nil
    var commandText: String? = nil
    var draftModelPath: String? = nil
    var launchArguments: [String]? = nil
    var componentSnapshot: ServiceComponentSnapshot? = nil
    // User-supplied native engine flags, appended after the managed arguments.
    var extraArguments: [String]? = nil
    /// ModelDock 启动后自动启动此服务。
    var autoStart: Bool? = nil
    /// 空闲多少分钟后自动停止；nil 表示不自动停止。
    var idleMinutes: Int? = nil
    /// 因空闲被自动停止；经网关的请求可唤醒。手动停止或启动时清除。
    var sleeping: Bool? = nil
}

struct LaunchPlan: Codable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var engineVersion: String? = nil
}

enum LaunchError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum LaunchBuilder {
    static func plan(engine: Engine, model: LocalModel?, port: Int, context: Int = 8192, maximumLoadedModels: Int = 3, inputMode: InputMode = .automatic, projectorPath: String? = nil) throws -> LaunchPlan {
        let model = engine.kind == .splash ? (model?.preparedForSplash(inputMode) ?? model) : engine.kind == .strata ? (model?.preparedForStrata(inputMode) ?? model) : model
        guard (1024...65535).contains(port) else { throw LaunchError.message("端口需要在 1024–65535 之间") }
        guard (1024...262144).contains(context), (1...16).contains(maximumLoadedModels) else { throw LaunchError.message("上下文或常驻模型数量无效") }
        guard engine.canServe else { throw LaunchError.message("当前引擎没有可启动的服务程序") }
        guard engine.launchSettings?.isEnabled != false else { throw LaunchError.message("此模型基座已停用，请在引擎配置中启用") }
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { throw LaunchError.message("引擎程序已移动或不存在，请重新扫描") }
        if let model, !model.compatible(with: engine) { throw LaunchError.message("这个模型与所选引擎不兼容，请查看模型的适配标记") }
        if engine.kind != .ollama {
            guard let model, model.compatible(with: engine) else { throw LaunchError.message("请先选择文件齐全且兼容的模型") }
            guard FileManager.default.fileExists(atPath: model.path) else { throw LaunchError.message("模型文件已移动，请重新扫描") }
        }
        if inputMode == .multimodal, let reason = ModalityPolicy.nativeMultimodalReason(engine: engine, model: model, projector: projectorPath) { throw LaunchError.message(reason) }
        var args: [String] = []; var env: [String: String] = [:]
        var executable = engine.path; var version = engine.version
        switch engine.kind {
        case .audio:
            guard let model, let task = AudioModelPolicy.task(model) else { throw LaunchError.message("请选择支持的 Qwen3-ASR 或 Qwen3-TTS 模型") }
            args = ["--model", model.path, "--task", task, "--port", String(port)]
            let python = URL(fileURLWithPath: engine.path).deletingLastPathComponent().appendingPathComponent("python3")
            if FileManager.default.isExecutableFile(atPath: python.path), let helper = AudioModelPolicy.helper, FileManager.default.fileExists(atPath: helper) {
                executable = python.path; args = ["-u", helper] + args
            }
            env = ["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_PROGRESS_BARS": "0", "PYTHONDONTWRITEBYTECODE": "1"]
        case .splash:
            if let selection = model?.splashSelection, let runtime = SplashRuntime.current(engine), !runtime.supportsPacked {
                guard let record = jsonFile(URL(fileURLWithPath: model!.path).appendingPathComponent("model.json")),
                      let name = record["model"] as? String, let source = model?.origin,
                      URL(fileURLWithPath: selection).resolvingSymlinksInPath().path == URL(fileURLWithPath: model!.path).resolvingSymlinksInPath().path else { throw LaunchError.message("Splash 新版模型登记已变化，请重新扫描") }
                executable = runtime.python; version = runtime.version
                args = ["-u", runtime.launcher, "serve", "--model", name, "--host", "127.0.0.1", "--port", String(port), "--max-context", String(context)]
                if !source.revision.isEmpty { args += ["--revision", source.revision] }
                if inputMode == .text || model?.splashVision == "none" { args += ["--language-only"] }
                if let files = record["files"] as? [String: [String: Any]] {
                    let targetFiles = files.keys.filter { $0.hasPrefix("target/") }.sorted().compactMap { files[$0]?["path"] as? String }
                    if let path = targetFiles.first(where: { ModelOrigin.hubRoot($0) != nil }), let cache = ModelOrigin.hubRoot(path) { env["HF_HUB_CACHE"] = cache }
                    if let draftConfig = files["draft/config.json"]?["path"] as? String { args += ["--draft-model", URL(fileURLWithPath: draftConfig).deletingLastPathComponent().path] }
                }
                env["HF_HUB_OFFLINE"] = "1"
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                break
            }
            if SplashRuntime.current(engine) != nil {
                guard model?.format.hasPrefix("Splash") == true else { throw LaunchError.message("当前启动器需要 Splash 已准备且匹配的模型，请查看适配标记") }
                guard let runtime = SplashRuntime.packed(engine) else { throw LaunchError.message(SplashRuntime.packedReason(engine) ?? "没有可运行此模型的 Splash 组件") }
                // Cellar bin/splash wrappers use opt/splash and follow upgrades.
                // Pin interpreter AND launcher so the native engine is pinned too.
                executable = runtime.python; args = ["-u", runtime.launcher]; version = runtime.version
            }
            guard let repo = model?.repository else { throw LaunchError.message("Splash 模型缺少来源仓库信息") }
            let registration = Scanner.home.appendingPathComponent("Library/Application Support/Splash/models").appendingPathComponent(repo)
            if FileManager.default.fileExists(atPath: registration.path), registration.resolvingSymlinksInPath().path != URL(fileURLWithPath: model!.path).resolvingSymlinksInPath().path { throw LaunchError.message("Splash 已登记此仓库的另一个快照。请先在原引擎中切换版本，避免启动错误的权重。") }
            args += ["serve", "--model", repo, "--host", "127.0.0.1", "--port", String(port), "--max-context", String(context)]
            let hub = URL(fileURLWithPath: model!.path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            env = ["HF_HUB_CACHE": hub.path, "HF_HOME": hub.deletingLastPathComponent().path, "HF_HUB_OFFLINE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        case .llama, .prism:
            if engine.kind == .llama && URL(fileURLWithPath: engine.path).lastPathComponent == "llama" { args.append("serve") }
            args += ["-m", model!.path, "--host", "127.0.0.1", "--port", String(port), "-c", String(context), "-ngl", engine.launchSettings?.gpu == false ? "0" : "99"]
            if engine.launchSettings?.gpu == false { args += ["--no-mmproj-offload"] }
            env["LLAMA_ARG_MMPROJ"] = ""; env["LLAMA_ARG_MMPROJ_URL"] = ""; env["LLAMA_ARG_MMPROJ_AUTO"] = "0"
            if inputMode != .text, let companion = ModalityPolicy.projector(model: model, override: projectorPath) { args += ["--mmproj", companion] }
            if inputMode == .text { args += ["--no-mmproj"]; env["LLAMA_ARG_MMPROJ"] = ""; env["LLAMA_ARG_MMPROJ_URL"] = ""; env["LLAMA_ARG_MMPROJ_AUTO"] = "0" }
            if model?.kind == .embedding { args += ["--embedding"] }
        case .ollama:
            args = ["serve"]; env = ["OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_MODELS": Scanner.defaultRoot.appendingPathComponent("ollama").path, "OLLAMA_CONTEXT_LENGTH": String(context), "OLLAMA_MAX_LOADED_MODELS": String(maximumLoadedModels)]
        case .mlx:
            if inputMode == .multimodal || (inputMode == .automatic && model.map({ ModalityPolicy.local($0).supportsMedia }) == true && engine.visionPath != nil) {
                guard let vision = engine.visionPath, FileManager.default.isExecutableFile(atPath: vision) else { throw LaunchError.message("尚未安装 MLX-VLM，请更新此基座的多模态组件后重试。") }
                executable = vision; version = engine.visionVersion ?? engine.version
            }
            args = ["--model", model!.path, "--host", "127.0.0.1", "--port", String(port)]
            if executable == engine.visionPath { args += ["--max-kv-size", String(context)] }
            env = ["HF_HUB_OFFLINE": "1"]
        case .lmstudio: throw LaunchError.message("请在 LM Studio 应用中启动服务")
        case .strata:
            guard let config = model?.strataConfig else { throw LaunchError.message("请先准备 Strata 主模型及配套组件") }
            try StrataModelCatalog.validate(config: config)
            args = ["--config", config, "--port", String(port), "--context", String(context), "--mode", inputMode.rawValue,
                    "--instance-dir", EnginePaths.root.deletingLastPathComponent().appendingPathComponent("strata-services").path]
            if engine.launchSettings?.strataDraft == false || model?.association?.draftMode == .disabled { args += ["--draft", "off"] }
            if let speculation = engine.launchSettings?.strataSpeculation { args += ["--speculation", String(speculation)] }
            env["PYTHONDONTWRITEBYTECODE"] = "1"
        }
        if engine.kind == .splash, model?.splashSelection != nil {
            if engine.launchSettings?.ane == false { args += ["--disable-ane"] }
            if model?.association?.draftMode == .disabled { throw LaunchError.message("新版 Splash 必须加载草稿；请在配套组件中选择自动或匹配草稿") }
            if let path = try ModelAssociationPolicy.draftPath(model: model, engine: engine) {
                if let index = args.firstIndex(of: "--draft-model"), index + 1 < args.count { args.removeSubrange(index...index + 1) }
                args += ["--draft-model", path]
            }
        }
        if engine.kind == .mlx {
            if let path = try ModelAssociationPolicy.draftPath(model: model, engine: engine) {
                guard executable == engine.visionPath else { throw LaunchError.message("DFlash2 需要 MLX-VLM；请选择多模态模式。MLX-LM 不支持此草稿格式。") }
                args += ["--draft-model", path, "--draft-kind", "dflash"]
            }
            // Keep inherited server environment from selecting an unrelated drafter.
            env["MLX_VLM_DRAFT_MODEL"] = ""; env["MLX_VLM_DRAFT_KIND"] = ""
        }
        return LaunchPlan(executable: executable, arguments: args, environment: env, engineVersion: version)
    }
}
