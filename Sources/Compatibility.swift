import Foundation

enum CompatibilityLevel: String { case direct, application, importRequired, unsupported, incomplete }
struct ModelCompatibility {
    var level: CompatibilityLevel
    var reason: String
    var title: String {
        switch level {
        case .direct: return "格式适配"
        case .application: return "应用内加载"
        case .importRequired: return "需先导入"
        case .unsupported: return "不适配"
        case .incomplete: return "文件不完整"
        }
    }
    var selectable: Bool { level == .direct || level == .application }
}

extension Engine {
    var modelRule: String {
        switch kind {
        case .strata: return "Flash-Next · Metal 主模型与配套组件"
        case .splash: return SplashRuntime.current(self)?.supportsPacked == false ? "新版上游模型 · packed 使用匹配旧组件" : "Splash 专属封装"
        case .llama: return "通用 GGUF · 不含 Prism 特殊格式"
        case .prism: return "GGUF · 支持 Bonsai 2 专属变换"
        case .ollama: return "Ollama 注册模型 · GGUF 需先导入"
        case .mlx: return "MLX 权重 · 文本 / 多模态运行组件"
        case .lmstudio: return "GGUF / MLX · 由应用运行时加载"
        }
    }
}

extension LocalModel {
    var needsPrism: Bool {
        let label = (name + " " + path).lowercased().replacingOccurrences(of: "_", with: "-")
        return prismRequired == true || format.contains("PQ2") || format.contains("PTQ1") || label.contains("bonsai-2") || label.contains("bonsai 2") || label.contains("prism-fork-required")
    }
    var exclusiveEngine: EngineKind? {
        if strataConfig != nil { return .strata }
        if format.hasPrefix("Splash") { return .splash }
        if format.hasPrefix("GGUF") && needsPrism { return .prism }
        if format == "Ollama" { return .ollama }
        return nil
    }
    var usageTitle: String {
        if kind == .draft { return "草稿加速组件 · 不能单独运行" }
        if kind == .adapter { return "附属适配器 · 不能单独运行" }
        switch exclusiveEngine {
        case .splash: return "Splash 专属"
        case .prism: return "Prism 专属"
        case .ollama: return "Ollama 注册格式"
        case .strata: return "Strata 配套组合"
        default:
            if format.hasPrefix("GGUF") { return "可共用 · GGUF" }
            if format.hasPrefix("MLX") { return "可共用 · MLX 生态" }
            return "配套应用使用"
        }
    }
    var usageExplanation: String {
        if kind == .draft { return "DFlash2 与匹配的主模型配合做推测解码，使用主模型 tokenizer；不能作为聊天服务或普通 MLX-LM 模型单独加载。" }
        if kind == .adapter { return "适配器需要匹配原始基座和加载方式，不能作为独立主模型启动。" }
        switch exclusiveEngine {
        case .splash: return splashSelection != nil ? "此目录包含 Splash 准备的目标权重、草稿模型和视觉组件。原始 MLX / GGUF 权重可以供其他匹配引擎使用。" : "Splash packed 是旧版专用封装，需要支持此格式的 Splash 组件。新版 Splash 从上游 MLX / GGUF 加载；这类 packed 文件仍不能直接交给其他引擎。"
        case .prism: return "检测到 Prism 专属量化或 Bonsai 2 特殊变换。仅使用已支持这些变换的 Prism 引擎；普通 llama.cpp 即使能读取文件也可能输出错误结果。"
        case .ollama: return "这是 Ollama 的注册清单和模型层，需要由 Ollama 管理；不能把清单当作 GGUF 权重加载。"
        case .strata: return "Strata Metal 使用匹配的 Flash-Next 主权重、n-gram、词表和模型包；MTP 加速与图片组件按准备及启动设置启用。"
        default:
            if format.hasPrefix("GGUF") { return "Llama 与 Prism 可直接加载；Ollama 需要先导入，LM Studio 需要对应运行时。格式适配还取决于引擎版本对该架构的支持。" }
            if format.hasPrefix("MLX") { return "MLX-LM 用于文本，MLX-VLM 用于多模态；LM Studio 可在应用内加载。新版 Splash 还需匹配的草稿模型。实际适配取决于模型架构和引擎版本。" }
            return "语音、编码器等权重需要其对应应用或专用加载器。"
        }
    }
    func compatibility(with engine: Engine) -> ModelCompatibility {
        if kind == .draft { return .init(level: .unsupported, reason: "草稿模型应在主模型的引擎配置中选择，不单独启动服务。") }
        if engine.kind == .strata {
            guard let prepared = preparedForStrata() else { return .init(level: .unsupported, reason: "Strata Metal 需要已准备的 Flash-Next 主权重、n-gram、词表及匹配组件；请在 Strata 页面准备模型。") }
            return .init(level: prepared.complete ? .direct : .incomplete, reason: prepared.complete ? "Strata Metal 配套组件齐全" : "Strata 配套组件缺失，请重新准备模型。")
        }
        if strataConfig != nil { return .init(level: .unsupported, reason: "这是 Strata 配套模型配置，请使用 Strata Metal；原始 GGUF 权重按其架构适配其他引擎。") }
        guard complete else { return .init(level: .incomplete, reason: "先补齐或修复模型文件。") }
        guard kind != .adapter else { return .init(level: .unsupported, reason: "附属适配器需要匹配基座，不能单独启动服务。") }
        if engine.kind == .splash, let prepared = preparedForSplash(), splashSelection == nil { return prepared.compatibility(with: engine) }
        if splashSelection != nil {
            guard engine.kind == .splash else { return .init(level: .unsupported, reason: "此目录是 Splash 组合组件，原始 MLX / GGUF 权重可供其他匹配引擎使用。") }
            guard SplashRuntime.current(engine)?.supportsPacked == false else { return .init(level: .unsupported, reason: "此模型需要新版 Splash 上游加载组件。") }
            return .init(level: .direct, reason: "新版 Splash 已准备的上游模型；启动时由引擎验证组件。")
        }
        if let exclusive = exclusiveEngine {
            guard exclusive == engine.kind else { return .init(level: .unsupported, reason: exclusive == .prism ? "此文件需要 Prism 专属实现，当前引擎不能混用。" : exclusive == .splash ? "这是 Splash 专属封装，当前引擎不能加载。" : "Ollama 注册清单不能作为原始权重加载。") }
            if exclusive == .splash && repository == nil { return .init(level: .unsupported, reason: "缺少 Splash 来源仓库信息，当前启动器无法定位这个封装。") }
            if exclusive == .splash, let reason = SplashRuntime.packedReason(engine) {
                return .init(level: SplashRuntime.packed(engine) == nil ? .unsupported : .direct, reason: reason)
            }
            return .init(level: .direct, reason: exclusive == .prism ? "需要支持该专属格式的 Prism 引擎。" : "由对应引擎直接加载。")
        }
        if format.hasPrefix("GGUF") {
            switch engine.kind {
            case .llama, .prism: return .init(level: .direct, reason: "可直接加载 GGUF；模型架构须由该版本引擎支持。")
            case .ollama: return .init(level: .importRequired, reason: "需要通过 Ollama 导入并注册，当前不会把原始 GGUF 当作已导入模型。")
            case .lmstudio: return .init(level: .application, reason: "在 LM Studio 中导入，并选择支持此架构的 llama.cpp 运行时。")
            default: return .init(level: .unsupported, reason: "这个引擎不直接读取 GGUF。")
            }
        }
        if format.hasPrefix("MLX") && kind == .language {
            if engine.kind == .splash, SplashRuntime.current(engine)?.supportsPacked == false, ModelOrigin.read(self)?.site == .huggingface { return .init(level: .importRequired, reason: "可交给新版 Splash 准备；是否支持此架构与草稿模型由引擎验证。") }
            if engine.kind == .mlx { return .init(level: .direct, reason: engine.visionPath != nil ? "文本使用 MLX-LM，多模态使用 MLX-VLM；启动时验证架构支持。" : "需要 MLX-LM 服务程序；多模态需安装 MLX-VLM。") }
            if engine.kind == .lmstudio { return .init(level: .application, reason: "在 LM Studio 中使用支持此架构的 MLX 运行时。") }
        }
        return .init(level: .unsupported, reason: "文件格式与此引擎的加载方式不匹配。")
    }
}

