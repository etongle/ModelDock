import AppKit
import Foundation

extension AppDelegate {
    @MainActor
    func restoreSplashService() async {
        let reportURL = argumentValue("--restore-report").map { URL(fileURLWithPath: $0) }
        var created: ServiceSpec?
        do {
            for _ in 0..<160 {
                if store.inventory != nil && !store.scanning { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let engine = store.engines.first(where: { $0.kind == .splash }),
                  let saved = store.services.records.filter({ $0.engineID == "splash" }).sorted(by: { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }).first,
                  let model = store.models.first(where: { $0.id == saved.modelID || $0.path == saved.modelPath }) else { throw LaunchError.message("未找到保存的 Splash 服务与现有模型") }
            await store.services.refresh()
            guard !NetworkProbe.portOccupied(saved.port) else { throw LaunchError.message("保存的端口已有服务，请在模型服务中检查") }
            store.selectedModels[engine.id] = model.id; store.chooseEngine(engine.id)
            store.port = String(saved.port); store.context = saved.context; store.tab = .services; store.selectedExternal = nil
            let spec = try store.services.start(engine: engine, model: model, port: saved.port, context: saved.context)
            created = spec; store.selectedServiceID = spec.id
            var ready = false
            for _ in 0..<120 {
                await store.services.refresh()
                if store.services.status(spec) == .running { ready = true; break }
                if store.services.status(spec) == .failed { throw LaunchError.message("引擎已退出，请查看运行日志") }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard ready else { throw LaunchError.message("Splash 尚未就绪，请查看运行日志") }
            let apiModel = store.services.reportedModels[spec.port]?.first ?? model.repository ?? model.name
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(spec.port)/v1/chat/completions")!)
            request.httpMethod = "POST"; request.timeoutInterval = 45; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": apiModel, "messages": [["role": "user", "content": "Reply with OK."]], "max_tokens": 8, "temperature": 0, "reasoning_effort": "none"])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]], !choices.isEmpty else { throw LaunchError.message("服务已启动，但推理验证失败") }
            let proof: [String: Any] = ["result": "passed", "installed_splash": engine.version, "running_splash": spec.engineVersion ?? engine.version, "executable": spec.engineExecutable ?? "", "model": model.name, "port": spec.port, "pid": spec.pid ?? 0, "birth": spec.processStart ?? 0, "http": 200, "inference": json, "left_running": true, "weights_downloaded": false, "weights_removed": false]
            if let reportURL { try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic) }
        } catch {
            if let created, store.services.status(created) != .running { try? store.services.stop(created) }
            store.message = "恢复 Splash 服务失败：" + error.localizedDescription
            if let reportURL {
                let proof: [String: Any] = ["result": "failed", "error": error.localizedDescription, "log": created.map { store.services.log($0.id) } ?? ""]
                try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            }
        }
    }
}
