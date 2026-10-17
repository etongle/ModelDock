import Foundation
import Combine
import Darwin

enum ServiceStatus: String, Codable {
    case stopped, starting, running, stopping, failed, conflicted
    var title: String {
        switch self { case .stopped: return "未启动"; case .starting: return "正在加载"; case .running: return "运行中"; case .stopping: return "正在停止"; case .failed: return "启动失败"; case .conflicted: return "端口冲突" }
    }
}

struct ObservedService: Identifiable {
    var id: Int { port }
    var port: Int
    var engineName: String
    var models: [String]
    var ready: Bool
    var statusCode: Int?
    var engineID: String? = nil
    var pid: Int32? = nil
    var birth: UInt64? = nil
}

struct ProbeResult { var alive: Bool; var ready: Bool; var models: [String]; var code: Int?; var capabilities: [String: ModelCapabilities] = [:] }

enum NetworkProbe {
    static func portOccupied(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return true }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
    static func models(port: Int, ollama: Bool = false, studio: Bool = false, strata: Bool = false) async -> ProbeResult {
        let endpoint = "http://127.0.0.1:\(port)" + (ollama ? "/api/tags" : "/v1/models")
        var request = URLRequest(url: URL(string: endpoint)!); request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let entries = json?[ollama ? "models" : "data"] as? [[String: Any]]
            var capabilities: [String: ModelCapabilities] = [:]
            for entry in entries ?? [] { if let name = entry[ollama ? "name" : "id"] as? String { capabilities[name] = ModelCapabilities.declared(entry) } }
            if ollama, code == 200 {
                for name in (entries ?? []).compactMap({ $0["name"] as? String }).prefix(24) {
                    if let show = try? await OllamaModelManagement.request(port: port, path: "/api/show", method: "POST", body: ["model": name]) { capabilities[name] = ModelCapabilities.declared(show, source: "Ollama 模型能力") }
                }
            } else if studio, code == 200, capabilities.values.contains(where: { !$0.known }) {
                var native = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/models")!); native.timeoutInterval = 2
                if let (bytes, response) = try? await URLSession.shared.data(for: native), (response as? HTTPURLResponse)?.statusCode == 200,
                   let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], let models = object["models"] as? [[String: Any]] {
                    for model in models {
                        let declared = ModelCapabilities.declared(model, source: "LM Studio 原生模型能力")
                        if let key = model["key"] as? String, capabilities[key]?.known == false, declared.known { capabilities[key] = declared }
                        for instance in model["loaded_instances"] as? [[String: Any]] ?? [] {
                            guard let name = instance["id"] as? String, declared.known, capabilities[name] != nil,
                                  capabilities[name]?.known == false || capabilities[name]?.source == declared.source else { continue }
                            var loaded = declared; loaded.context = (instance["config"] as? [String: Any])?["context_length"] as? Int; capabilities[name] = loaded
                        }
                    }
                }
            } else if code == 200, capabilities.count == 1, capabilities.values.contains(where: { !$0.known }) {
                var props = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/props")!); props.timeoutInterval = 2
                if let (bytes, response) = try? await URLSession.shared.data(for: props), (response as? HTTPURLResponse)?.statusCode == 200,
                   let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                    let declared = ModelCapabilities.declared(object)
                    if declared.known { for name in capabilities.keys where capabilities[name]?.known != true { capabilities[name] = declared } }
                }
            }
            var ready = code == 200 && entries != nil
            if strata && ready {
                var health = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!); health.timeoutInterval = 2
                if let (bytes, response) = try? await URLSession.shared.data(for: health), (response as? HTTPURLResponse)?.statusCode == 200,
                   let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], object["service"] as? String == "strata" { ready = object["loaded"] as? Bool == true }
                else { ready = false }
            }
            return ProbeResult(alive: true, ready: ready, models: (entries ?? []).compactMap { $0[ollama ? "name" : "id"] as? String }, code: code, capabilities: capabilities)
        } catch { return ProbeResult(alive: portOccupied(port), ready: false, models: [], code: nil) }
    }
    static func detect(port: Int, ollama: Bool, studio: Bool = false, strata: Bool = false) async -> ProbeResult {
        let result = await models(port: port, ollama: ollama, studio: studio, strata: strata)
        if strata { return result }
        guard result.alive && !result.ready && !ollama else { return result }
        let fallback = await models(port: port, ollama: true)
        return fallback.ready ? fallback : result
    }
}

