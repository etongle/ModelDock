import Foundation
import SwiftUI

struct SolutionRemovalItem: Identifiable {
    enum Action { case remove, shared, native }
    var service: ServiceSpec
    var action: Action
    var id: String { service.id }
    var title: String {
        switch action {
        case .remove: return "停止并移除 · 此实例独占创建"
        case .shared: return "保留 · 其他实例仍在使用"
        case .native: return "保留 · 复用的原生服务"
        }
    }
}

@MainActor extension SolutionController {
    func removalItems(_ record: SolutionDeployment, store: AppStore) -> [SolutionRemovalItem] {
        services(record, store: store).map { service in
            let shared = deployments.contains { $0.id != record.id && $0.components.contains { $0.serviceID == service.id } }
            let owned = record.components.contains { $0.serviceID == service.id && $0.ownsConfiguration }
            return .init(service: service, action: shared ? .shared : owned ? .remove : .native)
        }
    }

    func stoppableServices(_ record: SolutionDeployment, store: AppStore) -> [ServiceSpec] {
        services(record, store: store).filter { service in
            record.processes.contains { $0.serviceID == service.id && $0.pid == service.pid && $0.birth == service.processStart } &&
            !deployments.contains { $0.id != record.id && $0.components.contains { $0.serviceID == service.id } }
        }
    }

    @discardableResult
    func removeInstance(_ id: String, store: AppStore, plan supplied: SolutionCleanupPlan? = nil, selection: SolutionCleanupSelection = .init()) -> Bool {
        guard removingIDs.isEmpty, preparingID == nil, startingIDs.isEmpty, !store.maintaining, !store.installation.running,
              let record = deployments.first(where: { $0.id == id }) else { return false }
        let plan = supplied ?? SolutionCleanupPlan(record: record, models: [], engines: [])
        guard plan.record.id == id else { message = "清理范围已变化，请重新确认"; return false }
        do { try validateCleanup(plan, selection: selection, store: store) }
        catch { message = error.localizedDescription; return false }
        removingIDs.insert(id); message = nil
        if selectedDeploymentID == id || latest?.id == id { store.solutionTrial.reset(); store.realtimeTranslation.cancel() }
        Task { [weak self, weak store] in
            guard let self, let store else { return }
            var reserved = false
            defer {
                store.services.resourceCleanupInProgress = false
                if reserved { store.downloads.releaseCleanupPaths() }
                removingIDs.remove(id)
            }
            do {
                await store.services.refresh()
                try validateCleanup(plan, selection: selection, store: store)
                let paths = Set(plan.models.filter { selection.models.contains($0.id) }.map { $0.path.path } + plan.engines.filter { selection.engines.contains($0.engine.id) }.flatMap { Self.cleanupPrograms($0).map(\.path) })
                try store.downloads.reserveCleanupPaths(paths); reserved = true
                store.services.resourceCleanupInProgress = true
                for id in selection.services {
                    guard let service = store.services.records.first(where: { $0.id == id }) else { throw LaunchError.message("服务配置已变化，请重新打开清理页") }
                    if service.pid != nil { try store.services.stop(service); try await store.services.waitForRelease(port: service.port) }
                }
                await store.services.refresh()
                try validateCleanup(plan, selection: selection, store: store)
                remove(id, store: store, serviceIDs: selection.services)
                guard !deployments.contains(where: { $0.id == id }) else { return }
                var failures: [String] = []
                for item in plan.models where selection.models.contains(item.id) {
                    do {
                        await store.services.refresh()
                        if let issue = cleanupModelBlocker(item, record: record, selection: selection, store: store) { throw LaunchError.message(issue) }
                        try await trashCleanupResource(item.path)
                        store.downloads.noteRemovedModelFiles(item.path.path)
                    } catch { failures.append(item.model.name + " · " + error.localizedDescription) }
                }
                for engine in plan.engines where selection.engines.contains(engine.engine.id) {
                    do {
                        await store.services.refresh()
                        if let issue = cleanupEngineBlocker(engine, record: record, selection: selection, store: store) { throw LaunchError.message(issue) }
                        store.maintaining = true; store.maintenanceEngineID = engine.engine.id
                        defer { store.maintaining = false }
                        try await cleanEnginePrograms(engine, store: store)
                    } catch { failures.append(engine.engine.name + " · " + error.localizedDescription) }
                }
                if !failures.isEmpty { message = L10n.text("实例已删除，以下可选清理未完成，相关资源已保留：") + "\n" + failures.joined(separator: "\n") }
                store.synchronizeGateway()
                if !selection.models.isEmpty || !selection.engines.isEmpty { store.scan() }
            } catch { message = error.localizedDescription }
        }
        return true
    }
}
