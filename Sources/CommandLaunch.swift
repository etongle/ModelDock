import Foundation
import SwiftUI

struct CommandLaunch {
    var engine: Engine
    var plan: LaunchPlan
    var modelID: String
    var modelName: String
    var modelPath: String
    var port: Int
    var context: Int
    var mode: InputMode
    var projector: String?
    var display: String
    var downloadsModel: Bool
}

enum ServiceCommand {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    // Parse arguments, never evaluate a shell. Quotes and escaped line breaks work.
    static func words(_ text: String) throws -> [String] {
        guard text.utf8.count <= 32_768, !text.contains("\0") else { throw LaunchError.message("命令过长或包含无效字符") }
        var result: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for char in text {
            if escaped { if char != "\n" { word.append(char); started = true }; escaped = false; continue }
            if char == "\\" && quote != "'" { escaped = true; continue }
            if let current = quote {
                if char == current { quote = nil } else {
                    guard current == "'" || (char != "$" && char != "`") else { throw LaunchError.message("请填写实际参数值，不支持变量和命令替换") }
                    word.append(char)
                }
                continue
            }
            if char == "'" || char == "\"" { quote = char; started = true; continue }
            if char.isWhitespace { if started { result.append(word); word = ""; started = false }; continue }
            guard !";|&<>`$()".contains(char) else { throw LaunchError.message("这里只接受单条引擎启动命令，不支持管道、重定向或命令替换") }
            word.append(char); started = true
        }
        guard quote == nil && !escaped else { throw LaunchError.message("引号或转义未闭合，请检查命令") }
        if started { result.append(word) }
        guard !result.isEmpty else { throw LaunchError.message("请粘贴引擎启动命令") }
        return result
    }
    static func expanded(_ value: String) -> String {
        value.hasPrefix("~/") ? Scanner.home.appendingPathComponent(String(value.dropFirst(2))).path : value
    }
    static func parse(_ text: String, engine: Engine, models: [LocalModel]) throws -> CommandLaunch {
        guard engine.launchSettings?.isEnabled != false else { throw LaunchError.message("此模型基座已停用，请在引擎配置中启用") }
        guard engine.canServe, FileManager.default.isExecutableFile(atPath: engine.path) else { throw LaunchError.message("此引擎未发现可用的命令行服务组件，请先安装") }
        var tokens = try words(text), environment: [String: String] = [:]
        let allowedEnvironment: Set<String> = ["HF_HOME", "HF_HUB_CACHE", "HF_HUB_OFFLINE", "OLLAMA_HOST", "OLLAMA_MODELS", "OLLAMA_CONTEXT_LENGTH", "OLLAMA_MAX_LOADED_MODELS"]
        while let first = tokens.first, let equal = first.firstIndex(of: "="), !first.hasPrefix("-") {
            let key = String(first[..<equal]), value = String(first[first.index(after: equal)...])
            guard allowedEnvironment.contains(key), environment[key] == nil else { throw LaunchError.message("不支持或重复的环境参数：\(key)") }
            guard engine.kind == .ollama || !key.hasPrefix("OLLAMA_") else { throw LaunchError.message("OLLAMA 参数只适用于 Ollama") }
            environment[key] = expanded(value); tokens.removeFirst()
        }
        guard let program = tokens.first else { throw LaunchError.message("命令缺少引擎程序") }; tokens.removeFirst()
        let entry = URL(fileURLWithPath: expanded(program)).resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: engine.path).resolvingSymlinksInPath().path
        let visionEntry = engine.visionPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let visionCommand = engine.kind == .mlx && engine.visionPath != nil && (entry == visionEntry || program == URL(fileURLWithPath: engine.visionPath!).lastPathComponent)
        guard visionCommand || program == URL(fileURLWithPath: engine.path).lastPathComponent || (program.contains("/") && entry == expected) else { throw LaunchError.message("请使用当前 \(engine.name) 的服务程序：\(engine.path)") }
        var args = tokens
        if engine.kind == .splash || engine.kind == .ollama || (engine.kind == .llama && URL(fileURLWithPath: engine.path).lastPathComponent == "llama") {
            guard args.first == "serve" else { throw LaunchError.message("服务启动命令必须使用 serve；模型下载请使用模型更新入口") }; args.removeFirst()
        }
        guard !args.contains(where: { ["--help", "-h", "--version", "--api-key", "--api-key-file", "--hf-token"].contains($0.components(separatedBy: "=")[0]) }) else { throw LaunchError.message("请使用服务启动参数；访问凭据请在网关或下载页面单独配置") }
        // Normalize option=value so duplicate endpoint/model options cannot be ambiguous.
        args = args.flatMap { value -> [String] in
            if value.hasPrefix("--"), let equal = value.firstIndex(of: "=") { return [String(value[..<equal]), String(value[value.index(after: equal)...])] }; return [value]
        }
        func option(_ names: [String]) throws -> String? {
            let indexes = args.indices.filter { names.contains(args[$0]) }
            guard indexes.count <= 1 else { throw LaunchError.message("重复的参数：\(names.joined(separator: " / "))") }
            guard let index = indexes.first else { return nil }
            guard index + 1 < args.count, !args[index + 1].hasPrefix("-"), !args[index + 1].isEmpty else { throw LaunchError.message("\(args[index]) 缺少参数值") }
            return args[index + 1]
        }
        var port = engine.defaultPort, context = 8192
        var reference = "", localPath = "", projector: String?, mode: InputMode = .automatic
        var downloadsModel = false
        if engine.kind == .strata {
            let allowed: Set<String> = ["--config", "--port", "--context", "--mode", "--draft", "--speculation", "--instance-dir"]
            guard args.count % 2 == 0, stride(from: 0, to: args.count, by: 2).allSatisfy({ allowed.contains(args[$0]) }) else { throw LaunchError.message("Strata 命令需要已准备的 --config，以及端口、上下文和输入模式参数。") }
            guard let value = try option(["--config"]) else { throw LaunchError.message("Strata 启动命令缺少 --config") }
            let config = URL(fileURLWithPath: expanded(value)).resolvingSymlinksInPath().path
            let prepared = models.flatMap { model -> [LocalModel] in
                model.strataConfig != nil ? [model] : (model.strataAssemblies ?? []).compactMap { StrataModelCatalog.model(URL(fileURLWithPath: $0)) }
            }
            guard let model = prepared.first(where: { $0.strataConfig.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == config }) else { throw LaunchError.message("请先在 Strata 页面准备并登记这个模型配置。") }
            if let value = try option(["--port"]) { guard let parsed = Int(value) else { throw LaunchError.message("端口需要是整数") }; port = parsed }
            if let value = try option(["--context"]) { guard let parsed = Int(value) else { throw LaunchError.message("上下文需要是整数") }; context = parsed }
            if let value = try option(["--mode"]) { guard let parsed = InputMode(rawValue: value) else { throw LaunchError.message("Strata 输入模式无效") }; mode = parsed }
            var plan = try LaunchBuilder.plan(engine: engine, model: model, port: port, context: context, inputMode: mode)
            for flag in ["--draft", "--speculation"] {
                if let value = try option([flag]) {
                    guard flag == "--draft" ? ["automatic", "on", "off"].contains(value) : ["1", "2", "3", "4"].contains(value) else { throw LaunchError.message("Strata 草稿或推测窗口参数无效") }
                    if let index = plan.arguments.firstIndex(of: flag) { plan.arguments.removeSubrange(index...index + 1) }
                    plan.arguments += [flag, value]
                }
            }
            // The manager always assigns its own service directory.
            let display = ([plan.executable] + plan.arguments).map(quote).joined(separator: " ")
            return .init(engine: engine, plan: plan, modelID: model.id, modelName: model.name, modelPath: model.path, port: port, context: context, mode: mode, projector: nil, display: display, downloadsModel: false)
        }
        if engine.kind == .ollama {
            guard args.isEmpty else { throw LaunchError.message("Ollama serve 使用命令前的 OLLAMA_HOST 等环境参数配置") }
            let host = environment["OLLAMA_HOST"] ?? "127.0.0.1:\(port)"
            let address = URLComponents(string: host.contains("://") ? host : "http://" + host)
            guard let address, ["127.0.0.1", "localhost"].contains(address.host ?? ""), address.user == nil, address.password == nil, address.path.isEmpty || address.path == "/", address.query == nil else { throw LaunchError.message("OLLAMA_HOST 需要是本机地址，例如 127.0.0.1:11435") }
            port = address.port ?? port
            if let value = environment["OLLAMA_CONTEXT_LENGTH"] { guard let number = Int(value) else { throw LaunchError.message("上下文需要是整数") }; context = number }
            environment["OLLAMA_HOST"] = "127.0.0.1:\(port)"
            environment["OLLAMA_MODELS"] = environment["OLLAMA_MODELS"] ?? Scanner.defaultRoot.appendingPathComponent("ollama").path
            reference = "Ollama 多模型服务"
        } else {
            guard engine.kind != .lmstudio else { throw LaunchError.message("LM Studio 请使用原应用启动，然后接入网关") }
            if let host = try option(["--host"]), !["127.0.0.1", "localhost"].contains(host) { throw LaunchError.message("受管理服务需要监听本机地址 127.0.0.1") }
            if try option(["--host"]) == nil { args += ["--host", "127.0.0.1"] }
            if let value = try option(["--port"]) { guard let number = Int(value) else { throw LaunchError.message("端口需要是整数") }; port = number } else { args += ["--port", String(port)] }
            let contextFlags = engine.kind == .splash ? ["--max-context"] : ["-c", "--ctx-size"]
            if engine.kind != .mlx {
                if let value = try option(contextFlags) { guard let number = Int(value) else { throw LaunchError.message("上下文需要是整数") }; context = number } else { args += [contextFlags[0], String(context)] }
            } else if visionCommand {
                if let value = try option(["--max-kv-size"]) { guard let number = Int(value) else { throw LaunchError.message("上下文需要是整数") }; context = number }
                else { args += ["--max-kv-size", String(context)] }
            }
            let modelFlags = engine.kind == .splash || engine.kind == .mlx ? ["--model"] : ["-m", "--model"]
            guard let value = try option(modelFlags) else { throw LaunchError.message("请通过 \(modelFlags.joined(separator: " / ")) 指定模型") }
            reference = expanded(value)
            let isLocal = reference.hasPrefix("/")
            if engine.kind == .splash {
                guard ModelOrigin.validRepository(reference.components(separatedBy: ":")[0]), SplashRuntime.current(engine)?.supportsPacked == false else { throw LaunchError.message("此入口需要新版 Splash 和 owner/repo[:量化版本] 模型标识") }
                if reference.hasSuffix("-Splash") { throw LaunchError.message("新版 Splash 不加载旧 packed 包，请在模型更新入口选择新版匹配模型") }
                mode = args.contains("--language-only") ? .text : .automatic; downloadsModel = true
            } else {
                guard isLocal, FileManager.default.fileExists(atPath: reference) else { throw LaunchError.message("此启动入口需要已有模型的完整路径（支持 ~/）；仓库模型请先下载导入") }
                localPath = reference
                if let index = args.firstIndex(where: { modelFlags.contains($0) }) { args[index + 1] = reference }
                if engine.kind == .llama || engine.kind == .prism {
                    environment["LLAMA_ARG_MMPROJ"] = ""; environment["LLAMA_ARG_MMPROJ_URL"] = ""; environment["LLAMA_ARG_MMPROJ_AUTO"] = "0"
                    if let value = try option(["--mmproj"]) {
                        projector = expanded(value)
                        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: projector!)) else { throw LaunchError.message("视觉投影文件不存在") }
                        defer { try? file.close() }
                        guard (try? file.read(upToCount: 4)) == Data("GGUF".utf8), !args.contains("--no-mmproj") else { throw LaunchError.message("视觉投影文件无效，或与 --no-mmproj 冲突") }
                        args[args.firstIndex(of: "--mmproj")! + 1] = projector!; mode = .multimodal
                    } else if args.contains("--no-mmproj") { mode = .text }
                } else { mode = visionCommand ? .multimodal : .text }
            }
        }
        guard (1024...65535).contains(port), (1024...262144).contains(context) else { throw LaunchError.message("端口需要为 1024–65535，上下文需要为 1024–262144") }
        var executable = visionCommand ? engine.visionPath! : engine.path, version = visionCommand ? engine.visionVersion ?? engine.version : engine.version
        if engine.kind == .splash, let runtime = SplashRuntime.current(engine) { executable = runtime.python; args = ["-u", runtime.launcher, "serve"] + args; version = runtime.version }
        else if engine.kind == .ollama || (engine.kind == .llama && URL(fileURLWithPath: engine.path).lastPathComponent == "llama") { args.insert("serve", at: 0) }
        let model = models.first { item in
            !localPath.isEmpty && URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: localPath).resolvingSymlinksInPath().path
        }
        let display = environment.filter { !$0.key.hasPrefix("LLAMA_ARG_") }.sorted { $0.key < $1.key }.map { $0.key + "=" + quote($0.value) } + [quote(visionCommand ? executable : engine.path)] + (engine.kind == .splash ? Array(args.dropFirst(2)) : args).map(quote)
        return CommandLaunch(engine: engine, plan: .init(executable: executable, arguments: args, environment: environment, engineVersion: version), modelID: engine.kind == .ollama ? "" : model?.id ?? "command:\(engine.id):\(reference)", modelName: model?.name ?? reference, modelPath: model?.path ?? localPath, port: port, context: context, mode: mode, projector: projector, display: display.joined(separator: " "), downloadsModel: downloadsModel)
    }
}

