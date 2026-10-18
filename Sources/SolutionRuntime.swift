import Foundation
import SwiftUI

enum SolutionComponentPhase {
    case ready, checking, starting, stopped, configuration, reload, sharedReload, failed
    var title: String {
        switch self {
        case .ready: return "方案可用"
        case .checking: return "正在检查服务"
        case .starting: return "正在启动"
        case .stopped: return "未启动"
        case .configuration: return "需修改配置"
        case .reload, .sharedReload: return "需更新组件"
        case .failed: return "启动失败"
        }
    }
}
struct SolutionComponentRuntime: Identifiable {
    var component: SolutionComponent
    var phase: SolutionComponentPhase
    var issue: String?
    var id: String { component.id }
}
struct SolutionRuntimeSnapshot {
    var components: [SolutionComponentRuntime]
    var ready: Int { components.filter { $0.phase == .ready }.count }
    var total: Int { components.count }
    var loading: Int { components.filter { [.checking, .starting].contains($0.phase) }.count }
    var issues: [String] { components.compactMap { entry in entry.issue.map { L10n.text(entry.component.role.rawValue) + " · " + L10n.text($0) } } }
    var needsConfiguration: Bool { components.contains { $0.phase == .configuration } }
    var needsReload: Bool { components.contains { [.reload, .sharedReload].contains($0.phase) } }
    var hasSharedReload: Bool { components.contains { $0.phase == .sharedReload } }
    var allReady: Bool { total > 0 && ready == total }
    var actionTitle: String { needsConfiguration ? "修改方案配置" : hasSharedReload ? "查看共享服务" : needsReload ? "更新组件并启动" : "检查并启动方案" }
    var title: String {
        if allReady { return L10n.format("全部组件已就绪 · {0} / {1}", [String(ready), String(total)]) }
        if !issues.isEmpty { return L10n.format("组件需要处理 · {0} / {1} 已就绪", [String(ready), String(total)]) }
        return L10n.format(loading > 0 ? "正在启动 · {0} / {1} 已就绪" : "尚未就绪 · {0} / {1}", [String(ready), String(total)])
    }
}

