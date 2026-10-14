import Foundation
import AppKit
import Combine
import CryptoKit

enum CodingClient: String, CaseIterable, Codable, Identifiable {
    case opencode, pi, hermes
    var id: String { rawValue }
    var title: String { switch self { case .opencode: return "OpenCode"; case .pi: return "pi"; case .hermes: return "Hermes" } }
    var symbol: String { switch self { case .opencode: return "chevron.left.forwardslash.chevron.right"; case .pi: return "terminal"; case .hermes: return "sparkles" } }
    var description: String { switch self { case .opencode: return "在终端中编写与修改代码"; case .pi: return "轻量、可扩展的编程助手"; case .hermes: return "支持工具调用的本地助手" } }
    func contextRequirement(_ context: Int) -> String? {
        if self == .hermes { return context < 64_000 ? "Hermes 当前版本需要至少 64K 上下文" : nil }
        return context < 32768 ? "本地编程接入请扩展至 32K 上下文" : nil
    }
    var inheritedSelectors: [String] {
        switch self {
        case .opencode: return ["OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_TUI_CONFIG"]
        case .pi: return ["PI_CODING_AGENT_SESSION_DIR"]
        case .hermes: return ["HERMES_PROFILE", "HERMES_CONFIG", "HERMES_ENV"]
        }
    }
    var website: URL {
        switch self { case .opencode: return URL(string: "https://opencode.ai/docs/")!; case .pi: return URL(string: "https://pi.dev/")!; case .hermes: return URL(string: "https://hermes-agent.nousresearch.com/docs/")! }
    }
}

struct ClientInstallation: Identifiable {
    var id: CodingClient
    var executable: String?
    var version: String
    static func discover() -> [ClientInstallation] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/bin", "\(home)/.opencode/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return CodingClient.allCases.map { client in
            let executable = paths.map { "\($0)/\(client.rawValue)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
            // Version discovery runs off the main thread. Ensure Node shebangs also work in a Finder-launched app.
            var version = ""
            if let executable {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["PATH=\(ConnectionFiles.clientPath)", executable, "--version"]
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    version = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
                    if let range = version.range(of: #"\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.]+)?"#, options: .regularExpression) { version = String(version[range]) }
                    else { version = "" }
                } catch { }
            }
            return .init(id: client, executable: executable, version: version)
        }
    }
}

struct ConnectionTarget: Identifiable, Hashable, Codable {
    var id: String
    var engineName: String
    var engineID: String
    var model: String
    var port: Int
    var pid: Int32
    var birth: UInt64
    var context: Int?
    var endpointOverride: String? = nil
    var apiKey: String? = nil
    var capabilities: ModelCapabilities? = nil
    var sourceID: String? = nil
    var remoteRevision: String? = nil
    var backendRevision: String? = nil
    var registration: String? = nil
    var supportsThinkingToggle: Bool? = nil
    var isRemote: Bool { endpointOverride != nil }
    var endpoint: String { endpointOverride ?? "http://127.0.0.1:\(port)/v1" }
    var providerID: String { "model-manager-\(port)" }
}

struct ConnectionDraft: Identifiable { var id = UUID(); var port: Int; var sourceID: String? = nil }

struct ClientConnection: Codable {
    var client: CodingClient
    var model: String
    var endpoint: String
    var providerID: String
    var context: Int
    var project: String
    var executable: String
    var configuration: String
    var script: String
    var environment: [String: String]
    var arguments: [String]
    var service: ConnectionTarget
    var unsetEnvironment: [String]? = nil
    var registeredConfiguration: String? = nil
    var createdAt = Date()
}

