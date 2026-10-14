import Foundation
import AppKit

extension ConnectionController {
    func canExpandContext(store: AppStore, port: Int) -> Bool {
        store.services.records.contains { spec in
            spec.port == port && spec.pid != nil && store.services.status(spec) == .running &&
                ["splash", "llama", "prism", "ollama"].contains(spec.engineID)
        } && !store.maintaining && !store.installation.running && !store.scanning
    }
    func requestContextExpansion(store: AppStore, port: Int) {
        guard !busy, canExpandContext(store: store, port: port),
              let spec = store.services.records.first(where: { $0.port == port && $0.pid != nil }) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.text("将 \(spec.modelName) 扩展至 32K 上下文？")
        alert.informativeText = L10n.text("端口 \(port) 的这个模型服务会短暂重启；其他服务继续运行。扩大上下文会增加长对话的内存使用。原会话请关闭后重新接入。")
        alert.addButton(withTitle: L10n.text("扩展并重启")); alert.addButton(withTitle: L10n.text("取消"))
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { _ = try await expandContext(store: store, port: port, context: 32768); message = "服务已扩展至 32K，请重新接入客户端。"; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func waitForRelease(_ services: ServiceController, port: Int) async throws {
        for _ in 0..<48 {
            await services.refresh()
            if !NetworkProbe.portOccupied(port), !services.portReserved(port) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LaunchError.message("服务端口尚未释放，已停止后续操作。请查看服务状态。")
    }
    private func waitForReady(_ services: ServiceController, spec: ServiceSpec) async throws -> ServiceSpec {
        for _ in 0..<120 {
            await services.refresh()
            if services.status(spec) == .running, let current = services.records.first(where: { $0.id == spec.id }) { return current }
            if [.failed, .conflicted].contains(services.status(spec)) { throw LaunchError.message(services.errors[spec.id] ?? "引擎启动失败，请查看运行日志。") }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LaunchError.message("服务启动超时，请查看运行日志。")
    }
    @discardableResult func expandContext(store: AppStore, port: Int, context: Int) async throws -> ServiceSpec {
        guard !busy, canExpandContext(store: store, port: port),
              let saved = store.services.records.first(where: { $0.port == port && $0.pid != nil }),
              let engine = store.engines.first(where: { $0.id == saved.engineID }) else { throw LaunchError.message("当前服务无法自动调整上下文，请在原应用中配置。") }
        guard (32768...262144).contains(context), context > saved.context else { throw LaunchError.message("新的上下文长度无效。") }
        let model = store.models.first { $0.id == saved.modelID || $0.path == saved.modelPath }
        guard model != nil || engine.kind == .ollama else { throw LaunchError.message("未找到服务使用的模型文件。") }
        // Build both plans before stopping anything; missing runtimes or incompatible models fail without downtime.
        _ = try LaunchBuilder.plan(engine: engine, model: model, port: port, context: context, maximumLoadedModels: saved.maximumLoadedModels ?? 3, inputMode: saved.inputMode ?? .automatic, projectorPath: saved.projectorPath)
        _ = try LaunchBuilder.plan(engine: engine, model: model, port: port, context: saved.context, maximumLoadedModels: saved.maximumLoadedModels ?? 3, inputMode: saved.inputMode ?? .automatic, projectorPath: saved.projectorPath)
        busy = true; error = nil; message = "正在扩展上下文并重新启动这个服务…"
        defer { busy = false }
        await store.services.refresh()
        guard let current = store.services.records.first(where: { $0.id == saved.id }),
              current.pid == saved.pid, current.processStart == saved.processStart, store.services.status(current) == .running else {
            throw LaunchError.message("服务进程已经改变，未执行重启。")
        }
        try store.services.stop(current)
        try await waitForRelease(store.services, port: port)
        var replacement: ServiceSpec?
        do {
            let spec = try store.services.start(engine: engine, model: model, port: port, context: context, maximumLoadedModels: saved.maximumLoadedModels ?? 3, inputMode: saved.inputMode ?? .automatic, projectorPath: saved.projectorPath)
            replacement = spec
            let ready = try await waitForReady(store.services, spec: spec)
            if let target = store.connectionTargets.first(where: { $0.port == port }) { modelID = target.id; self.context = context }
            lastConnection = nil
            if store.parsedPort == port { store.context = context }
            return ready
        } catch {
            let failure = error.localizedDescription
            do {
                await store.services.refresh()
                if let replacement, let current = store.services.records.first(where: { $0.id == replacement.id }), current.pid != nil {
                    try store.services.stop(current); try await waitForRelease(store.services, port: port)
                }
                guard !NetworkProbe.portOccupied(port), !store.services.portReserved(port) else { throw LaunchError.message("端口已被占用") }
                let fallback = try store.services.start(engine: engine, model: model, port: port, context: saved.context, maximumLoadedModels: saved.maximumLoadedModels ?? 3, inputMode: saved.inputMode ?? .automatic, projectorPath: saved.projectorPath)
                _ = try await waitForReady(store.services, spec: fallback)
                throw LaunchError.message("扩展失败，已恢复原来的 \(saved.context) 上下文服务：\(failure)")
            } catch LaunchError.message(let text) where text.contains("已恢复原来的") { throw LaunchError.message(text) }
            catch { throw LaunchError.message("扩展失败，自动恢复也未成功，请查看日志并重新启动服务：\(failure)；\(error.localizedDescription)") }
        }
    }
}