// Read metadata only; never load tensor data. Limits also cover malformed files.
enum GGUFMetadata {
    /// 键值读取器：visit 返回 true 表示已读取该值，否则跳过。
    struct Reader {
        let file: FileHandle
        let limit: UInt64 = 32 * 1024 * 1024
        static let sizes: [UInt64: UInt64] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, try file.offset() + UInt64(count) <= limit,
                  let data = try file.read(upToCount: count), data.count == count else { throw LaunchError.message("GGUF 元数据不完整") }
            return data
        }
        func integer(_ count: Int) throws -> UInt64 { try bytes(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
        func string() throws -> String { let count = try integer(8); guard count <= 4_000_000 else { throw LaunchError.message("GGUF 字符串过长") }; return String(decoding: try bytes(Int(count)), as: UTF8.self) }
        func skip(_ count: UInt64) throws { let offset = try file.offset(); guard count <= limit, offset + count <= limit else { throw LaunchError.message("GGUF 元数据过大") }; try file.seek(toOffset: offset + count) }
        func skipValue(_ type: UInt64, nested: Bool = false) throws {
            if let size = Self.sizes[type] { try skip(size) }
            else if type == 8 { try skip(try integer(8)) }
            else if type == 9 && !nested {
                let element = try integer(4); let count = try integer(8)
                guard count <= 1_000_000 else { throw LaunchError.message("GGUF 数组过长") }
                if let size = Self.sizes[element] { try skip(count * size) }
                else { for _ in 0..<count { try skipValue(element, nested: true) } }
            } else { throw LaunchError.message("未知 GGUF 元数据类型") }
        }
        /// 读取整数（含有符号）标量或整数数组；其他类型返回 nil 且已跳过。
        func integers(_ type: UInt64) throws -> [Int]? {
            func scalar(_ type: UInt64) throws -> Int? {
                switch type {
                case 0, 1: return Int(try integer(1))
                case 2, 3: return Int(try integer(2))
                case 4: return Int(try integer(4))
                case 5: return Int(Int32(truncatingIfNeeded: try integer(4)))
                case 10: return Int(clamping: try integer(8))
                case 11: return Int(Int64(bitPattern: try integer(8)))
                default: try skipValue(type); return nil
                }
            }
            guard type == 9 else { return try scalar(type).map { [$0] } }
            let element = try integer(4); let count = try integer(8)
            guard count <= 100_000, [0, 1, 2, 3, 4, 5, 10, 11].contains(element) else {
                guard count <= 1_000_000 else { throw LaunchError.message("GGUF 数组过长") }
                if let size = Self.sizes[element] { try skip(count * size) } else { for _ in 0..<count { try skipValue(element, nested: true) } }
                return nil
            }
            return try (0..<count).compactMap { _ in try scalar(element) }
        }
    }
    /// 依次访问每个元数据键；文件不是 GGUF 时返回 false。
    @discardableResult
    static func scan(_ url: URL, visit: (_ key: String, _ type: UInt64, _ reader: Reader) throws -> Bool) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let reader = Reader(file: file)
        guard try reader.bytes(4) == Data("GGUF".utf8), [2, 3].contains(try reader.integer(4)) else { return false }
        _ = try reader.integer(8); let count = try reader.integer(8)
        guard count <= 20_000 else { return false }
        for _ in 0..<count {
            let key = try reader.string(); let type = try reader.integer(4)
            if try !visit(key, type, reader) { try reader.skipValue(type) }
        }
        return true
    }
    static func read(_ url: URL) -> (architecture: String?, prism: Bool?, inputs: [String]?) {
        var architecture: String?; var prism: Bool = false; var inputs = ["text"]; var encoderFlags = Set<String>()
        do {
            guard try scan(url, visit: { key, type, reader in
                if key.hasPrefix("prism.hadamard.") { prism = true }
                if key == "general.architecture" && type == 8 { architecture = try reader.string(); return true }
                if ["clip.has_vision_encoder", "clip.has_audio_encoder"].contains(key), type == 7 {
                    encoderFlags.insert(key)
                    if try reader.integer(1) != 0 { inputs.append(key == "clip.has_vision_encoder" ? "image" : "audio") }
                    return true
                }
                return false
            }) else { return (nil, nil, nil) }
            return (architecture, prism, inputs.count > 1 || encoderFlags.count == 2 ? inputs : nil)
        } catch { return (architecture, prism ? true : nil, nil) }
    }
}