@MainActor
final class CommandDraft: ObservableObject, Identifiable {
    let id = UUID()
    let engineID: String
    @Published var text: String
    @Published var error: String?
    init(engineID: String, text: String) { self.engineID = engineID; self.text = text }
}

@MainActor
extension AppStore {
    func prepareSplashSource(_ model: LocalModel, engine: Engine) {
        guard let source = ModelOrigin.read(model), source.site == .huggingface else { message = "请先登记 Hugging Face 来源"; return }
        let free = (try? EnginePortPolicy.available(engine: engine, base: engine.defaultPort, count: 1, occupied: { self.services.portReserved($0) || NetworkProbe.portOccupied($0) }).first) ?? engine.defaultPort
        var text = ServiceCommand.quote(engine.path) + " serve --model " + ServiceCommand.quote(source.repository) + " --port \(free) --max-context 32768"
        if !source.revision.isEmpty { text += " --revision " + ServiceCommand.quote(source.revision) }
        do {
            if model.association?.draftMode == .disabled { throw LaunchError.message("新版 Splash 必须加载草稿，请开启自动或指定草稿") }
            if let path = try ModelAssociationPolicy.draftPath(model: model, engine: engine) { text += " --draft-model " + ServiceCommand.quote(path) }
            if engine.launchSettings?.ane == false { text += " --disable-ane" }
            if engine.launchSettings?.inputMode == .text { text += " --language-only" }
        } catch { message = error.localizedDescription; return }
        if let hub = ModelOrigin.hubRoot(model.path) { text = "HF_HUB_CACHE=" + ServiceCommand.quote(hub) + " " + text }
        prepareCommand(engine: engine, text: text)
    }
    func prepareCommand(engine: Engine? = nil, text: String? = nil) {
        let selected = engine ?? self.engine
        var sample = text ?? ""
        if text == nil {
            let free = (try? EnginePortPolicy.available(engine: selected, base: selected.defaultPort, count: 1, occupied: { self.services.portReserved($0) || NetworkProbe.portOccupied($0) }).first) ?? selected.defaultPort
            switch selected.kind {
            case .splash: sample = "\(ServiceCommand.quote(selected.path)) serve --model mlx-community/Qwen3.8-27B-4bit --port \(free) --max-context 32768"
            case .ollama: sample = "OLLAMA_HOST=127.0.0.1:\(free) \(ServiceCommand.quote(selected.path)) serve"
            default:
                if let model = selectedModel, let plan = try? LaunchBuilder.plan(engine: selected, model: model, port: free, context: context, inputMode: inputMode, projectorPath: projectorPath) { sample = ([ServiceCommand.quote(plan.executable)] + plan.arguments.map(ServiceCommand.quote)).joined(separator: " ") }
            }
        }
        commandDraft = CommandDraft(engineID: selected.id, text: sample)
    }
    func startCommand(_ draft: CommandDraft) {
        guard let engine = engines.first(where: { $0.id == draft.engineID }), !maintaining, !installation.running else { message = "请等待引擎操作完成"; return }
        guard !(engine.kind == .strata && strata.busy), !appUpdates.applying else { message = "请等待当前模型准备或应用更新完成"; return }
        do {
            let command = try ServiceCommand.parse(draft.text, engine: engine, models: models)
            let spec = try services.start(command: command)
            commandDraft = nil; showService(spec)
        } catch { draft.error = error.localizedDescription }
    }
}