@MainActor
final class ServiceController: ObservableObject {
    @Published var records: [ServiceSpec] = []
    @Published var statuses: [String: ServiceStatus] = [:]
    /// Services whose stop was requested here, so a later exit is not reported as unexpected.
    var stopRequested = Set<String>()
    @Published var external: [ObservedService] = []
    @Published var errors: [String: String] = [:]
    @Published var polling = false
    @Published var logRevision = 0
    @Published var reportedModels: [Int: [String]] = [:]
    @Published var loadedModels: [Int: [LoadedModel]] = [:]
    @Published var listeners: [Int: [PortListener]] = [:]
    @Published var engineProcesses: [EngineRuntimeProcess] = []
    @Published var modelCapabilities: [Int: [String: ModelCapabilities]] = [:]
    var ignoredPorts = Set<Int>()
    private var processes: [String: Process] = [:]
    private var handles: [String: FileHandle] = [:]
    private var timer: Timer?
    private var watchedPort: Int?
    let stateDirectory: URL

    init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
        do {
            try FileManager.default.createDirectory(at: stateDirectory.appendingPathComponent("logs"), withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: stateDirectory.appendingPathComponent("services.json")), let saved = try? JSONDecoder().decode([ServiceSpec].self, from: data) { records = saved }
        } catch { errors["storage"] = "无法保存服务配置：\(error.localizedDescription)" }
        for index in records.indices {
            if let pid = records[index].pid, ownsProcess(records[index], pid: pid) { statuses[records[index].id] = .starting }
            else { records[index].pid = nil; statuses[records[index].id] = .stopped }
        }
    }

    func beginMonitoring() {
        Task { await refresh() }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in if self?.polling == false { await self?.refresh() } } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func pauseMonitoring() { timer?.invalidate(); timer = nil }

    func watchPort(_ port: Int?) {
        guard watchedPort != port else { return }; watchedPort = port
        Task { if !polling { await refresh() } }
    }

    func record(engineID: String, modelID: String?, port: Int) -> ServiceSpec? {
        records.first { $0.engineID == engineID && $0.port == port && (engineID == "ollama" || modelID == nil || $0.modelID == modelID) }
    }
    func status(_ spec: ServiceSpec) -> ServiceStatus { statuses[spec.id] ?? .stopped }
    func portReserved(_ port: Int, excluding id: String? = nil) -> Bool {
        records.contains { $0.port == port && $0.pid != nil && $0.id != id }
    }
    func identifies(engineID: String, port: Int) -> Bool {
        let current = listeners[port] ?? []
        return !current.isEmpty && current.allSatisfy { listener in
            guard processStartTime(listener.pid) == listener.birth else { return false }
            if let actual = listener.engineID { return actual == engineID }
            return records.contains { $0.engineID == engineID && $0.port == port && status($0) == .running && listener.belongs(to: $0) }
        }
    }
    func portConflict(_ port: Int, excluding id: String? = nil) -> String? {
        if let external = external.first(where: { $0.port == port }) {
            return "端口 \(port) 已由 \(external.engineName) 使用" + (external.pid.map { " · PID \($0)" } ?? "")
        }
        if let spec = records.first(where: { $0.port == port && $0.pid != nil && $0.id != id }) {
            return "端口 \(port) 已由 \(PortIdentity.name(spec.engineID)) 使用（\(status(spec).title)）"
        }
        if let id, records.contains(where: { $0.id == id && $0.pid != nil }), statuses[id] != .conflicted { return nil }
        return NetworkProbe.portOccupied(port) ? "端口 \(port) 已被其他进程占用" : nil
    }
    func logURL(_ id: String) -> URL { stateDirectory.appendingPathComponent("logs/\(id).log") }

    func log(_ id: String) -> String {
        guard let file = try? FileHandle(forReadingFrom: logURL(id)) else { return "启动后显示运行日志" }
        defer { try? file.close() }
        let end = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: end > 80_000 ? end - 80_000 : 0)
        let data = (try? file.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? "等待引擎输出日志…" : text
    }

    private func save() {
        do { try JSONEncoder().encode(records).write(to: stateDirectory.appendingPathComponent("services.json"), options: .atomic) }
        catch { errors["storage"] = "配置保存失败：\(error.localizedDescription)" }
    }
    func captureComponents(_ value: ServiceComponentSnapshot, spec: ServiceSpec) {
        guard let index = records.firstIndex(where: { $0.id == spec.id && $0.pid == spec.pid && $0.processStart == spec.processStart && $0.startedAt == spec.startedAt }), records[index].componentSnapshot != value else { return }
        if let old = records[index].componentSnapshot, !old.entries.contains(where: { $0.id == "draft" && !$0.confirmed }) { return }
        records[index].componentSnapshot = value; save()
    }

    private func ownsProcess(_ spec: ServiceSpec, pid: Int32) -> Bool {
        guard pid > 1, kill(pid, 0) == 0, getpgid(pid) == pid else { return false }
        if let process = processes[spec.id], process.processIdentifier == pid, process.isRunning { return true }
        if let identity = spec.processStart, identity > 0, processStartTime(pid) == identity { return true }
        guard let engine = Scanner.engines().first(where: { $0.id == spec.engineID }) else { return false }
        let command = runText("/bin/ps", ["-p", String(pid), "-o", "comm="])
        return URL(fileURLWithPath: command).resolvingSymlinksInPath().path == URL(fileURLWithPath: engine.path).resolvingSymlinksInPath().path
    }

    @discardableResult
    // `extraArguments == nil` keeps the flags already saved on the matching configuration.
    func start(engine: Engine, model: LocalModel?, port: Int, context: Int, maximumLoadedModels: Int = 3, inputMode: InputMode = .automatic, projectorPath: String? = nil, extraArguments: [String]? = nil) throws -> ServiceSpec {
        var plan = try LaunchBuilder.plan(engine: engine, model: model, port: port, context: context, maximumLoadedModels: maximumLoadedModels, inputMode: inputMode, projectorPath: projectorPath)
        guard !portReserved(port), !NetworkProbe.portOccupied(port) else { throw LaunchError.message((portConflict(port) ?? "端口 \(port) 已被占用") + "，请使用空闲端口") }
        var spec = record(engineID: engine.id, modelID: model?.id, port: port) ?? ServiceSpec(engineID: engine.id, modelID: model?.id ?? "", modelName: model?.name ?? "Ollama 服务", modelPath: model?.path ?? "", port: port)
        guard spec.pid == nil else { throw LaunchError.message("这个服务已经启动，请先停止再重新配置") }
        let extras = extraArguments ?? spec.extraArguments ?? []
        try ServiceExtraArguments.validate(extras, engine: engine)
        plan.arguments += extras; spec.extraArguments = extras.isEmpty ? nil : extras
        spec.context = context; spec.startedAt = Date()
        spec.inputMode = inputMode; spec.projectorPath = projectorPath?.isEmpty == false ? projectorPath : nil
        spec.engineVersion = plan.engineVersion; spec.engineExecutable = plan.executable
        if engine.kind == .splash, let prepared = model?.preparedForSplash(inputMode) { spec.modelPath = prepared.path }
        if engine.kind == .strata, let prepared = model?.preparedForStrata(inputMode) { spec.modelPath = prepared.path; spec.modelName = prepared.name }
        if engine.kind == .ollama { spec.modelName = "Ollama 多模型服务"; spec.modelID = ""; spec.modelPath = ""; spec.maximumLoadedModels = maximumLoadedModels }
        spec.commandText = nil
        return try startPlan(spec: spec, plan: plan, engine: engine)
    }

    @discardableResult
    func start(command: CommandLaunch) throws -> ServiceSpec {
        guard !portReserved(command.port), !NetworkProbe.portOccupied(command.port) else { throw LaunchError.message((portConflict(command.port) ?? "端口已占用") + "，请修改命令中的端口") }
        var spec = record(engineID: command.engine.id, modelID: command.modelID, port: command.port) ?? ServiceSpec(engineID: command.engine.id, modelID: command.modelID, modelName: command.modelName, modelPath: command.modelPath, port: command.port)
        guard spec.pid == nil else { throw LaunchError.message("服务仍在运行，请先停止") }
        spec.modelID = command.modelID; spec.modelName = command.modelName; spec.modelPath = command.modelPath
        spec.context = command.context; spec.inputMode = command.mode; spec.projectorPath = command.projector
        spec.commandText = command.display; spec.startedAt = Date()
        spec.engineVersion = command.plan.engineVersion; spec.engineExecutable = command.plan.executable
        return try startPlan(spec: spec, plan: command.plan, engine: command.engine)
    }

    private func startPlan(spec original: ServiceSpec, plan: LaunchPlan, engine: Engine) throws -> ServiceSpec {
        var spec = original
        spec.launchArguments = plan.arguments
        spec.componentSnapshot = nil
        spec.sleeping = nil
        func argument(_ flag: String) -> String? { guard let index = plan.arguments.firstIndex(of: flag), index + 1 < plan.arguments.count else { return nil }; return plan.arguments[index + 1] }
        spec.draftModelPath = argument("--draft-model")
        spec.projectorPath = argument("--mmproj")
        let logPath = logURL(spec.id)
        if !FileManager.default.fileExists(atPath: logPath.path) { FileManager.default.createFile(atPath: logPath.path, contents: nil) }
        let output = try FileHandle(forWritingTo: logPath); try output.seekToEnd()
        try output.write(contentsOf: Data("\n—— \(Date().formatted()) · 启动 \(engine.name) \(spec.engineVersion ?? engine.version) / \(spec.modelName) ——\n运行组件：\(plan.executable)\n".utf8))
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--child-exec", plan.executable] + plan.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        for (key, value) in plan.environment { environment[key] = value }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        let id = spec.id
        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasStopping = self.statuses[id] == .stopping
                self.statuses[id] = wasStopping || task.terminationStatus == 0 ? .stopped : .failed
                if !wasStopping && task.terminationStatus != 0 { self.errors[id] = "引擎已退出（代码 \(task.terminationStatus)），请查看日志" }
                if let index = self.records.firstIndex(where: { $0.id == id }) { self.records[index].pid = nil }
                self.processes[id] = nil; try? self.handles.removeValue(forKey: id)?.close(); self.save(); self.logRevision += 1
            }
        }
        do { try process.run() } catch { try? output.close(); throw error }
        spec.pid = process.processIdentifier
        let identity = processStartTime(process.processIdentifier)
        spec.processStart = identity > 0 ? identity : nil
        processes[id] = process; handles[id] = output
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = spec } else { records.append(spec) }
        statuses[id] = .starting; errors[id] = nil; save()
        Task { if !polling { await refresh() } }
        return spec
    }

    func stop(_ spec: ServiceSpec) throws {
        guard let current = records.first(where: { $0.id == spec.id }), let pid = current.pid, ownsProcess(current, pid: pid) else { throw LaunchError.message("无法确认此服务由本工具启动，不会停止其他进程") }
        statuses[spec.id] = .stopping; stopRequested.insert(spec.id)
        guard kill(-pid, SIGTERM) == 0 else { throw LaunchError.message("无法停止服务：\(String(cString: strerror(errno)))") }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            if let latest = self.records.first(where: { $0.id == spec.id }), latest.pid == pid, self.ownsProcess(latest, pid: pid) { _ = kill(-pid, SIGKILL) }
            await self.refresh()
        }
    }

    /// Saves new launch parameters on a stopped configuration; the next start uses them.
    /// 保存运行方式（随 App 启动、空闲停止、休眠标记），不影响运行中的进程。
    func updateBehavior(_ id: String, autoStart: Bool? = nil, idleMinutes: Int?? = nil, sleeping: Bool? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let autoStart { records[index].autoStart = autoStart ? true : nil }
        if let idleMinutes { records[index].idleMinutes = idleMinutes }
        if let sleeping { records[index].sleeping = sleeping ? true : nil }
        save()
    }

    func updateParameters(_ id: String, _ value: ServiceParameters) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw LaunchError.message("这条服务配置已删除") }
        let current = records[index]
        guard current.pid == nil, processes[id]?.isRunning != true else { throw LaunchError.message("服务仍在运行，请先停止") }
        // start() reuses the record matching engine/model/port, so a second record on the new port would be ambiguous.
        if records.contains(where: { $0.id != id && $0.engineID == current.engineID && $0.port == value.port && (current.engineID == "ollama" || $0.modelID == current.modelID) }) {
            throw LaunchError.message("端口 \(value.port) 已有同一模型的服务配置")
        }
        records[index].port = value.port; records[index].context = value.context; records[index].inputMode = value.inputMode
        records[index].projectorPath = value.projectorPath; records[index].extraArguments = value.extraArguments.isEmpty ? nil : value.extraArguments
        if current.engineID == "ollama" { records[index].maximumLoadedModels = value.maximumLoadedModels }
        save()
    }

    func waitForRelease(port: Int) async throws {
        for _ in 0..<48 {
            await refresh()
            if !NetworkProbe.portOccupied(port), !portReserved(port) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LaunchError.message("服务端口尚未释放，已停止后续操作。请查看服务状态。")
    }
    func waitForReady(_ spec: ServiceSpec) async throws -> ServiceSpec {
        for _ in 0..<120 {
            await refresh()
            if status(spec) == .running, let current = records.first(where: { $0.id == spec.id }) { return current }
            if [.failed, .conflicted].contains(status(spec)) { throw LaunchError.message(errors[spec.id] ?? "引擎启动失败，请查看运行日志。") }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LaunchError.message("服务启动超时，请查看运行日志。")
    }

    func canRemoveConfiguration(_ spec: ServiceSpec) -> Bool {
        guard let current = records.first(where: { $0.id == spec.id }), current.pid == nil,
              processes[current.id]?.isRunning != true else { return false }
        return ![ServiceStatus.starting, .running, .stopping].contains(status(current))
    }

    func statusTitle(_ spec: ServiceSpec) -> String {
        if status(spec) == .starting { return startupProgress(spec).summary }
        return status(spec) == .stopped && spec.startedAt != nil ? "已停止" : status(spec).title
    }

    func removeConfiguration(_ spec: ServiceSpec) throws {
        guard records.contains(where: { $0.id == spec.id }) else { throw LaunchError.message("这条服务配置已删除") }
        // Read the current record, not the view's earlier copy: it may have been restarted.
        guard canRemoveConfiguration(spec) else { throw LaunchError.message("先停止服务，再删除配置") }
        let remaining = records.filter { $0.id != spec.id }
        try JSONEncoder().encode(remaining).write(to: stateDirectory.appendingPathComponent("services.json"), options: .atomic)
        records = remaining; statuses[spec.id] = nil; errors[spec.id] = nil
    }

    func refresh() async {
        // An explicit refresh after a load/start must await the prior snapshot
        // before taking a fresh one. Timers and field changes skip pending work.
        while polling {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        polling = true; defer { polling = false }
        engineProcesses = await EngineUpdateScope.snapshot()
        let currentRecords = records
        let ports = Set(Scanner.engines().map(\.defaultPort) + currentRecords.map(\.port) + (watchedPort.map { [$0] } ?? []))
        let before = await PortIdentity.snapshot(ports: ports)
        var observed: [ObservedService] = []
        let responses = await withTaskGroup(of: (Int, ProbeResult).self) { group in
            for port in ports {
                let native = before[port]?.contains { listener in listener.engineID == "ollama" || currentRecords.contains { spec in spec.engineID == "ollama" && listener.belongs(to: spec) } } == true
                let studio = before[port]?.contains { listener in listener.engineID == "lmstudio" || currentRecords.contains { spec in spec.engineID == "lmstudio" && listener.belongs(to: spec) } } == true
                let strata = before[port]?.contains { listener in listener.engineID == "strata" || currentRecords.contains { spec in spec.engineID == "strata" && listener.belongs(to: spec) } } == true
                group.addTask { (port, await NetworkProbe.detect(port: port, ollama: native, studio: studio, strata: strata)) }
            }
            var results: [(Int, ProbeResult)] = []; for await result in group { results.append(result) }; return results
        }
        let after = await PortIdentity.snapshot(ports: ports)
        listeners = after
        for (port, result) in responses {
            let currentListeners = after[port] ?? []
            let stable = !currentListeners.isEmpty && Set(before[port] ?? []) == Set(currentListeners)
            reportedModels[port] = stable ? result.models : []
            modelCapabilities[port] = stable ? result.capabilities : [:]
            let native = currentListeners.contains { listener in listener.engineID == "ollama" || records.contains { spec in spec.engineID == "ollama" && listener.belongs(to: spec) } }
            if native && stable && result.ready { loadedModels[port] = await NativeModelAPI.loaded(port: port) }
            else { loadedModels[port] = nil }
            let managed = records.filter { $0.port == port && $0.pid != nil }
            for spec in managed {
                if let pid = spec.pid, !ownsProcess(spec, pid: pid) {
                    if let index = records.firstIndex(where: { $0.id == spec.id }) { records[index].pid = nil }; statuses[spec.id] = .stopped
                } else if statuses[spec.id] != .stopping {
                    let belongs = !currentListeners.isEmpty && currentListeners.allSatisfy { $0.belongs(to: spec) }
                    if belongs {
                        // Repair old metadata only from the verified process tree,
                        // never from a port number or model name.
                        if let actual = currentListeners.compactMap(\.engineID).first, actual != spec.engineID,
                           let index = records.firstIndex(where: { $0.id == spec.id }) { records[index].engineID = actual }
                        statuses[spec.id] = stable && result.ready ? .running : .starting
                        errors[spec.id] = nil
                    } else if !currentListeners.isEmpty {
                        statuses[spec.id] = .conflicted
                        errors[spec.id] = "端口 \(port) 正由 \(PortIdentity.name(currentListeners.first?.engineID)) 使用；当前服务未在此端口提供接口。请停止当前服务后改用空闲端口。"
                    } else { statuses[spec.id] = .starting }
                }
            }
            let stillManaged = records.contains { spec in spec.port == port && !currentListeners.isEmpty && currentListeners.allSatisfy { $0.belongs(to: spec) } }
            if result.alive && !stillManaged && !ignoredPorts.contains(port) {
                let listener = currentListeners.first
                let engineID = Set(currentListeners.compactMap(\.engineID)).count == 1 ? listener?.engineID : nil
                observed.append(ObservedService(port: port, engineName: PortIdentity.name(engineID), models: stable ? result.models : [], ready: stable && result.ready, statusCode: result.code, engineID: engineID, pid: listener?.pid, birth: listener?.birth))
            }
        }
        external = observed.sorted { $0.port < $1.port }; logRevision += 1; save()
    }
}

enum ChildExecutor {
    static func run(arguments: [String]) -> Never {
        guard !arguments.isEmpty else { exit(64) }
        // Foundation may already create a group whose leader is this child.
        // Otherwise create our own session before replacing the helper process.
        if getpgrp() != getpid() && setsid() < 0 { fputs("无法创建服务进程组\n", stderr); exit(70) }
        let pointers = arguments.map { strdup($0) } + [nil]
        pointers.withUnsafeBufferPointer { buffer in _ = execv(arguments[0], UnsafeMutablePointer(mutating: buffer.baseAddress!)) }
        fputs("无法运行引擎：\(String(cString: strerror(errno)))\n", stderr); exit(71)
    }
}
