import Foundation
import AppKit

/// 一条由 ModelDock 写进 pi / OpenCode 用户配置的模型登记（provider + model），来源是连接回执。
struct ClientRegistration: Hashable {
    var client: CodingClient
    var file: String
    var provider: String
    var model: String
}

/// 删除模型或卸载引擎时，找出并移除 ModelDock 曾写入客户端的登记，以及本工具私有的连接回执、启动脚本和隔离配置。
enum ClientRegistrationCleanup {
    struct Plan {
        var registrations: [ClientRegistration] = []
        var files: [URL] = []
        var isEmpty: Bool { registrations.isEmpty && files.isEmpty }
    }
    struct Scope {
        /// 被删除的服务配置 ID：回执的 sourceID（直连或经网关）命中即视为受影响。
        var sourceIDs: Set<String> = []
        /// 卸载引擎时的引擎 ID；直连该引擎（含外部服务）的回执受影响。
        var engineID: String? = nil
        /// 模型在接口中可能使用的名称；只用于来源已不存在、外部或 Ollama 共享服务的回执。
        var names: Set<String> = []
        /// 仍然存在、且按名称匹配不可靠的服务配置 ID。
        var strictSources: Set<String> = []
        /// 逐条判断回执是否失效（例如模型已不存在）。
        var receipt: ((ClientConnection) -> Bool)? = nil
    }

