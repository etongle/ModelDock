import Foundation
import SwiftUI

struct SolutionRuntimeSnapshot {
    var ready: Int; var total: Int; var loading: Int; var issues: [String]
    var allReady: Bool { total > 0 && ready == total && issues.isEmpty }
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
                Button(L10n.text("编辑配置")) { controller.edit(record.id, store: store) }.buttonStyle(.bordered).disabled(controller.startingIDs.contains(record.id))
            }
            ProgressView(value: Double(snapshot.ready), total: Double(max(1, snapshot.total))).tint(Theme.accent)
            ForEach(record.components) { component in
                if let spec = store.services.records.first(where: { $0.id == component.serviceID }) {
                    HStack {
                        Text(verbatim: L10n.text(component.role.rawValue)).font(.system(size: TypeScale.callout, weight: .medium))
                        Text(verbatim: spec.modelName).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(1)
                        Spacer(minLength: 4)
                        StateLabel(title: store.services.statusTitle(spec), color: store.services.status(spec).color)
                        Button(L10n.text("查看详情")) { store.showService(spec) }.buttonStyle(PlainAction())
                    }
                    if store.services.status(spec) == .starting {
                        let progress = store.services.startupProgress(spec)
                        Text(verbatim: L10n.text(progress.summary)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                    }
                }
            }
            ForEach(Array(snapshot.issues.enumerated()), id: \.offset) { _, issue in Text(verbatim: L10n.text(issue)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            if let error = record.error, !snapshot.allReady { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            if snapshot.allReady {
                Text(verbatim: L10n.text("组件接口已就绪。开始翻译后显示实际识别和翻译结果。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).background(Theme.selection.opacity(0.55), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("solution-runtime-status")
    }
}

@MainActor extension SolutionController {
    func runtime(_ record: SolutionDeployment, store: AppStore) -> SolutionRuntimeSnapshot {
        var result = SolutionRuntimeSnapshot(ready: 0, total: record.components.count, loading: 0, issues: [])
        for component in record.components {
            if component.role == .text, let model = store.models.first(where: { $0.id == component.modelID }), let issue = TranslationLanguages.modelIssue(model) { result.issues.append(issue); continue }
            guard let spec = store.services.records.first(where: { $0.id == component.serviceID }) else {
                if record.state == .configured { result.issues.append(L10n.text(component.role.rawValue) + " · " + L10n.text("服务配置已缺失，请重新配置")) }
                continue
            }
            switch store.services.status(spec) {
            case .running:
                if component.engineID == "audio", let version = audioVersions[spec.id], version < 2 { result.issues.append(L10n.text(component.role.rawValue) + " · " + L10n.text("语音组件需要重新加载")) }
                else { result.ready += 1 }
            case .starting, .stopping: result.loading += 1
            case .failed, .conflicted: result.issues.append(L10n.text(component.role.rawValue) + " · " + L10n.text(store.services.errors[spec.id] ?? store.services.statusTitle(spec)))
            case .stopped: break
            }
        }
        return result
    }

    private func audioVersion(_ spec: ServiceSpec) async -> (version: Int, busy: Bool)? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(spec.port)/health")!); request.timeoutInterval = 3
        guard let (bytes, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return (object["helper_version"] as? Int ?? 0, object["busy"] as? Bool ?? false)
    }

    func refreshAudioProtocols(store: AppStore) async {
        for spec in store.services.records where spec.engineID == "audio" && store.services.status(spec) == .running {
            if let value = await audioVersion(spec) { audioVersions[spec.id] = value.version }
        }
    }

    func start(_ id: String, store: AppStore) {
        guard !startingIDs.contains(id), let record = deployments.first(where: { $0.id == id && $0.state == .configured }), !record.components.isEmpty else { return }
        startingIDs.insert(id); update(id) { $0.error = nil }
        startOperations[id] = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { startingIDs.remove(id); startOperations[id] = nil }
            var failures: [String] = []
            for component in record.components {
                do {
                    try Task.checkCancellation()
                    guard let spec = store.services.records.first(where: { $0.id == component.serviceID }) else { throw LaunchError.message("服务配置已缺失，请重新配置") }
                    if component.role == .text, let model = store.models.first(where: { $0.id == component.modelID }), let issue = TranslationLanguages.modelIssue(model) { throw LaunchError.message(issue) }
                    guard store.engineEnabled(spec.engineID) else { throw LaunchError.message("方案需要的基座已禁用，请在全局引擎设置中启用") }
                    await store.services.refresh()
                    var current = store.services.records.first { $0.id == spec.id } ?? spec
                    if current.engineID == "audio", store.services.status(current) == .running, let value = await audioVersion(current), value.version < 2 {
                        guard !value.busy else { throw LaunchError.message("语音服务正在处理请求，请稍后重试更新组件") }
                        try store.services.stop(current); try await store.services.waitForRelease(port: current.port)
                        current = store.services.records.first { $0.id == current.id } ?? current
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
        guard preparingID == nil, !startingIDs.contains(id), let record = deployments.first(where: { $0.id == id }) else { return }
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