enum ConnectionFiles {
    static var clientPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":") + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func validModel(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 1024 && !model.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
    static func privateDirectory(_ url: URL) throws {
        // Generated connections must stay inside the app's own directory, including when a child was replaced by a symlink.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw LaunchError.message("连接目录包含符号链接，请选择正常的应用数据目录。") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func write(_ data: Data, to url: URL, executable: Bool = false) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw LaunchError.message("连接文件包含符号链接，已停止写入。") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
    static func matches(_ target: ConnectionTarget, before: [PortListener], after: [PortListener], probe: ProbeResult, records: [ServiceSpec]) -> Bool {
        guard probe.ready, probe.models.contains(target.model), !before.isEmpty, Set(before) == Set(after),
              processStartTime(target.pid) == target.birth else { return false }
        return after.allSatisfy { listener in
            if let actual = listener.engineID, !target.isRemote, target.engineID != "external", target.engineID != "gateway", actual != target.engineID { return false }
            return listener.pid == target.pid && listener.birth == target.birth || records.contains { spec in
                spec.pid == target.pid && spec.processStart == target.birth && spec.port == target.port && spec.engineID == target.engineID && listener.belongs(to: spec)
            }
        }
    }
    static func prepare(client: CodingClient, target: ConnectionTarget, context: Int, executable: String, project: String, root: URL, guardExecutable: String? = Bundle.main.executableURL?.path, webSearch: Bool = false) throws -> ClientConnection {
        guard (target.isRemote ? (1...65535) : (1024...65535)).contains(target.port), validModel(target.model), (2048...1_048_576).contains(context),
              target.context.map({ context <= $0 }) ?? true else { throw LaunchError.message("模型名称、端口或上下文长度无效。") }
        if let requirement = client.contextRequirement(context) { throw LaunchError.message(requirement + "。请先调整模型服务的上下文设置。") }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw LaunchError.message("\(client.title) 未安装或程序路径已经改变，请重新检测。") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project, isDirectory: &directory), directory.boolValue else { throw LaunchError.message("工作目录不存在，请重新选择。") }
        let identity = "connection-v4|\(client.rawValue)|\(target.endpoint)|\(target.pid)|\(target.birth)|\(target.model)|\(context)|\(target.backendRevision ?? "")|\(target.remoteRevision ?? "")|\(target.capabilities?.inputs.joined(separator: ",") ?? "text")|\(webSearch)" + (client == .pi ? "|pi-budget-v2|\(target.supportsThinkingToggle == true)" : "")
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let profile = root.appendingPathComponent("profiles/\(client.rawValue)/\(digest)")
        try privateDirectory(profile)
        let provider = target.providerID
        let output = client == .pi ? PiConnectionPolicy.output(context) : min(2048, context / 4)
        var environment: [String: String] = ["PATH": clientPath]
        var arguments: [String] = []
        var configuration: URL
        switch client {
        case .opencode:
            let configRoot = profile.appendingPathComponent("config")
            try privateDirectory(configRoot.appendingPathComponent("opencode"))
            configuration = configRoot.appendingPathComponent("opencode/opencode.json")
            let selected = "\(provider)/\(target.model)"
            var object: [String: Any] = [
                "$schema": "https://opencode.ai/config.json",
                "model": selected, "small_model": selected, "enabled_providers": [provider], "autoupdate": false,
                "compaction": ["auto": true, "prune": true, "reserved": output + 1024, "preserve_recent_tokens": min(4096, context / 8)],
                "provider": [provider: [
                    "npm": "@ai-sdk/openai-compatible", "name": "\(target.engineName) · 本地",
                    "options": ["baseURL": target.endpoint, "apiKey": target.apiKey ?? "local-model-manager"],
                    "models": [target.model: ["name": target.model, "limit": ["context": context, "input": context - output - 1024, "output": output],
                        "cost": ["input": 0, "output": 0], "options": ["maxTokens": output], "modalities": ["input": target.capabilities?.inputs.map { $0 == "file" ? "pdf" : $0 } ?? ["text"], "output": target.capabilities?.outputs ?? ["text"]]]]
                ]]
            ]
            if webSearch { object["mcp"] = [WebSearchConnection.name: WebSearchConnection.opencode]; object["permission"] = [WebSearchConnection.name + "_*": "allow"] }
            let data = try json(object); try write(data, to: configuration)
            // The inline layer survives project-level defaults; --pure keeps third-party agents from selecting cloud models.
            environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: data, as: UTF8.self)
            environment["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
            environment["OPENCODE_DISABLE_CLAUDE_CODE_SKILLS"] = "1"
            environment["XDG_CONFIG_HOME"] = configRoot.path
            environment["XDG_DATA_HOME"] = profile.appendingPathComponent("data").path
            environment["XDG_CACHE_HOME"] = profile.appendingPathComponent("cache").path
            environment["XDG_STATE_HOME"] = profile.appendingPathComponent("state").path
            arguments = (webSearch ? [] : ["--pure"]) + ["--model", selected]
        case .pi:
            configuration = profile.appendingPathComponent("models.json")
            var modelEntry: [String: Any] = ["id": target.model, "name": target.model, "reasoning": false, "input": target.capabilities?.inputs.contains("image") == true ? ["text", "image"] : ["text"],
                "contextWindow": context, "maxTokens": output, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]]
            if target.supportsThinkingToggle == true { modelEntry["samplingParams"] = ["chat_template_kwargs": ["enable_thinking": false]] }
            try write(try json(["providers": [provider: [
                "baseUrl": target.endpoint, "api": "openai-completions", "apiKey": target.apiKey ?? "local-model-manager",
                "compat": ["supportsDeveloperRole": false, "supportsReasoningEffort": false, "supportsStore": false, "maxTokensField": "max_tokens"],
                "models": [modelEntry]
            ]]]), to: configuration)
            let settings = profile.appendingPathComponent("settings.json")
            let oldSettings = FileManager.default.fileExists(atPath: settings.path) ? try NativeClientConfig.object(Data(contentsOf: settings)) : ["defaultProvider": provider, "defaultModel": target.model, "defaultThinkingLevel": "off", "compaction": ["enabled": true]]
            try write(try json(PiConnectionPolicy.settings(oldSettings, provider: provider, model: target.model, context: context)), to: settings)
            environment["PI_CODING_AGENT_DIR"] = profile.path
            if webSearch { try write(try json(["mcpServers": [WebSearchConnection.name: WebSearchConnection.pi]]), to: profile.appendingPathComponent("mcp.json")) }
            arguments = ["--provider", provider, "--model", target.model, "--thinking", "off", "--no-skills"]
        case .hermes:
            configuration = profile.appendingPathComponent("config.yaml")
            // JSON is a YAML subset; serialize model IDs rather than interpolating them into YAML.
            try write(try json([
                "model": ["default": target.model, "provider": provider, "base_url": target.endpoint, "context_length": context, "max_tokens": output],
                "providers": [provider: ["base_url": target.endpoint, "api_key": target.apiKey ?? "local-model-manager", "default_model": target.model,
                    "api_mode": "chat_completions", "models": [target.model: ["context_length": context]]]],
                "fallback_providers": [],
                "auxiliary": ["compression": ["provider": "main", "model": target.model], "title_generation": ["provider": "main", "model": target.model]],
                "terminal": ["backend": "local"]
            ]), to: configuration)
            environment["HERMES_HOME"] = profile.path
            environment["HERMES_MAX_TOKENS"] = String(output)
            arguments = ["--provider", provider, "--model", target.model]
        }
        let scripts = root.appendingPathComponent("launchers"); try privateDirectory(scripts)
        let script = scripts.appendingPathComponent("\(client.rawValue)-\(UUID().uuidString).command")
        let receipt = script.appendingPathExtension("json")
        // No untrusted value appears unquoted in the shell; no login shell or global profile mutation.
        let exports = environment.keys.sorted().map { "export \($0)=\(quote(environment[$0]!))" }.joined(separator: "\n")
        let command = ([executable] + arguments).map(quote).joined(separator: " ")
        let guardCommand = guardExecutable.map { quote($0) + " --validate-connection " + quote(receipt.path) + "\n" } ?? ""
        let clearing = "unset " + client.inheritedSelectors.joined(separator: " ") + "\n"
        let text = "#!/bin/sh\nset -eu\n\(clearing)\(exports)\ncd -- \(quote(project))\n\(guardCommand)exec \(command)\n"
        let connection = ClientConnection(client: client, model: target.model, endpoint: target.endpoint, providerID: provider,
            context: context, project: project, executable: executable, configuration: configuration.path, script: script.path,
            environment: environment, arguments: arguments, service: target, unsetEnvironment: client.inheritedSelectors)
        try write(try JSONEncoder().encode(connection), to: receipt)
        try write(Data(text.utf8), to: script, executable: true)
        try write(try JSONEncoder().encode(connection), to: root.appendingPathComponent("latest-\(client.rawValue).json"))
        return connection
    }
    static func validateLaunch(_ receipt: URL) async throws {
        let connection = try JSONDecoder().decode(ClientConnection.self, from: Data(contentsOf: receipt))
        let target = connection.service
        guard (target.isRemote ? (1...65535) : (1024...65535)).contains(target.port), validModel(target.model), connection.model == target.model,
              connection.endpoint == target.endpoint, target.isRemote || processStartTime(target.pid) == target.birth else {
            throw LaunchError.message("原模型服务已停止或改变，请在模型管理中重新接入。")
        }
        if target.isRemote {
            try await validateRemote(target); return
        }
        func listeners() async -> [PortListener] {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: PortIdentity.listeners(ports: [target.port])[target.port] ?? []) }
            }
        }
        let before = await listeners()
        let probe = try await authenticatedProbe(target)
        let after = await listeners()
        guard probe.ready, probe.models.contains(target.model), !before.isEmpty, Set(before) == Set(after),
              processStartTime(target.pid) == target.birth,
              after.allSatisfy({ $0.belongs(pid: target.pid, birth: target.birth) && ($0.engineID == nil || target.engineID == "external" || target.engineID == "gateway" || $0.engineID == target.engineID) }) else {
            throw LaunchError.message("端口归属或模型已经改变。为避免接入错误的服务，请在模型管理中重新接入。")
        }
    }
}

