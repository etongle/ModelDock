import Foundation
import AppKit
import Combine
import CryptoKit
import Darwin

struct GatewayRemoteModel: Codable, Hashable, Identifiable {
    var id: String
    var capabilities: ModelCapabilities
}
struct GatewayEndpoint: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var url: String
    var apiKey: String
    var models: [GatewayRemoteModel]
    var context: Int?
    var pid: Int32?
    var birth: UInt64?
    var revision = UUID().uuidString
    var engineID: String? = nil
}
struct GatewayPreference: Codable {
    var enabled = true
    var mode: InputMode = .automatic
    var alias: String?
}
struct GatewaySettings: Codable {
    var port = 18790
    var enabled = false
    var instance = UUID().uuidString
    var apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var endpoints: [GatewayEndpoint] = []
    var preferences: [String: GatewayPreference] = [:]
    /// 局域网共享：网关监听所有网卡，请求仍须携带网关密钥。默认关闭。
    var lanEnabled: Bool? = nil
}
struct GatewayProcess: Codable { var pid: Int32; var birth: UInt64; var port: Int }
struct GatewayRoute: Codable, Identifiable, Hashable {
    var id: String
    var sourceID: String
    var name: String
    var engineID: String
    var model: String
    var endpoint: String
    var apiKey: String
    var alias: String
    var inputs: [String]
    var outputs: [String]
    var capabilities: ModelCapabilities
    var context: Int?
    var pid: Int32?
    var birth: UInt64?
    var remote: Bool
    var available: Bool
    var enabled: Bool
    var mode: InputMode
    var revision: String
    /// 服务因空闲已停止；网关收到请求时通知 App 唤醒。
    var sleeping: Bool? = nil
}
struct GatewayConfiguration: Codable {
    var schema = 1
    var instance: String
    var apiKey: String
    var routes: [GatewayRoute]
    var solutions: [GatewaySolution] = []
}

@MainActor
final class GatewayEndpointDraft: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    @Published var name = ""
    @Published var engineID = "external"
    @Published var url = "http://127.0.0.1:1234/v1"
    @Published var apiKey = ""
    @Published var context = ""
    @Published var images = false
    @Published var audio = false
    @Published var files = false
    @Published var message: String?
    @Published var busy = false
    var editingID: String?
    init(_ value: GatewayEndpoint? = nil) {
        engineID = value?.engineID ?? "external"
        if let value { editingID = value.id; name = value.name; url = value.url; apiKey = value.apiKey; context = value.context.map(String.init) ?? ""; images = value.models.contains { $0.capabilities.inputs.contains("image") }; audio = value.models.contains { $0.capabilities.inputs.contains("audio") }; files = value.models.contains { $0.capabilities.inputs.contains("file") } }
    }
}

enum GatewayAddress {
    static func validated(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.pathComponents.contains("..") else { throw LaunchError.message("请填写 HTTP / HTTPS 的 OpenAI 兼容接口地址，密钥单独填写。") }
        return url
    }
    static func loopback(_ url: URL) -> Bool { ["127.0.0.1", "localhost"].contains(url.host) }
    static func modelList(_ url: URL, apiKey: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models")!); request.timeoutInterval = 12
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral, delegate: GatewayRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = json["data"] as? [[String: Any]] else { throw LaunchError.message("外部接口未返回可用的模型列表，请检查地址、密钥和原服务。") }
        return models
    }
}

