import Foundation

struct SolutionCleanupSelection {
    var services = Set<String>()
    var models = Set<String>()
    var engines = Set<String>()
    var count: Int { services.count + models.count + engines.count }
}
struct SolutionCleanupModel: Identifiable {
    var model: LocalModel
    var path: URL
    var resolved: URL
    var identity: FileIdentity?
    var issue: String?
    var id: String { model.id }
}
struct SolutionCleanupPlan {
    var record: SolutionDeployment
    var models: [SolutionCleanupModel]
    var engines: [MaintenancePlan]
}

@MainActor extension SolutionController {
    func cleanupPlan(_ record: SolutionDeployment, store: AppStore) async -> SolutionCleanupPlan {
        var seen = Set<String>()
        let models = record.components.compactMap { component -> SolutionCleanupModel? in
            guard let model = store.models.first(where: { $0.matchesID(component.modelID ?? "") || $0.path == component.modelPath }), seen.insert(model.id).inserted else { return nil }
            // Remove only this exact revision/file, never its repository, cache or blob root.
            let path = URL(fileURLWithPath: model.path).standardizedFileURL
            var narrow = model; narrow.removalPath = path.path
            let issue: String?
            do {
                _ = try ModelFileSafety.removalURL(narrow, models: store.models, roots: store.inventory?.roots ?? [])
                issue = model.format == "Ollama" ? "Ollama 共享层请在模型文件页单独管理" : nil
            } catch { issue = error.localizedDescription }
            return .init(model: model, path: path, resolved: path.resolvingSymlinksInPath(), identity: FileIdentity.read(path.path), issue: issue)
        }
        var engines: [MaintenancePlan] = []
        if let inventory = store.inventory {
            for id in Set(record.components.map(\.engineID)).sorted() {
                guard let engine = store.engines.first(where: { $0.id == id }), engine.installed else { continue }
                let plan = await makeCleanupEnginePlan(engine, inventory: inventory)
                engines.append(plan)
            }
        }
        return .init(record: record, models: models, engines: engines)
    }

    func makeCleanupEnginePlan(_ engine: Engine, inventory: Inventory) async -> MaintenancePlan {
        if let cleanupEnginePlanner { return await cleanupEnginePlanner(engine, inventory) }
        return await Task.detached { EngineMaintenance.plan(engine: engine, mode: .uninstall, inventory: inventory) }.value
    }

    static func cleanupPrograms(_ plan: MaintenancePlan) -> [RemovalItem] {
        EngineMaintenance.normalized(plan.items.filter { [.package, .executable].contains($0.group) })
    }

    func cleanupServiceBlocker(_ id: String, record: SolutionDeployment, store: AppStore) -> String? {
        guard let item = removalItems(record, store: store).first(where: { $0.id == id }) else { return "服务配置已变化，请重新打开清理页" }
        switch item.action {
        case .shared: return "其他实例仍在使用，不能一并清理"
        case .native: return "复用的原生服务保留，请在模型服务页单独管理"
        case .remove: return nil
        }
    }

    func cleanupModelBlocker(_ item: SolutionCleanupModel, record: SolutionDeployment, selection: SolutionCleanupSelection, store: AppStore) -> String? {
        if let issue = item.issue { return issue }
        guard let identity = item.identity, FileIdentity.read(item.path.path) == identity,
              item.path.resolvingSymlinksInPath() == item.resolved else { return "模型文件已变化，请重新打开清理页" }
        if !ModelFileSafety.dependencies(item.model, removal: item.path, models: store.models).isEmpty { return "其他模型仍引用此文件或配套组件，不能一并清理" }
        let paths = ModelInstancePolicy.paths(item.model) + [item.path.path]
        func overlaps(_ value: String) -> Bool { paths.contains { DownloadController.overlaps($0, value) } }
        if deployments.contains(where: { other in other.id != record.id && other.components.contains { $0.modelID == item.model.id || $0.modelPath.map(overlaps) == true } }) { return "其他实例仍引用此模型，不能一并清理" }
        let retained = store.services.records.filter { !selection.services.contains($0.id) }
        if ModelFileSafety.used(item.model, removal: item.path, services: retained, external: store.services.external, models: store.models, includingStopped: true) {
            let optionalServices = Set(removalItems(record, store: store).filter { $0.action == .remove }.map(\.id))
            if ModelFileSafety.used(item.model, removal: item.path, services: retained.filter { !optionalServices.contains($0.id) }, external: store.services.external, models: store.models, includingStopped: true) {
                return "其他服务仍引用此模型，不能一并清理"
            }
            return "保留的服务仍引用此模型；需先勾选相应的独占服务配置"
        }
        if store.models.contains(where: { other in
            guard other.id != item.model.id else { return false }
            let references = ModelInstancePolicy.paths(other) + [other.association?.draftPath, other.association?.projectorPath, other.association?.strataAssembly].compactMap { $0 }
            return references.contains(where: overlaps)
        }) { return "其他模型仍引用此文件或配套组件，不能一并清理" }
        if store.engineConfigurations.values.compactMap(\.draftPath).contains(where: overlaps) { return "基座配置仍引用此配套模型，不能一并清理" }
        if paths.contains(where: { store.strata.uses($0) }) { return "此模型正在准备配套组件，请等待完成" }
        if store.downloads.jobs.contains(where: { job in
            job.state != .complete && (overlaps(job.displayLocation) || job.repairTarget.map(overlaps) == true)
        }) { return "下载或续传任务仍在使用此位置，不能一并清理" }
        return nil
    }