@MainActor struct SolutionRuntimeCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: SolutionController
    var record: SolutionDeployment
    private var snapshot: SolutionRuntimeSnapshot { controller.runtime(record, store: store) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: snapshot.title).font(.system(size: TypeScale.body, weight: .semibold))
                Spacer(minLength: 6)
                if controller.startingIDs.contains(record.id) { ProgressView().controlSize(.small) }
                Button(L10n.text("编辑配置")) { controller.edit(record.id, store: store) }.buttonStyle(.bordered).disabled(controller.startingIDs.contains(record.id) || controller.preparingID != nil || !controller.removingIDs.isEmpty)
            }
            ProgressView(value: Double(snapshot.ready), total: Double(max(1, snapshot.total))).tint(Theme.accent)
            ForEach(snapshot.components) { entry in
                let component = entry.component
                let spec = store.services.records.first { $0.id == component.serviceID }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: L10n.text(component.role.rawValue)).font(.system(size: TypeScale.callout, weight: .medium))
                            Text(verbatim: spec?.modelName ?? component.repository).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        StateLabel(title: entry.phase.title, color: entry.phase == .ready ? .green : entry.issue != nil ? .orange : .gray)
                        if let spec { Button(L10n.text("查看详情")) { store.showService(spec) }.buttonStyle(PlainAction()) }
                    }
                    if let issue = entry.issue {
                        Text(verbatim: L10n.text(issue)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).fixedSize(horizontal: false, vertical: true)
                        if let spec, store.services.status(spec) == .running {
                            Text(verbatim: L10n.text("服务正在运行，但尚不能用于此方案。" )).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                        }
                    } else if let spec, store.services.status(spec) == .starting {
                        Text(verbatim: L10n.text(store.services.startupProgress(spec).summary)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                    }
                }.padding(.vertical, 6).accessibilityIdentifier("solution-runtime-component-" + component.role.gatewayModel)
            }
            if let error = record.error, !snapshot.allReady, !snapshot.issues.contains(error) { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            if snapshot.allReady {
                Text(verbatim: L10n.text("组件接口已就绪。开始翻译后显示实际识别和翻译结果。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).background(Theme.selection.opacity(0.55), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("solution-runtime-status")
    }
}

@MainActor extension SolutionController {
    func runtime(_ record: SolutionDeployment, store: AppStore) -> SolutionRuntimeSnapshot {
        let roles = SolutionCatalog.all.first { $0.id == record.solutionID }?.roles(for: record.draft) ?? record.components.map(\.role)
        return .init(components: roles.map { role in
            let component = record.components.first { $0.role == role } ?? SolutionComponent(role: role, engineID: SolutionCatalog.engine(role), repository: "—", revision: "")
            return runtimeComponent(component, store: store, deploymentID: record.id)
        })
    }

    func runtimeComponent(_ component: SolutionComponent, store: AppStore, deploymentID: String) -> SolutionComponentRuntime {
        func value(_ phase: SolutionComponentPhase, _ issue: String? = nil) -> SolutionComponentRuntime { .init(component: component, phase: phase, issue: issue) }
        guard store.engineEnabled(component.engineID) else { return value(.configuration, "方案需要的基座已禁用，请在全局引擎设置中启用") }
        guard let model = store.models.first(where: { $0.id == component.modelID }), model.complete else { return value(.configuration, "所选模型已移动、不完整或基座已禁用，请重新选择") }
        if component.role == .text, let issue = TranslationLanguages.modelIssue(model) { return value(.configuration, issue) }
        guard let spec = store.services.records.first(where: { $0.id == component.serviceID }) else { return value(.configuration, "服务配置已缺失，请重新配置") }
        guard spec.engineID == component.engineID, model.matchesID(spec.modelID),
              ModelInstancePolicy.paths(model).contains(where: { ModelInstancePolicy.samePath(spec.modelPath, $0) }) else { return value(.configuration, "服务与方案模型不匹配，请重新配置") }
        switch store.services.status(spec) {
        case .running:
            if component.engineID == "audio" {
                guard audioProcessStarts[spec.id] == spec.processStart, let version = audioVersions[spec.id] else { return value(.checking) }
                if version < 2 {
                    if deployments.contains(where: { $0.id != deploymentID && $0.components.contains { $0.serviceID == spec.id } }) {
                        return value(.sharedReload, "共享语音服务需要更新，请在服务详情中停止并重新启动。更新会影响其他关联实例。")
                    }
                    return value(.reload, "语音组件需要重新加载")
                }
            }
            return value(.ready)
        case .starting, .stopping: return value(.starting)
        case .failed, .conflicted: return value(.failed, store.services.errors[spec.id] ?? store.services.statusTitle(spec))
        case .stopped: return value(.stopped)
        }
    }

    func selectDeployment(_ id: String, store: AppStore) {
        guard preparingID == nil, removingIDs.isEmpty, startingIDs.isEmpty, let record = deployments.first(where: { $0.id == id && $0.solutionID == selectedID }) else { return }
        store.solutionTrial.reset(); store.realtimeTranslation.cancel()
        selectedDeploymentID = record.id; editingID = nil; message = nil
    }

    func activate(_ record: SolutionDeployment, store: AppStore) {
        let state = runtime(record, store: store)
        if state.needsConfiguration { edit(record.id, store: store) }
        else if let entry = state.components.first(where: { $0.phase == .sharedReload }), let service = store.services.records.first(where: { $0.id == entry.component.serviceID }) { store.showService(service) }
        else { start(record.id, store: store) }
    }

    private func audioVersion(_ spec: ServiceSpec) async -> (version: Int, busy: Bool)? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(spec.port)/health")!); request.timeoutInterval = 3
        guard let (bytes, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        guard let pid = spec.pid, processStartTime(pid) == spec.processStart else { return nil }
        return (object["helper_version"] as? Int ?? 0, object["busy"] as? Bool ?? false)
    }

    func refreshAudioProtocols(store: AppStore) async {
        for spec in store.services.records where spec.engineID == "audio" && store.services.status(spec) == .running {
            if let value = await audioVersion(spec), store.services.records.first(where: { $0.id == spec.id })?.processStart == spec.processStart {
                let changed = audioProcessStarts[spec.id] != spec.processStart || audioVersions[spec.id] != value.version
                audioProcessStarts[spec.id] = spec.processStart
                if changed { audioVersions[spec.id] = value.version }
            } else if audioProcessStarts[spec.id] != spec.processStart { audioVersions[spec.id] = nil }

        }
    }

    func start(_ id: String, store: AppStore) {
        guard removingIDs.isEmpty, !startingIDs.contains(id), let record = deployments.first(where: { $0.id == id && $0.state == .configured }) else { return }
        startingIDs.insert(id); update(id) { $0.error = nil }
        startOperations[id] = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { startingIDs.remove(id); startOperations[id] = nil }
            await store.services.refresh()
            await refreshAudioProtocols(store: store)
            let initial = runtime(record, store: store)
            guard !initial.needsConfiguration, !initial.hasSharedReload else { update(id) { $0.error = initial.issues.joined(separator: "\n") }; return }
            var failures: [String] = []
            for entry in initial.components {
                let component = entry.component
                do {
                    try Task.checkCancellation()
                    guard let spec = store.services.records.first(where: { $0.id == component.serviceID }) else { throw LaunchError.message("服务配置已缺失，请重新配置") }
                    if component.role == .text, let model = store.models.first(where: { $0.id == component.modelID }), let issue = TranslationLanguages.modelIssue(model) { throw LaunchError.message(issue) }
                    guard store.engineEnabled(spec.engineID) else { throw LaunchError.message("方案需要的基座已禁用，请在全局引擎设置中启用") }
                    await store.services.refresh()
                    var current = store.services.records.first { $0.id == spec.id } ?? spec
                    if current.engineID == "audio", store.services.status(current) == .running {
                        guard let value = await audioVersion(current) else { throw LaunchError.message("无法读取语音服务状态，请查看服务详情") }
                        if value.version < 2 {
                            guard !value.busy else { throw LaunchError.message("语音服务正在处理请求，请稍后重试更新组件") }
                            try store.services.stop(current); try await store.services.waitForRelease(port: current.port)
                            current = store.services.records.first { $0.id == current.id } ?? current
                        }
                    }
                    if store.services.status(current) == .running { continue }
                    if store.services.status(current) == .stopping { try await store.services.waitForRelease(port: current.port); current = store.services.records.first { $0.id == current.id } ?? current }
                    if current.pid == nil {
                        // Configuration ownership stays unchanged. Only processes started by
                        // this explicit action are tracked for the solution's stop button.
                        let started = try store.startSaved(current)
                        if let pid = started.pid, let birth = started.processStart {
                            update(id) { $0.processes.removeAll { $0.serviceID == started.id }; $0.processes.append(.init(serviceID: started.id, pid: pid, birth: birth)) }
                        }
                        current = started
                    }
                    _ = try await store.services.waitForReady(current)
                } catch is CancellationError { return }
                catch { failures.append(L10n.text(component.role.rawValue) + " · " + error.localizedDescription) }
            }
            await refreshAudioProtocols(store: store)
            guard !Task.isCancelled else { return }
            if !failures.isEmpty { update(id) { $0.error = failures.joined(separator: "\n") }; return }
            let final = runtime(record, store: store)
            guard final.allReady else { update(id) { $0.error = final.issues.isEmpty ? "请先启动方案中的全部服务并等待就绪" : final.issues.joined(separator: "\n") }; return }
            store.synchronizeGateway()
            if !store.gateway.ownsProcess() { store.gateway.start(store: store) }
            for _ in 0..<80 {
                if store.gateway.ready && !store.gateway.busy { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            await store.gateway.poll()
            if let latest = deployments.first(where: { $0.id == id }), !store.gateway.solutionReady(latest) {
                update(id) { $0.error = store.gateway.error ?? "模型组件已启动，方案网关尚未就绪，请查看网关状态。" }
            } else if store.tab == .solutions && selectedID == record.solutionID {
                selectedDeploymentID = id; section = .overview
            }
        }
    }

    func edit(_ id: String, store: AppStore) {
        guard preparingID == nil, removingIDs.isEmpty, !startingIDs.contains(id), let record = deployments.first(where: { $0.id == id }) else { return }
        store.solutionTrial.reset()
        store.realtimeTranslation.cancel()
        selectedID = record.solutionID; selectedDeploymentID = id; editingID = id; section = .configuration
        var value = record.draft
        for component in record.components {
            guard let model = store.models.first(where: { $0.id == component.modelID }), component.role != .text || TranslationLanguages.modelIssue(model) == nil else { value.localChoices[component.role.rawValue] = nil; continue }
            value.localChoices[component.role.rawValue] = component.engineID + "\n" + model.id
        }
        drafts[selectedID] = value; message = nil; save()
    }

    func replaceConfiguration(_ id: String, components: [SolutionComponent], draft: SolutionDraft, store: AppStore, launchWhenReady: Bool) throws {
        guard let index = deployments.firstIndex(where: { $0.id == id }), !startingIDs.contains(id) else { throw LaunchError.message("请等待当前方案操作完成") }
        let before = deployments, old = deployments[index]
        var next = components.map { value in
            old.components.first { $0.role == value.role && $0.engineID == value.engineID && $0.modelID == value.modelID && $0.modelPath == value.modelPath && value.modelID != nil } ?? value
        }
        for previous in old.components where !next.contains(where: { $0.serviceID != nil && $0.serviceID == previous.serviceID }) {
            guard let sid = previous.serviceID,
                  let other = deployments.firstIndex(where: { $0.id != id && $0.components.contains { $0.serviceID == sid } }),
                  let part = deployments[other].components.firstIndex(where: { $0.serviceID == sid }) else { continue }
            if previous.ownsConfiguration { deployments[other].components[part].ownsConfiguration = true }
            if let process = old.processes.first(where: { $0.serviceID == sid }), !deployments[other].processes.contains(where: { $0.serviceID == sid }) { deployments[other].processes.append(process) }
        }
        // Unchanged components keep their service bindings and download ownership.
        for offset in next.indices where next[offset].downloadID == nil {
            if let previous = old.components.first(where: { $0.role == next[offset].role && $0.repository == next[offset].repository && $0.revision == next[offset].revision && next[offset].modelPath == nil }) { next[offset] = previous }
        }
        deployments[index].draft = draft; deployments[index].components = next
        deployments[index].processes = old.processes.filter { process in next.contains { $0.serviceID == process.serviceID } }
        deployments[index].state = .preparing; deployments[index].stage = "正在检查方案…"; deployments[index].error = nil; deployments[index].progress = nil
        guard save() else { deployments = before; throw LaunchError.message("方案配置保存失败") }
        editingID = nil
        if launchWhenReady { autoStartRequests.insert(id) }
        perform(id, store: store)
    }
}