@MainActor
final class GatewayController: ObservableObject {
    @Published var settings: GatewaySettings
    @Published var process: GatewayProcess?
    @Published var ready = false
    @Published var supportsImageSolutionRoutes = false
    @Published var supportsImageEditRoutes = false
    @Published var supportsSolutionRoutes = false
    @Published var busy = false
    @Published var error: String?
    @Published var routes: [GatewayRoute] = []
    @Published var solutionRoutes: [GatewaySolution] = []
    @Published var editor: GatewayEndpointDraft?
    @Published var portText = "18790"
    @Published var requests = 0
    @Published var active = 0
    @Published var failed = 0
    let root: URL
    private var child: Process?
    private var output: FileHandle?
    private var polling = false
    private var lastConfiguration: Data?
    /// 本机服务最近一次的路由，服务休眠后据此保留路由。按路由 ID 保存。
    private lazy var sleepingCache: [String: GatewayRoute] = (try? Data(contentsOf: root.appendingPathComponent("sleeping-routes.json"))).flatMap { try? JSONDecoder().decode([String: GatewayRoute].self, from: $0) } ?? [:]
    var settingsURL: URL { root.appendingPathComponent("settings.json") }
    var configurationURL: URL { root.appendingPathComponent("runtime.json") }
    var processURL: URL { root.appendingPathComponent("process.json") }
    var endpoint: String { "http://127.0.0.1:\(settings.port)/v1" }
    init(directory: URL) {
        root = directory.appendingPathComponent("gateway")
        settings = (try? Data(contentsOf: root.appendingPathComponent("settings.json"))).flatMap { try? JSONDecoder().decode(GatewaySettings.self, from: $0) } ?? GatewaySettings()
        portText = String(settings.port)
        process = (try? Data(contentsOf: root.appendingPathComponent("process.json"))).flatMap { try? JSONDecoder().decode(GatewayProcess.self, from: $0) }
        if let process, processStartTime(process.pid) != process.birth { self.process = nil }
    }
    func save() throws {
        try ConnectionFiles.privateDirectory(root)
        try ConnectionFiles.write(try JSONEncoder().encode(settings), to: settingsURL)
    }
    func ownsProcess() -> Bool {
        guard let process, process.pid > 1, process.birth > 0, processStartTime(process.pid) == process.birth,
              getpgid(process.pid) == process.pid else { return false }
        let arguments = PortIdentity.arguments(process.pid)
        return arguments.contains(configurationURL.path) && arguments.contains { URL(fileURLWithPath: $0).lastPathComponent == "gateway.py" }
    }
    func synchronize(_ targets: [ConnectionTarget], local: [LocalModel], services: ServiceController, deployments: [SolutionDeployment] = []) {
        var values: [GatewayRoute] = []
        for target in targets where target.engineID != "gateway" {
            let source = target.sourceID ?? "\(target.engineID):\(target.port)"
            let identifier = "\(source)|\(target.model)"
            let preference = settings.preferences[identifier] ?? GatewayPreference()
            let rawName = target.model.hasPrefix("/") ? URL(fileURLWithPath: target.model).deletingPathExtension().lastPathComponent : target.model
            let physical = source.hasPrefix("external:") ? "\(source)|\(target.pid)|\(target.birth)" : source
            let prefix = target.isRemote ? "external-\(digest(source).prefix(8))" : "\(target.engineID)-\(target.port)-\(digest(physical).prefix(6))"
            let alias = preference.alias ?? "\(prefix)/\(rawName)"
            let capabilities = target.capabilities ?? ModelCapabilities()
            let hash = digest("\(identifier)|\(target.endpoint)|\(target.pid)|\(target.birth)|\(preference.mode.rawValue)|\(capabilities.inputs.joined(separator: ","))|\(target.remoteRevision ?? "")")
            values.append(.init(id: identifier, sourceID: source, name: "\(target.engineName) · \(rawName)", engineID: target.engineID, model: target.model, endpoint: target.endpoint, apiKey: target.apiKey ?? "", alias: alias, inputs: capabilities.applying(preference.mode).inputs, outputs: capabilities.outputs, capabilities: capabilities, context: target.context, pid: target.pid > 0 ? target.pid : nil, birth: target.birth > 0 ? target.birth : nil, remote: target.isRemote, available: true, enabled: preference.enabled, mode: preference.mode, revision: hash))
        }
        // 休眠服务：沿用最近一次的路由（别名不变），标记 sleeping，供网关唤醒。
        var cache = sleepingCache
        for route in values where !route.remote { cache[route.id] = route }
        let sleeping = Set(services.records.filter { $0.sleeping == true && $0.pid == nil }.map(\.id))
        cache = cache.filter { _, route in sleeping.contains(route.sourceID) || values.contains { $0.id == route.id } }
        for (id, var route) in cache where sleeping.contains(route.sourceID) && !values.contains(where: { $0.id == id }) {
            route.sleeping = true; route.available = false; route.pid = nil; route.birth = nil
            values.append(route)
        }
        if cache != sleepingCache {
            sleepingCache = cache
            try? ConnectionFiles.privateDirectory(root)
            if let data = try? JSONEncoder().encode(cache) { try? ConnectionFiles.write(data, to: root.appendingPathComponent("sleeping-routes.json")) }
        }
        routes = values.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
        solutionRoutes = synchronizeSolutions(deployments, local: local, services: services)
        do {
            let data = try JSONEncoder().encode(GatewayConfiguration(instance: settings.instance, apiKey: settings.apiKey, routes: routes, solutions: solutionRoutes))
            if data != lastConfiguration { try ConnectionFiles.privateDirectory(root); try ConnectionFiles.write(data, to: configurationURL); lastConfiguration = data }
        } catch { self.error = "网关配置未能保存：\(error.localizedDescription)" }
    }
    func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() }
    func setMode(_ route: GatewayRoute, _ mode: InputMode, store: AppStore) {
        guard mode != .multimodal || route.capabilities.supportsMedia else { error = "此服务未声明多模态能力，请在原服务开启或在外部配置中明确声明。"; return }
        var value = settings.preferences[route.id] ?? GatewayPreference(); value.mode = mode; settings.preferences[route.id] = value
        do { try save(); store.synchronizeGateway() } catch { self.error = error.localizedDescription }
    }
    func setEnabled(_ route: GatewayRoute, _ enabled: Bool, store: AppStore) {
        var value = settings.preferences[route.id] ?? GatewayPreference(); value.enabled = enabled; settings.preferences[route.id] = value
        do { try save(); store.synchronizeGateway() } catch { self.error = error.localizedDescription }
    }
    func start(store: AppStore) {
        guard !busy else { return }
        guard let port = Int(portText), (1024...65535).contains(port) else { error = "网关端口需要在 1024–65535 之间。"; return }
        if ownsProcess() { Task { await poll() }; return }
        guard !NetworkProbe.portOccupied(port), !store.services.portReserved(port) else { error = "端口 \(port) 已被占用，请选择其他网关端口。"; return }
        guard let python = EnginePaths.gatewayPython, let resources = Bundle.main.resourceURL else { error = "未找到网关运行环境。"; return }
        busy = true; error = nil
        do {
            settings.port = port; settings.enabled = true; try save(); store.synchronizeGateway()
            let log = root.appendingPathComponent("gateway.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
            let task = Process(); task.executableURL = Bundle.main.executableURL
            task.arguments = ["--child-exec", python, "-I", "-B", "-u", resources.appendingPathComponent("gateway.py").path, "--config", configurationURL.path, "--identity-lib", resources.appendingPathComponent("ProcessIdentity.dylib").path, "--port", String(port), "--host", settings.lanEnabled == true ? "0.0.0.0" : "127.0.0.1"]
            task.standardOutput = handle; task.standardError = handle; task.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment; environment["PYTHONDONTWRITEBYTECODE"] = "1"; task.environment = environment
            try task.run(); child = task; output = handle
            let birth = processStartTime(task.processIdentifier)
            guard birth > 0 else { task.terminate(); throw LaunchError.message("无法核对网关进程身份。") }
            process = .init(pid: task.processIdentifier, birth: birth, port: port)
            try ConnectionFiles.write(try JSONEncoder().encode(process), to: processURL)
            Task {
                defer { self.busy = false }
                for _ in 0..<50 { await self.poll(); if self.ready { store.synchronizeGateway(); return }; if !task.isRunning { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
                self.error = "网关未能启动，请检查网关运行日志。"
            }
        } catch { busy = false; self.error = error.localizedDescription }
    }
    func stop() {
        guard !busy else { return }
        guard ownsProcess(), let process else { ready = false; self.process = nil; return }
        busy = true
        settings.enabled = false; try? save()
        _ = kill(-process.pid, SIGTERM)
        Task {
            defer { busy = false }
            for _ in 0..<40 { if processStartTime(process.pid) != process.birth { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            guard processStartTime(process.pid) != process.birth else { error = "网关仍在处理请求，请稍后再试。"; return }
            ready = false; self.process = nil; try? FileManager.default.removeItem(at: processURL)
            try? output?.close(); output = nil; child = nil
        }
    }
    func poll() async {
        guard !polling else { return }; polling = true; defer { polling = false }
        guard ownsProcess(), let process else { ready = false; supportsSolutionRoutes = false; return }
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(process.port)/health")!); request.timeoutInterval = 2
            request.setValue("Bearer " + settings.apiKey, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let before = await PortIdentity.snapshot(ports: [process.port])
            ready = (response as? HTTPURLResponse)?.statusCode == 200 && value?["instance"] as? String == settings.instance && value?["pid"] as? Int32 == process.pid && ownsProcess() && !(before[process.port] ?? []).isEmpty && (before[process.port] ?? []).allSatisfy { $0.belongs(pid: process.pid, birth: process.birth) }
            supportsImageSolutionRoutes = ready && (value?["features"] as? [String] ?? []).contains("image_solution_routes")
            supportsImageEditRoutes = ready && (value?["features"] as? [String] ?? []).contains("image_edit_routes")
            supportsSolutionRoutes = ready && (value?["features"] as? [String] ?? []).contains("solution_routes")
            if ready {
                request.url = URL(string: "http://127.0.0.1:\(process.port)/gateway/status")!
                let (stats, _) = try await URLSession.shared.data(for: request)
                let object = try JSONSerialization.jsonObject(with: stats) as? [String: Any]
                requests = object?["requests"] as? Int ?? 0; active = object?["active"] as? Int ?? 0; failed = object?["failed"] as? Int ?? 0
            }
        } catch { ready = false; supportsSolutionRoutes = false }
    }
    func addEndpoint(_ draft: GatewayEndpointDraft, store: AppStore) {
        guard !draft.busy else { return }; draft.busy = true; draft.message = nil
        Task {
            defer { draft.busy = false }
            do {
                var url = try GatewayAddress.validated(draft.url)
                guard draft.apiKey.utf8.count <= 8192, !draft.apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw LaunchError.message("密钥不能包含换行或控制字符。") }
                if url.host == "localhost", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) { parts.host = "127.0.0.1"; url = parts.url! }
                guard !GatewayAddress.loopback(url) || (url.port ?? 80) != settings.port else { throw LaunchError.message("外部接口不能指向网关自身。") }
                let localPort = GatewayAddress.loopback(url) ? url.port ?? 80 : nil
                let before = await PortIdentity.snapshot(ports: Set(localPort.map { [$0] } ?? []))
                let objects = try await GatewayAddress.modelList(url, apiKey: draft.apiKey)
                let after = await PortIdentity.snapshot(ports: Set(localPort.map { [$0] } ?? []))
                if let localPort { guard !(before[localPort] ?? []).isEmpty, Set(before[localPort] ?? []) == Set(after[localPort] ?? []) else { throw LaunchError.message("本机外部服务的监听进程已变化，请重新检测。") } }
                let models = objects.compactMap { object -> GatewayRemoteModel? in
                    guard let id = object["id"] as? String, ConnectionFiles.validModel(id) else { return nil }
                    var capability = ModelCapabilities.declared(object)
                    if !capability.known { capability.inputs = ["text"] + (draft.images ? ["image"] : []) + (draft.audio ? ["audio"] : []) + (draft.files ? ["file"] : []); capability.known = true; capability.source = "手动声明的服务能力" }
                    return .init(id: id, capabilities: capability)
                }
                guard !models.isEmpty else { throw LaunchError.message("此接口没有公布可用模型。") }
                let context = draft.context.isEmpty ? nil : Int(draft.context)
                guard draft.context.isEmpty || context.map({ (2048...1_048_576).contains($0) }) == true else { throw LaunchError.message("请填写服务实际支持的上下文长度。") }
                var entry = GatewayEndpoint(name: draft.name.isEmpty ? url.host! : draft.name, url: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), apiKey: draft.apiKey, models: models, context: context, pid: localPort.flatMap { after[$0]?.first?.pid }, birth: localPort.flatMap { after[$0]?.first?.birth })
                entry.engineID = draft.engineID == "strata" ? "strata" : nil
                if let id = draft.editingID { entry.id = id; settings.endpoints.removeAll { $0.id == id } }
                settings.endpoints.append(entry); try save(); editor = nil; store.synchronizeGateway()
            } catch { draft.message = error.localizedDescription }
        }
    }
    func removeEndpoint(_ entry: GatewayEndpoint, store: AppStore) {
        settings.endpoints.removeAll { $0.id == entry.id }
        do { try save(); store.synchronizeGateway() } catch { self.error = error.localizedDescription }
    }
}

@MainActor
extension AppStore {
    func synchronizeGateway() {
        gateway.synchronize(gatewaySourceTargets, local: models, services: services, deployments: solutions.deployments)
        services.ignoredPorts = gateway.ownsProcess() ? [gateway.settings.port] : []
    }
    var gatewayConnectionTargets: [ConnectionTarget] {
        guard gateway.ready, let process = gateway.process else { return [] }
        return gateway.routes.filter { $0.enabled && $0.available && $0.inputs.contains("text") && $0.outputs.contains("text") }.map { route in
            var target = ConnectionTarget(id: "gateway:\(route.id)", engineName: route.name, engineID: "gateway", model: route.alias, port: process.port, pid: process.pid, birth: process.birth, context: route.context)
            target.apiKey = gateway.settings.apiKey; target.capabilities = route.capabilities.applying(route.mode); target.sourceID = route.sourceID; target.backendRevision = route.revision
            target.supportsThinkingToggle = PiConnectionPolicy.thinkingSupported(engine: route.engineID, version: services.records.first { $0.id == route.sourceID }?.engineVersion)
            return target
        }
    }
    var configuredConnectionTargets: [ConnectionTarget] { configuredGatewayTargets.filter { ($0.capabilities?.outputs ?? ["text"]).contains("text") && ($0.capabilities?.inputs ?? ["text"]).contains("text") } }
    var configuredGatewayTargets: [ConnectionTarget] {
        gateway.settings.endpoints.flatMap { entry in entry.models.map { model in
            var target = ConnectionTarget(id: "remote:\(entry.id):\(model.id)", engineName: entry.name, engineID: entry.engineID ?? "remote", model: model.id, port: URL(string: entry.url)?.port ?? (entry.url.hasPrefix("https") ? 443 : 80), pid: entry.pid ?? 0, birth: entry.birth ?? 0, context: model.capabilities.context ?? entry.context)
            target.endpointOverride = entry.url; target.apiKey = entry.apiKey.isEmpty ? nil : entry.apiKey; target.capabilities = model.capabilities; target.sourceID = "remote:\(entry.id)"; target.remoteRevision = entry.revision; target.registration = gateway.settingsURL.path
            return target
        } }
    }
}

final class GatewayRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