@MainActor
final class ConnectionController: ObservableObject {
    @Published var draft: ConnectionDraft?
    @Published var installations: [ClientInstallation] = []
    @Published var discovering = false
    @Published var modelID = ""
    @Published var context = 8192
    @Published var project: String
    @Published var busy = false
    @Published var message: String?
    @Published var error: String?
    @Published var lastConnection: ClientConnection?
    @Published var viaGateway = false
    @Published var registerInClient = true
    @Published var webSearch = false
    let root: URL
    private let directoryURL: URL
    init(directory: URL) {
        root = directory.appendingPathComponent("connections")
        directoryURL = root.appendingPathComponent("working-directory.json")
        project = (try? Data(contentsOf: directoryURL)).flatMap { try? JSONDecoder().decode(String.self, from: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    func present(port: Int, targets: [ConnectionTarget]) {
        guard let first = targets.first(where: { $0.port == port }) else { error = "请先启动服务并等待模型接口可用。"; return }
        modelID = first.id; context = first.context ?? 8192; message = nil; error = nil; lastConnection = nil
        viaGateway = first.engineID == "gateway"
        draft = .init(port: port, sourceID: first.engineID == "gateway" ? nil : first.sourceID); discover()
    }
    func present(target: ConnectionTarget) {
        modelID = target.id; context = target.context ?? 8192; message = nil; error = nil; lastConnection = nil; viaGateway = target.engineID == "gateway"
        draft = .init(port: target.port, sourceID: target.sourceID); discover()
    }
    func discover() {
        guard !discovering else { return }; discovering = true
        Task {
            let result: [ClientInstallation] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: ClientInstallation.discover()) }
            }
            installations = result; discovering = false
        }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = L10n.text("选择客户端启动时使用的工作目录"); panel.prompt = L10n.text("选择工作目录")
        panel.directoryURL = URL(fileURLWithPath: project)
        if panel.runModal() == .OK, let url = panel.url {
            project = url.path
            do { try ConnectionFiles.privateDirectory(root); try ConnectionFiles.write(try JSONEncoder().encode(project), to: directoryURL) }
            catch { self.error = "工作目录未能保存：\(error.localizedDescription)" }
        }
    }
    func connect(_ client: CodingClient, store: AppStore, launch: Bool, registerOnly: Bool = false) {
        guard !busy else { return }
        guard let target = store.connectionTargets.first(where: { $0.id == modelID }),
              let executable = installations.first(where: { $0.id == client })?.executable else { error = "模型服务或客户端不可用，请刷新后重试。"; return }
        let chosenContext = context; let chosenProject = project
        busy = true; message = nil; error = nil
        Task {
            defer { busy = false }
            do {
                // Recheck API and kernel listener identity immediately before exporting or launching.
                await store.services.refresh()
                guard store.connectionTargets.contains(where: { $0 == target }) else { throw LaunchError.message("服务或模型已经改变，请重新选择。") }
                let listeners: [PortListener] = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: PortIdentity.listeners(ports: [target.port])[target.port] ?? []) }
                }
                if target.isRemote {
                    try await ConnectionFiles.validateRemote(target)
                }
                let probe = target.isRemote ? ProbeResult(alive: true, ready: true, models: [target.model], code: 200) : try await ConnectionFiles.authenticatedProbe(target)
                let after: [PortListener] = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: PortIdentity.listeners(ports: [target.port])[target.port] ?? []) }
                }
                guard target.isRemote || ConnectionFiles.matches(target, before: listeners, after: after, probe: probe, records: store.services.records) else {
                    throw LaunchError.message("接口模型或监听进程已改变，未接入客户端。请刷新服务后重试。")
                }
                var connection = try ConnectionFiles.prepare(client: client, target: target, context: chosenContext, executable: executable, project: chosenProject, root: root, webSearch: webSearch && client != .hermes)
                if (registerInClient || registerOnly) && client != .hermes {
                    let saved = try NativeClientConfig.register(connection, root: root, webSearch: webSearch)
                    connection.registeredConfiguration = saved.configuration.path
                    try ConnectionFiles.write(try JSONEncoder().encode(connection), to: URL(fileURLWithPath: connection.script).appendingPathExtension("json"))
                    try ConnectionFiles.write(try JSONEncoder().encode(connection), to: root.appendingPathComponent("latest-\(client.rawValue).json"))
                }
                lastConnection = connection
                if registerOnly {
                    message = "已写入 \(client.title) 的用户配置，常规启动可选择此模型。当前默认模型保留。" + (webSearch ? " 已登记联网搜索工具。" : "")
                    return
                }
                if launch {
                    guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw LaunchError.message("未找到终端应用，连接命令已生成，可复制后运行。") }
                    let config = NSWorkspace.OpenConfiguration(); config.activates = true
                    NSWorkspace.shared.open([URL(fileURLWithPath: connection.script)], withApplicationAt: terminal, configuration: config) { [weak controller = self] _, failure in
                        Task { @MainActor in
                            if let failure { controller?.error = "终端打开失败：\(failure.localizedDescription)" }
                            else { controller?.message = "已在终端打开 \(client.title)，使用 \(target.model)。" }
                        }
                    }
                } else {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("/bin/sh " + ConnectionFiles.quote(connection.script), forType: .string)
                    message = "已复制 \(client.title) 连接命令，粘贴到终端即可启动。"
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension AppStore {
    var directConnectionTargets: [ConnectionTarget] {
        let targets = benchmarkTargets.compactMap { target -> ConnectionTarget? in
            guard let pid = target.pid, let birth = target.birth, birth > 0, ConnectionFiles.validModel(target.apiModel) else { return nil }
            var value = ConnectionTarget(id: target.id, engineName: target.engineName, engineID: target.engineID, model: target.apiModel, port: target.port, pid: pid, birth: birth, context: target.context)
            value.sourceID = target.id.hasPrefix("external:") ? "external:\(target.port)" : String(target.id.split(separator: ":").first ?? "")
            var capability = services.modelCapabilities[target.port]?[target.apiModel] ?? ModelCapabilities()
            if let spec = services.records.first(where: { $0.port == target.port && $0.pid != nil }) { value.supportsThinkingToggle = PiConnectionPolicy.thinkingSupported(engine: spec.engineID, version: spec.engineVersion) }
            if let spec = services.records.first(where: { $0.port == target.port && $0.pid != nil }), let model = models.first(where: { $0.id == spec.modelID }) {
                if !capability.known { capability = ModalityPolicy.local(model) }
                capability = capability.applying(spec.inputMode ?? .automatic)
            }
            value.capabilities = capability
            return value
        } + configuredConnectionTargets
        return targets.filter { engineEnabled($0.engineID) }
    }
    var connectionTargets: [ConnectionTarget] { directConnectionTargets + gatewayConnectionTargets }
}
