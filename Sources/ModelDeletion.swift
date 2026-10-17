import Foundation
import AppKit
import CryptoKit

struct OllamaModelTarget {
    var port: Int
    var listeners: [PortListener]
    var name: String
    var digest: String
    var manifest: URL
}

enum OllamaModelManagement {
    static func canonical(_ name: String) -> String {
        (name.split(separator: "/").last?.contains(":") == true ? name : name + ":latest").lowercased()
    }
    static func request(port: Int, path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!); request.timeoutInterval = 15; request.httpMethod = method
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, object["error"] == nil else { throw LaunchError.message(object["error"] as? String ?? "Ollama 模型管理请求失败") }
        return object
    }
    @MainActor static func validate(_ target: OllamaModelTarget, services: ServiceController) throws {
        guard services.identifies(engineID: "ollama", port: target.port), Set(services.listeners[target.port] ?? []) == Set(target.listeners),
              target.listeners.allSatisfy({ processStartTime($0.pid) == $0.birth }) else { throw LaunchError.message("Ollama 服务已变化，请重新操作") }
        let data = try Data(contentsOf: target.manifest)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == target.digest else { throw LaunchError.message("模型登记文件已变化，请重新扫描") }
    }
    @MainActor static func target(_ model: LocalModel, services: ServiceController) async throws -> OllamaModelTarget {
        guard model.format == "Ollama", let root = ModelFileCatalog.ollamaRoot(URL(fileURLWithPath: model.path)), let name = model.repository else { throw LaunchError.message("模型不是有效的 Ollama 登记格式") }
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: model.path))).map { String(format: "%02x", $0) }.joined()
        let ports = services.listeners.keys.sorted().filter { services.identifies(engineID: "ollama", port: $0) }
        for port in ports {
            let listeners = services.listeners[port] ?? []
            do {
                let tags = try await request(port: port, path: "/api/tags")["models"] as? [[String: Any]] ?? []
                guard let entry = tags.first(where: { canonical($0["name"] as? String ?? "") == canonical(name) }), (entry["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: "") == digest else { continue }
                let show = try await request(port: port, path: "/api/show", method: "POST", body: ["model": name])
                let from = (show["modelfile"] as? String ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("FROM ") }
                let source = from.map { String($0.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? ""
                guard source.hasPrefix("/"), URL(fileURLWithPath: source).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().appendingPathComponent("blobs").path + "/") else { continue }
                let result = OllamaModelTarget(port: port, listeners: listeners, name: name, digest: digest, manifest: URL(fileURLWithPath: model.path))
                try validate(result, services: services); return result
            } catch { continue }
        }
        throw LaunchError.message("未找到管理此模型目录的 Ollama 服务。请启动对应 Ollama 服务后重试；共享层文件会保留。")
    }
    @MainActor static func ensureUnloaded(_ target: OllamaModelTarget, services: ServiceController, action: String = "删除") async throws {
        try validate(target, services: services)
        let state = try await request(port: target.port, path: "/api/ps")
        guard let loaded = state["models"] as? [[String: Any]] else { throw LaunchError.message("无法确认 Ollama 模型的常驻状态") }
        guard !loaded.contains(where: { canonical($0["name"] as? String ?? "") == canonical(target.name) }) else { throw LaunchError.message("此模型仍在内存中，请先从内存卸载此模型或停止对应 Ollama 服务，再\(action)。") }
    }
    @MainActor static func delete(_ target: OllamaModelTarget, services: ServiceController) async throws {
        try await ensureUnloaded(target, services: services)
        try validate(target, services: services)
        _ = try await request(port: target.port, path: "/api/delete", method: "DELETE", body: ["model": target.name])
        guard !FileManager.default.fileExists(atPath: target.manifest.path) else { throw LaunchError.message("Ollama 未移除此目录的登记文件，请重新扫描并检查原应用。") }
    }
}

enum ModelFileSafety {
    static func removalURL(_ model: LocalModel, models: [LocalModel], roots: [String]) throws -> URL {
        var path = URL(fileURLWithPath: model.removalPath).standardizedFileURL
        if models.contains(where: { $0.id != model.id && EngineMaintenance.contains(path.path, $0.path) }) {
            path = URL(fileURLWithPath: model.path).standardizedFileURL
        }
        guard path.pathComponents.count > 4, !roots.contains(path.path), path.path != Scanner.defaultRoot.path,
              !["hub", "hf-cache", "models", "cache", "ollama", "lmstudio", "manifests", "blobs"].contains(path.lastPathComponent) else { throw LaunchError.message("这个位置包含多个模型，请选择具体模型文件") }
        return path
    }
    static func used(_ model: LocalModel, removal: URL, services: [ServiceSpec], external: [ObservedService], models: [LocalModel] = []) -> Bool {
        let resolved = removal.resolvingSymlinksInPath().path
        return services.contains { spec in
            guard spec.pid != nil else { return false }
            if spec.engineID == "strata", let files = jsonFile(URL(fileURLWithPath: spec.modelPath).appendingPathComponent("modeldock-strata.json"))?["files"] as? [String: [String: Any]],
               files.values.compactMap({ $0["path"] as? String }).contains(where: {
                   let path = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                   return EngineMaintenance.contains(resolved, path) || EngineMaintenance.contains(path, resolved)
               }) { return true }
            for path in ([spec.draftModelPath, spec.projectorPath].compactMap({ $0 }) + (spec.componentSnapshot?.entries.compactMap(\.path) ?? [])) where path.hasPrefix("/") {
                let component = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                if EngineMaintenance.contains(resolved, component) || EngineMaintenance.contains(component, resolved) { return true }
            }
            if let text = spec.commandText, let words = try? ServiceCommand.words(text), let index = words.firstIndex(of: "--model"), words.count > index + 1 {
                let reference = words[index + 1].components(separatedBy: ":")[0]
                if reference == model.repository || reference == ModelOrigin.read(model)?.repository { return true }
                for assembly in models.flatMap(\.preparedSplashModels) where assembly.repository == reference || ModelOrigin.read(assembly)?.repository == reference {
                    if let files = jsonFile(URL(fileURLWithPath: assembly.path).appendingPathComponent("model.json"))?["files"] as? [String: [String: Any]],
                       files.values.compactMap({ $0["path"] as? String }).contains(where: { EngineMaintenance.contains(resolved, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }) { return true }
                }
            }
            if spec.engineID == "splash", !spec.modelPath.isEmpty, let record = jsonFile(URL(fileURLWithPath: spec.modelPath).appendingPathComponent("model.json")), let files = record["files"] as? [String: [String: Any]] {
                if files.values.compactMap({ $0["path"] as? String }).contains(where: { EngineMaintenance.contains(resolved, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }) { return true }
            }
            guard !spec.modelPath.isEmpty else { return false }
            let path = URL(fileURLWithPath: spec.modelPath).resolvingSymlinksInPath().path
            return spec.modelID == model.id || EngineMaintenance.contains(resolved, path) || EngineMaintenance.contains(path, URL(fileURLWithPath: model.path).resolvingSymlinksInPath().path)
        } || external.contains { service in service.models.contains { name in
            (name.hasPrefix("/") && EngineMaintenance.contains(resolved, URL(fileURLWithPath: name).resolvingSymlinksInPath().path)) || (model.repository != nil && name == model.repository)
        } }
    }
}

@MainActor
extension AppStore {
    func deleteModel(_ model: LocalModel) {
        guard modelFiles.deletingID == nil else { return }
        modelFiles.deletingID = model.id
        Task {
            defer { modelFiles.deletingID = nil }
            do {
                await services.refresh()
                var cleanup = RemovalCleanup()
                // 确认弹窗附加的清理清单：服务配置与 pi/OpenCode 登记随模型一起移除。
                func cleanupNote() -> String { cleanup.summary.isEmpty ? "" : "\n\n" + L10n.text("同时移除：") + "\n" + cleanup.summary }
                if model.format == "Ollama" {
                    let target = try await OllamaModelManagement.target(model, services: services)
                    try await OllamaModelManagement.ensureUnloaded(target, services: services)
                    cleanup = removalCleanup(model: model, removedPath: model.path)
                    let alert = NSAlert(); alert.messageText = L10n.text("从 Ollama 删除 \(model.name)？")
                    alert.informativeText = L10n.text("仅处理此模型，由 Ollama 管理登记文件和层文件。其他模型及其共享层保留。\n此操作不会移至废纸篓；恢复需要重新下载或导入。") + cleanupNote()
                    alert.alertStyle = .warning; alert.addButton(withTitle: L10n.text("删除模型")); alert.addButton(withTitle: L10n.text("取消")); alert.buttons[1].keyEquivalent = "\r"; alert.buttons[0].keyEquivalent = ""
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    await services.refresh(); try await OllamaModelManagement.delete(target, services: services)
                } else {
                    let path = try ModelFileSafety.removalURL(model, models: models, roots: inventory?.roots ?? [])
                    let source = URL(fileURLWithPath: model.path).resolvingSymlinksInPath()
                    @MainActor func checkUse() throws {
                        if self.strata.uses(source.path) || self.strata.uses(path.path) { throw LaunchError.message("此模型位置正在准备 Strata 配套组件，请等待操作完成。") }
                        if self.downloads.hasWriter(affecting: path.path) { throw LaunchError.message("此模型目录正在下载，请先暂停对应下载任务") }
                        guard !ModelFileSafety.used(model, removal: path, services: self.services.records, external: self.services.external, models: self.models) else { throw LaunchError.message("此模型文件正在被服务使用，请先停止使用它的服务") }
                    }
                    try checkUse()
                    guard let identity = FileIdentity.read(path.path) else { throw LaunchError.message("模型文件已移动或删除，请重新扫描") }
                    cleanup = removalCleanup(model: model, removedPath: path.path)
                    let alert = NSAlert(); alert.messageText = L10n.text("将 \(model.name) 移至废纸篓？")
                    alert.informativeText = L10n.text("\(path.path)\n\n其他模型及共享的配套文件保留。可以从废纸篓恢复。") + cleanupNote()
                    alert.alertStyle = .warning; alert.addButton(withTitle: L10n.text("移至废纸篓")); alert.addButton(withTitle: L10n.text("取消")); alert.buttons[1].keyEquivalent = "\r"; alert.buttons[0].keyEquivalent = ""
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    await services.refresh()
                    guard FileIdentity.read(path.path) == identity && URL(fileURLWithPath: model.path).resolvingSymlinksInPath() == source else { throw LaunchError.message("模型文件或目录链接已变化，请重新操作") }
                    try checkUse()
                    _ = try await Task.detached { try FileManager.default.trashItem(at: path, resultingItemURL: nil) }.value
                }
                // 模型已删除；残留清理失败只提示，不影响删除结果。
                let failures = applyRemovalCleanup(cleanup)
                if !failures.isEmpty { message = L10n.text("模型已删除，部分相关配置未能移除：") + failures.joined(separator: "；") }
                scan()
            } catch { message = error.localizedDescription }
        }
    }
}