    static func receipts(root: URL) -> [(url: URL, connection: ClientConnection)] {
        let launchers = root.appendingPathComponent("launchers")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: launchers.path)) ?? []
        let latest = CodingClient.allCases.map { root.appendingPathComponent("latest-\($0.rawValue).json") }
        let urls = names.filter { $0.hasSuffix(".command.json") }.map { launchers.appendingPathComponent($0) } + latest
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url), let connection = try? JSONDecoder().decode(ClientConnection.self, from: data) else { return nil }
            return (url, connection)
        }
    }

    static func affected(_ connection: ClientConnection, scope: Scope) -> Bool {
        let service = connection.service
        if let source = service.sourceID, scope.sourceIDs.contains(source) { return true }
        if let engineID = scope.engineID, service.engineID == engineID { return true }
        if scope.receipt?(connection) == true { return true }
        guard !scope.names.isEmpty, !service.isRemote, !(service.sourceID.map(scope.strictSources.contains) ?? false) else { return false }
        // 网关别名是 "<前缀>/<原始名称>"，原始名称本身可能含 "/"。
        let raw = service.engineID == "gateway" ? (service.model.split(separator: "/", maxSplits: 1).last.map(String.init) ?? service.model) : service.model
        return scope.names.contains(service.model) || scope.names.contains(raw)
    }

    /// keepSources：继续存在的服务配置；它们仍在使用的登记不会被移除。
    static func plan(root: URL, scope: Scope, keepSources: Set<String>) -> Plan {
        var plan = Plan(), removed = Set<ClientRegistration>(), kept = Set<ClientRegistration>()
        let profiles = root.appendingPathComponent("profiles").standardizedFileURL.path + "/"
        for (url, connection) in receipts(root: root) {
            let registration = connection.registeredConfiguration.map { ClientRegistration(client: connection.client, file: $0, provider: connection.providerID, model: connection.model) }
            guard affected(connection, scope: scope) else {
                if let registration, connection.service.isRemote || connection.service.sourceID.map(keepSources.contains) == true { kept.insert(registration) }
                continue
            }
            if let registration { removed.insert(registration) }
            plan.files.append(url)
            if url.lastPathComponent.hasSuffix(".command.json") { plan.files.append(url.deletingPathExtension()) }
            // 隔离配置目录：pi/Hermes 为配置文件所在目录，OpenCode 为 profile/config/opencode/opencode.json 的上三级。
            var profile = URL(fileURLWithPath: connection.configuration).deletingLastPathComponent()
            if connection.client == .opencode { profile = profile.deletingLastPathComponent().deletingLastPathComponent() }
            if profile.standardizedFileURL.path.hasPrefix(profiles) { plan.files.append(profile) }
        }
        plan.registrations = removed.subtracting(kept).filter { $0.provider.hasPrefix("model-manager-") && [.pi, .opencode].contains($0.client) }
            .sorted { ($0.file, $0.provider, $0.model) < ($1.file, $1.provider, $1.model) }
        plan.files = Array(Set(plan.files.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        return plan
    }

    /// 从客户端配置中删除登记；文件按 register 相同的锁、备份和比对规则写入。返回实际移除的登记数。
    @discardableResult
    static func apply(_ plan: Plan, root: URL) throws -> Int {
        var count = 0
        for (key, group) in Dictionary(grouping: plan.registrations, by: { "\($0.client.rawValue)|\($0.file)" }).sorted(by: { $0.key < $1.key }) {
            let client = group[0].client, file = URL(fileURLWithPath: group[0].file)
            guard ["models.json", "opencode.json", "opencode.jsonc"].contains(file.lastPathComponent) else { throw LaunchError.message("客户端配置路径异常，已跳过：\(key)") }
            let configRoot = file.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try NativeClientConfig.transaction(configRoot: configRoot, client: client, root: root) { read in
                var updates: [URL: Data] = [:]
                var object = try read(file), changed = 0
                for entry in group { if try strip(&object, client: client, provider: entry.provider, model: entry.model) { changed += 1 } }
                if changed > 0 { updates[file] = try ConnectionFiles.json(object) }
                let settings = configRoot.appendingPathComponent("settings.json")
                if client == .pi, FileManager.default.fileExists(atPath: settings.path) {
                    var values = try read(settings), touched = false
                    for entry in group { if try stripPiSettings(&values, provider: entry.provider, model: entry.model) { touched = true } }
                    if touched { updates[settings] = try ConnectionFiles.json(values) }
                }
                count += changed
                return updates
            } done: { _, _ in }
        }
        // 本工具私有文件：回执、启动脚本和隔离配置目录。
        let base = root.standardizedFileURL.path + "/"
        for url in plan.files where url.standardizedFileURL.path.hasPrefix(base) && FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return count
    }

    /// 删除一个模型登记；provider 下没有模型时一并删除 provider，并清理指向它的默认模型。返回是否有改动。
    static func strip(_ object: inout [String: Any], client: CodingClient, provider: String, model: String) throws -> Bool {
        switch client {
        case .pi:
            var providers = try NativeClientConfig.dictionary(object, "providers")
            guard var own = providers[provider] as? [String: Any], let models = own["models"] as? [[String: Any]] else { return false }
            let remaining = models.filter { ($0["id"] as? String) != model }
            guard remaining.count != models.count else { return false }
            if remaining.isEmpty { providers[provider] = nil } else { own["models"] = remaining; providers[provider] = own }
            object["providers"] = providers
            return true
        case .opencode:
            var providers = try NativeClientConfig.dictionary(object, "provider")
            guard var own = providers[provider] as? [String: Any], var models = own["models"] as? [String: Any], models[model] != nil else { return false }
            models[model] = nil
            if models.isEmpty {
                providers[provider] = nil
                if let enabled = object["enabled_providers"] as? [String] { object["enabled_providers"] = enabled.filter { $0 != provider } }
            } else { own["models"] = models; providers[provider] = own }
            object["provider"] = providers
            for key in ["model", "small_model"] where object[key] as? String == provider + "/" + model { object[key] = nil }
            return true
        case .hermes: return false
        }
    }

    static func stripPiSettings(_ object: inout [String: Any], provider: String, model: String) throws -> Bool {
        var changed = false
        let key = provider + "/" + model
        var compaction = try NativeClientConfig.dictionary(object, "compaction")
        var overrides = try NativeClientConfig.dictionary(compaction, "modelOverrides")
        if overrides[key] != nil {
            overrides[key] = nil; changed = true
            if overrides.isEmpty { compaction["modelOverrides"] = nil } else { compaction["modelOverrides"] = overrides }
            object["compaction"] = compaction
        }
        if object["defaultProvider"] as? String == provider, object["defaultModel"] as? String == model {
            object["defaultProvider"] = nil; object["defaultModel"] = nil; changed = true
        }
        if let enabled = object["enabledModels"] as? [String], enabled.contains(key) { object["enabledModels"] = enabled.filter { $0 != key }; changed = true }
        return changed
    }
}

/// 删除模型 / 卸载引擎时一并移除的本工具状态。
struct RemovalCleanup {
    var services: [ServiceSpec] = []
    var clients = ClientRegistrationCleanup.Plan()
    var removedPath: String? = nil
    var modelID: String? = nil
    /// 要删除的测速记录 ID。
    var benchmarks: Set<String> = []
    /// 普通删除服务配置时保留运行日志。
    var keepLogs = false

    /// 确认弹窗中展示的清理摘要。
    var summary: String {
        var lines: [String] = []
        if !services.isEmpty { lines.append(L10n.text("\(services.count) 条服务配置及其日志")) }
        let clients = Set(clients.registrations.map(\.client.title)).sorted()
        if !clients.isEmpty { lines.append(L10n.text("\(clients.joined(separator: "、")) 中的 \(self.clients.registrations.count) 个模型登记")) }
        if !benchmarks.isEmpty { lines.append(L10n.text("\(benchmarks.count) 条测速记录")) }
        return lines.joined(separator: "\n")
    }
}

@MainActor extension AppStore {
    func removalCleanup(model: LocalModel, removedPath: String) -> RemovalCleanup {
        // Ollama 服务同时承载多个模型，保留其服务配置，只按模型名称清理登记。
        // 复用模型实例的匹配规则：按 ID、版本路径、Splash/Strata 预备组合识别属于此模型的服务。
        let owned = modelServices(model).filter { $0.engineID != "ollama" }
        var names: Set<String> = [model.path, removedPath]
        if let repository = model.repository { names.insert(repository); names.insert(OllamaModelManagement.canonical(repository)) }
        if let origin = ModelOrigin.read(model)?.repository { names.insert(origin) }
        let ownedIDs = Set(owned.map(\.id))
        let strict = Set(services.records.filter { !ownedIDs.contains($0.id) && $0.engineID != "ollama" }.map(\.id))
        let scope = ClientRegistrationCleanup.Scope(sourceIDs: ownedIDs, names: names, strictSources: strict)
        let keep = Set(services.records.map(\.id)).subtracting(ownedIDs)
        // 测速记录：按模型 ID（含 Splash 预备组合），未记录 ID 的按接口模型名称匹配。
        let modelIDs = Set([model.id] + model.preparedSplashModels.map(\.id))
        let aliases = Self.benchmarkNames([model] + model.preparedSplashModels)
        let benchmarks = performance.records.filter { record in
            record.target.modelID.map(modelIDs.contains) ?? Self.matches(record, aliases)
        }
        return .init(services: owned.filter { $0.pid == nil }, clients: ClientRegistrationCleanup.plan(root: connections.root, scope: scope, keepSources: keep), removedPath: removedPath, modelID: model.id, benchmarks: Set(benchmarks.map(\.id)))
    }

    /// 删除单个服务配置：一并移除它在 pi/OpenCode 中的接入登记和网关偏好。
    /// 模型文件已不存在时，日志和该服务的测速记录也一起移除。
    func removalCleanup(service spec: ServiceSpec) -> RemovalCleanup {
        let missing = serviceModelMissing(spec)
        let scope = ClientRegistrationCleanup.Scope(sourceIDs: [spec.id])
        let keep = Set(services.records.map(\.id)).subtracting([spec.id])
        let benchmarks = missing ? performance.records.filter { $0.target.id.hasPrefix(spec.id + ":") || (!spec.modelID.isEmpty && $0.target.modelID == spec.modelID) } : []
        return .init(services: [spec], clients: ClientRegistrationCleanup.plan(root: connections.root, scope: scope, keepSources: keep), benchmarks: Set(benchmarks.map(\.id)), keepLogs: !missing)
    }

    /// 失效的接入登记：回执记录的服务配置已不存在（外部服务和远程接口除外）。
    func refreshStaleRegistrations() {
        let ids = Set(services.records.map(\.id))
        // 同一端口、同一引擎重新建立的服务仍可使用原登记（provider 按端口命名），不算失效。
        let sources = Set(ClientRegistrationCleanup.receipts(root: connections.root).map(\.connection.service).filter { service in
            !(service.engineID != "gateway" && services.records.contains { $0.port == service.port && $0.engineID == service.engineID })
        }.compactMap(\.sourceID).filter { !ids.contains($0) && !$0.hasPrefix("external:") && !$0.hasPrefix("remote:") })
        var scope = ClientRegistrationCleanup.Scope(sourceIDs: sources)
        // 服务仍在、但登记的模型已删除：只在扫描完成后判断，且对本地文件型引擎生效。
        if inventory != nil, !scanning {
            let names = Self.benchmarkNames(models + models.flatMap(\.preparedSplashModels))
            let fileEngines: Set<String> = ["splash", "mlx", "llama", "prism", "strata"]
            let records = services.records, reported = services.reportedModels
            scope.receipt = { connection in
                let service = connection.service, lower = service.model.lowercased()
                let short = (service.model.hasPrefix("/") ? URL(fileURLWithPath: service.model).lastPathComponent : service.model).lowercased()
                guard fileEngines.contains(service.engineID), reported[service.port]?.contains(service.model) != true else { return false }
                if names.contains(lower) || names.contains(short) { return false }
                // 保守处理：同端口服务的模型名包含此名称时（如命令启动的 Splash 别名），视为仍在使用。
                return !records.contains { $0.port == service.port && ($0.modelName.lowercased().contains(short) || short.contains($0.modelName.lowercased())) }
            }
        }
        let plan = ClientRegistrationCleanup.plan(root: connections.root, scope: scope, keepSources: ids)
        staleRegistrations = plan.registrations.isEmpty ? .init() : plan
    }

    func removeStaleRegistrations() {
        let plan = staleRegistrations
        guard !plan.registrations.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.text("清理 \(plan.registrations.count) 个失效的接入登记？")
        alert.informativeText = plan.registrations.map { "\($0.client.title) · \($0.model)" }.joined(separator: "\n") + "\n\n" + L10n.text("对应的模型或服务配置已删除。只移除 ModelDock 写入的条目，原配置会先备份。")
        alert.addButton(withTitle: L10n.text("清理")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try ClientRegistrationCleanup.apply(plan, root: connections.root) } catch { message = error.localizedDescription }
        refreshStaleRegistrations()
    }

    /// 删除服务配置确认弹窗的说明。
    func serviceRemovalMessage(_ spec: ServiceSpec) -> String {
        let cleanup = removalCleanup(service: spec)
        var text = L10n.text(cleanup.keepLogs ? "保留模型文件和运行日志" : "模型文件已删除；将同时移除运行日志")
        let count = cleanup.clients.registrations.count
        if count > 0 { text += "\n" + L10n.text("同时移除 \(Set(cleanup.clients.registrations.map(\.client.title)).sorted().joined(separator: "、")) 中的 \(count) 个接入登记") }
        if !cleanup.benchmarks.isEmpty { text += "\n" + L10n.text("\(cleanup.benchmarks.count) 条测速记录") }
        return text
    }

    /// 服务记录的模型文件已不存在（模型已被删除）。命令启动、Ollama 等不记录模型路径的服务不判断。
    func serviceModelMissing(_ spec: ServiceSpec) -> Bool {
        guard spec.pid == nil, spec.modelPath.hasPrefix("/"), spec.engineID != "ollama" else { return false }
        return !FileManager.default.fileExists(atPath: spec.modelPath)
    }

    func removalCleanup(engineID: String) -> RemovalCleanup {
        let owned = services.records.filter { $0.engineID == engineID }
        let ownedIDs = Set(owned.map(\.id))
        let scope = ClientRegistrationCleanup.Scope(sourceIDs: ownedIDs, engineID: engineID)
        return .init(services: owned.filter { $0.pid == nil }, clients: ClientRegistrationCleanup.plan(root: connections.root, scope: scope, keepSources: Set(services.records.map(\.id)).subtracting(ownedIDs)),
            benchmarks: Set(performance.records.filter { $0.target.engineID == engineID }.map(\.id)))
    }

    /// 执行清理。单项失败不回滚已删除的模型文件，收集后返回给调用方提示。
    func applyRemovalCleanup(_ cleanup: RemovalCleanup) -> [String] {
        var failures: [String] = []
        let removedIDs = Set(cleanup.services.map(\.id))
        for spec in cleanup.services where services.records.contains(where: { $0.id == spec.id && $0.pid == nil }) {
            do {
                try services.removeConfiguration(spec)
                if !cleanup.keepLogs, UUID(uuidString: spec.id) != nil, FileManager.default.fileExists(atPath: services.logURL(spec.id).path) { try FileManager.default.trashItem(at: services.logURL(spec.id), resultingItemURL: nil) }
            } catch { failures.append(L10n.text("服务配置：") + error.localizedDescription) }
        }
        do { try ClientRegistrationCleanup.apply(cleanup.clients, root: connections.root) }
        catch { failures.append(L10n.text("客户端登记：") + error.localizedDescription) }
        // 网关中针对这些服务的偏好（别名、输入模式）。
        let preferences = gateway.settings.preferences.filter { key, _ in !removedIDs.contains(String(key.split(separator: "|").first ?? "")) }
        if preferences.count != gateway.settings.preferences.count {
            gateway.settings.preferences = preferences
            do { try gateway.save() } catch { failures.append(L10n.text("网关设置：") + error.localizedDescription) }
        }
        if !cleanup.benchmarks.isEmpty {
            do { try performance.remove { cleanup.benchmarks.contains($0.id) } } catch { failures.append(L10n.text("测速记录：") + error.localizedDescription) }
        }
        if let path = cleanup.removedPath { failures += forgetComponentReferences(path, modelID: cleanup.modelID) }
        synchronizeGateway()
        refreshStaleRegistrations()
        return failures
    }

    /// 模型可能出现在测速记录中的名称（小写）：ID、名称、路径、仓库、Splash 登记别名。
    nonisolated static func benchmarkNames(_ models: [LocalModel]) -> Set<String> {
        var names = Set<String>()
        for model in models {
            var values = [model.id, model.name, model.path, URL(fileURLWithPath: model.path).lastPathComponent, model.repository, ModelOrigin.read(model)?.repository]
            for registration in model.splashRegistrations ?? [] { values += [registration.id, registration.name] + registration.aliases.map(Optional.some) }
            names.formUnion(values.compactMap { $0?.lowercased() }.filter { !$0.isEmpty })
        }
        return names
    }
    nonisolated static func matches(_ record: BenchmarkResult, _ names: Set<String>) -> Bool {
        [record.target.apiModel, record.target.modelName].contains { value in
            let lower = value.lowercased()
            return names.contains(lower) || (value.hasPrefix("/") && names.contains(URL(fileURLWithPath: value).lastPathComponent.lowercased()))
        }
    }

    /// 模型已不在清单中的测速记录。未记录模型 ID 的，只判断来自本地模型文件的引擎，外部服务记录不计入。
    /// 扫描未完成时不判断，避免误报。
    var orphanedBenchmarks: [BenchmarkResult] {
        guard inventory != nil, !scanning else { return [] }
        let all = models + models.flatMap(\.preparedSplashModels)
        let known = Set(all.map(\.id)), names = Self.benchmarkNames(all)
        let fileEngines: Set<String> = ["splash", "mlx", "llama", "prism", "strata"]
        return performance.records.filter { record in
            if let id = record.target.modelID { return !known.contains(id) }
            return fileEngines.contains(record.target.engineID) && !Self.matches(record, names)
        }
    }

    func removeOrphanedBenchmarks() {
        let orphans = orphanedBenchmarks
        guard !orphans.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.text("清理 \(orphans.count) 条已删除模型的测速记录？")
        alert.informativeText = L10n.text("这些记录对应的模型已不在模型文件列表中。若模型位于暂未连接的磁盘，请先连接后再清理。")
        alert.addButton(withTitle: L10n.text("清理记录")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = Set(orphans.map(\.id))
        do { try performance.remove { ids.contains($0.id) } } catch { message = error.localizedDescription }
    }

    func removeBenchmark(_ result: BenchmarkResult) {
        do { try performance.remove { $0.id == result.id } } catch { message = error.localizedDescription }
    }

    /// 删除模型后，清除本模型的组件关联，以及其他模型和引擎默认设置中指向已删除文件的草稿、投影或 Strata 组合。
    private func forgetComponentReferences(_ removed: String, modelID: String?) -> [String] {
        var failures: [String] = []
        let resolved = URL(fileURLWithPath: removed).resolvingSymlinksInPath().path
        func gone(_ path: String?) -> Bool {
            guard let path, !path.isEmpty else { return false }
            return EngineMaintenance.contains(resolved, URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        var associations = modelAssociations
        if let modelID { associations[modelID] = nil }
        for (id, var value) in associations {
            if gone(value.draftPath) { value.draftPath = nil; if value.draftMode == .local { value.draftMode = .automatic } }
            if gone(value.projectorPath) { value.projectorPath = nil }
            if gone(value.strataAssembly) { value.strataAssembly = nil }
            associations[id] = value
        }
        if associations != modelAssociations {
            do {
                try JSONEncoder().encode(associations).write(to: services.stateDirectory.appendingPathComponent("model-associations.json"), options: .atomic)
                modelAssociations = associations
            } catch { failures.append(L10n.text("组件关联：") + error.localizedDescription) }
        }
        var configurations = engineConfigurations
        for (id, var value) in configurations where gone(value.draftPath) { value.draftPath = nil; configurations[id] = value }
        if configurations != engineConfigurations {
            do {
                try JSONEncoder().encode(configurations).write(to: services.stateDirectory.appendingPathComponent("engine-configurations.json"), options: .atomic)
                engineConfigurations = configurations
            } catch { failures.append(L10n.text("引擎设置：") + error.localizedDescription) }
        }
        return failures
    }
}