    func cleanupEngineBlocker(_ plan: MaintenancePlan, record: SolutionDeployment, selection: SolutionCleanupSelection, store: AppStore) -> String? {
        if let blocker = plan.blockers.first { return blocker }
        guard !Self.cleanupPrograms(plan).isEmpty else { return "未找到可独立卸载的程序，请在运行引擎页管理" }
        if deployments.contains(where: { $0.id != record.id && $0.components.contains { $0.engineID == plan.engine.id } }) { return "其他实例仍需要此基座，不能一并清理" }
        if store.services.records.contains(where: { $0.engineID == plan.engine.id && !selection.services.contains($0.id) }) { return "保留的服务配置仍需要此基座，不能一并清理" }
        if store.services.external.contains(where: { $0.engineID == plan.engine.id }) { return "本机外部服务仍在使用此基座，不能一并清理" }
        if store.installation.running || store.maintaining || (plan.engine.kind == .strata && store.strata.busy) { return "基座正在安装、维护或准备模型，请稍后重试" }
        if !EngineMaintenance.downloadBlockers(Self.cleanupPrograms(plan), jobs: store.downloads.jobs).isEmpty { return "下载任务仍在使用此基座目录，不能一并清理" }
        return nil
    }

    func validateCleanup(_ plan: SolutionCleanupPlan, selection: SolutionCleanupSelection, store: AppStore) throws {
        guard let record = deployments.first(where: { $0.id == plan.record.id }) else { throw LaunchError.message("方案实例已移除，请刷新列表") }
        func stamp(_ value: SolutionDeployment) -> [String] { value.components.map { [$0.id, $0.engineID, $0.modelID ?? "", $0.modelPath ?? "", $0.serviceID ?? ""].joined(separator: "\n") }.sorted() }
        guard stamp(record) == stamp(plan.record) else { throw LaunchError.message("清理范围已变化，请重新确认") }
        let models = Set(plan.models.map(\.id)), engines = Set(plan.engines.map { $0.engine.id })
        guard selection.models.isSubset(of: models), selection.engines.isSubset(of: engines) else { throw LaunchError.message("清理范围已变化，请重新确认") }
        for id in selection.services {
            if let issue = cleanupServiceBlocker(id, record: record, store: store) { throw LaunchError.message(issue) }
        }
        for item in plan.models where selection.models.contains(item.id) {
            if let issue = cleanupModelBlocker(item, record: record, selection: selection, store: store) { throw LaunchError.message(issue) }
        }
        for item in plan.engines where selection.engines.contains(item.engine.id) {
            if let issue = cleanupEngineBlocker(item, record: record, selection: selection, store: store) { throw LaunchError.message(issue) }
        }
    }

    func trashCleanupResource(_ path: URL) async throws {
        if let cleanupTrash { try await cleanupTrash(path); return }
        try await Task.detached { try FileManager.default.trashItem(at: path, resultingItemURL: nil) }.value
    }

    func cleanEnginePrograms(_ original: MaintenancePlan, store: AppStore) async throws {
        guard let inventory = store.inventory else { throw LaunchError.message("请先扫描本地模型与基座") }
        let fresh = await makeCleanupEnginePlan(original.engine, inventory: inventory)
        let items = Self.cleanupPrograms(original)
        guard !store.services.records.contains(where: { $0.engineID == original.engine.id }),
              !deployments.contains(where: { $0.components.contains { $0.engineID == original.engine.id } }),
              !store.services.external.contains(where: { $0.engineID == original.engine.id }) else { throw LaunchError.message("基座已被新增服务或实例引用，已保留") }
        let blocked = store.maintenanceBlockers(fresh, selectedIDs: Set(items.map(\.id)))
        guard blocked.isEmpty else { throw LaunchError.message(blocked.joined(separator: "\n")) }
        try EngineMaintenance.validate(items, original: original, fresh: fresh)
        for item in items {
            if let formula = item.formula {
                let args = ["uninstall"] + (item.cask ? ["--cask"] : ["--formula"]) + [formula]
                _ = try await Task.detached { try EngineMaintenance.command(EnginePaths.brew ?? "/opt/homebrew/bin/brew", args) }.value
            } else {
                guard FileIdentity.read(item.path) == item.identity,
                      !EngineMaintenance.protected(item.path, inventory: inventory), !EngineMaintenance.untrackedWeights(item.path) else { throw LaunchError.message("程序目录包含模型或归属已变化，已保留") }
                try await trashCleanupResource(URL(fileURLWithPath: item.path))
            }
        }
    }
}
