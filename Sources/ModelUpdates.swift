import Foundation
import SwiftUI

struct ModelOrigin: Codable, Hashable {
    var site: ModelSite
    var repository: String
    var revision: String
    var files: [String]
    static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 128 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
    }
    static func read(_ model: LocalModel) -> ModelOrigin? {
        if let source = model.origin { return source }
        let folder = URL(fileURLWithPath: model.folder)
        if let (_, source) = receipt(above: folder) { return source }
        let parts = folder.pathComponents
        guard let repoIndex = parts.firstIndex(where: { $0.hasPrefix("models--") }), parts.count > repoIndex + 2, parts[repoIndex + 1] == "snapshots" else { return nil }
        let repo = String(parts[repoIndex].dropFirst(8)).replacingOccurrences(of: "--", with: "/")
        guard validRepository(repo) else { return nil }
        return .init(site: .huggingface, repository: repo, revision: parts[repoIndex + 2], files: [])
    }
    private static func receipt(above folder: URL) -> (URL, ModelOrigin)? {
        var current = folder
        for _ in 0..<8 {
            let file = current.appendingPathComponent("model-manager-source.json")
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
               let data = try? Data(contentsOf: file), let source = try? JSONDecoder().decode(ModelOrigin.self, from: data), validRepository(source.repository) { return (current, source) }
            if current.path == "/" { break }; current.deleteLastPathComponent()
        }
        return nil
    }
    static func sourceRoot(_ model: LocalModel) -> URL {
        let parts = URL(fileURLWithPath: model.folder).pathComponents
        if let index = parts.firstIndex(where: { $0.hasPrefix("models--") }), parts.count > index + 2, parts[index + 1] == "snapshots" { return URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(index + 3)))) }
        return receipt(above: URL(fileURLWithPath: model.folder))?.0 ?? URL(fileURLWithPath: model.folder)
    }
    static func displayName(folder: URL) -> String? {
        var originRoot: URL?, repository: String?
        if let (root, source) = receipt(above: folder) { originRoot = root; repository = source.repository }
        else {
            let parts = folder.pathComponents
            if let index = parts.firstIndex(where: { $0.hasPrefix("models--") }), parts.count > index + 2, parts[index + 1] == "snapshots" {
                repository = String(parts[index].dropFirst(8)).replacingOccurrences(of: "--", with: "/")
                originRoot = URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(index + 3))))
            }
        }
        guard let repository, validRepository(repository), let originRoot else { return nil }
        let name = repository.components(separatedBy: "/").last!
        return folder.path.hasPrefix(originRoot.path + "/") ? name + " · " + String(folder.path.dropFirst(originRoot.path.count + 1)) : name
    }
    static func address(_ source: ModelOrigin) -> String {
        source.site == .modelscope ? "https://modelscope.cn/models/\(source.repository)" : "https://huggingface.co/\(source.repository)"
    }
    static func hubRoot(_ path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let index = parts.firstIndex(where: { $0.hasPrefix("models--") }), index > 1 else { return nil }
        return NSString.path(withComponents: Array(parts[..<index]))
    }
    static func replacement(_ model: LocalModel) -> String? {
        guard model.format.hasPrefix("Splash"), !model.format.hasPrefix("Splash 上游") else { return nil }
        switch model.repository ?? read(model)?.repository {
        case "incoai/Qwen3.8-27B-Splash": return "mlx-community/Qwen3.8-27B-4bit"
        case "incoai/Qwen3.6-35B-A3B-Splash": return "mlx-community/Qwen3.6-35B-A3B-4bit"
        default: return nil
        }
    }
    static func selectedFiles(model: LocalModel, listing: RemoteListing) -> Set<String> {
        if model.format.hasPrefix("GGUF") {
            let root = sourceRoot(model)
            let paths = [model.path, model.companion].compactMap { $0 }.map { path in
                path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : URL(fileURLWithPath: path).lastPathComponent
            }
            return Set(listing.files.map(\.path)).intersection(paths)
        }
        if let source = read(model), !source.files.isEmpty, source.repository == listing.repository {
            // Include newly added shards/configuration instead of keeping an old shard list.
            if model.format.hasPrefix("MLX") || model.format == "Safetensors" { return tensorFiles(model: model, listing: listing) }
            return Set(listing.files.map(\.path)).intersection(source.files)
        }
        return model.format.hasPrefix("MLX") || model.format == "Safetensors" ? tensorFiles(model: model, listing: listing) : ModelCatalog.suggested(listing)
    }
    private static func tensorFiles(model: LocalModel, listing: RemoteListing) -> Set<String> {
        let root = sourceRoot(model), folder = model.folder
        var scoped = listing
        if folder.hasPrefix(root.path + "/") {
            let prefix = String(folder.dropFirst(root.path.count + 1)) + "/"
            scoped.files = listing.files.filter { $0.path.hasPrefix(prefix) }
        }
        return ModelCatalog.suggested(scoped)
    }
}

@MainActor
final class ModelUpdateDraft: ObservableObject, Identifiable {
    let id = UUID()
    let model: LocalModel
    @Published var address: String
    @Published var token = ""
    @Published var listing: RemoteListing?
    @Published var selected = Set<String>()
    @Published var checking = false
    @Published var updating = false
    @Published var error: String?
    @Published var result: String?
    private var checkedAddress: String?
    var original: ModelOrigin? { ModelOrigin.read(model) }
    var replacement: String? { ModelOrigin.replacement(model) }
    var selectedFiles: [RemoteFile] { listing?.files.filter { selected.contains($0.path) } ?? [] }
    var sameRevision: Bool {
        guard let original, let listing, listing.site == .huggingface else { return false }
        return original.repository == listing.repository && original.revision == listing.revision
    }
    init(model: LocalModel) {
        self.model = model
        address = ModelOrigin.replacement(model).map { "https://huggingface.co/" + $0 } ?? ModelOrigin.read(model).map(ModelOrigin.address) ?? ""
    }
    func check() {
        guard !checking, !updating else { return }; checking = true; error = nil; listing = nil; selected = []; result = nil
        let input = address, credential = token
        Task {
            defer { checking = false }
            do {
                let value = try await ModelCatalog.listing(input, token: credential)
                guard address == input else { return }
                guard value.site != .direct else { throw LaunchError.message("文件直链无法检查仓库版本，请填写 Hugging Face 或 ModelScope 仓库地址") }
                checkedAddress = input; listing = value; selected = ModelOrigin.selectedFiles(model: model, listing: value)
            } catch { self.error = error.localizedDescription }
        }
    }
    func download(store: AppStore) {
        guard let listing, !selectedFiles.isEmpty, !checking, !updating else { return }
        guard checkedAddress == address else { error = "仓库地址已变化，请重新检查版本"; return }
        guard store.downloads.activeID == nil, !store.maintaining else { error = "请先暂停当前下载或等待清理完成"; return }
        guard !store.strata.uses(model.path) else { error = "此模型正在准备 Strata 配套组件，请等待操作完成。"; return }
        store.downloads.address = address; store.downloads.token = token
        store.downloads.listing = listing; store.downloads.selected = selected
        store.downloads.createJob()
        if let message = store.downloads.message { error = message; return }
        store.modelUpdate = nil; store.tab = .downloads
    }
    func ollamaUpdate(store: AppStore) {
        guard !updating else { return }; updating = true; error = nil; result = nil
        Task {
            defer { updating = false }
            do {
                await store.services.refresh()
                let target = try await OllamaModelManagement.target(model, services: store.services)
                try await OllamaModelManagement.ensureUnloaded(target, services: store.services, action: "更新")
                try OllamaModelManagement.validate(target, services: store.services)
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(target.port)/api/pull")!)
                request.httpMethod = "POST"; request.timeoutInterval = 3600
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": target.name, "stream": false])
                let (data, response) = try await URLSession.shared.data(for: request)
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard (response as? HTTPURLResponse)?.statusCode == 200, object["status"] as? String == "success", object["error"] == nil else { throw LaunchError.message(object["error"] as? String ?? "Ollama 未确认模型更新成功，请查看原服务") }
                guard store.services.identifies(engineID: "ollama", port: target.port), Set(store.services.listeners[target.port] ?? []) == Set(target.listeners) else { throw LaunchError.message("更新期间 Ollama 服务发生变化，请重新检查") }
                result = "此模型已同步到仓库最新版本。"; store.scan()
            } catch { self.error = error.localizedDescription }
        }
    }
}

enum SplashAssemblyCatalog {
    static var root: URL { Scanner.home.appendingPathComponent("Library/Application Support/Splash/models") }
    static func scan(root: URL = SplashAssemblyCatalog.root) -> [LocalModel] {
        let fm = FileManager.default
        var links: [URL] = []
        for owner in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            links += (try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        // Revision/text/draft selections are intentionally hidden by Splash.
        links += (try? fm.contentsOfDirectory(at: root.appendingPathComponent(".selections"), includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        return links.compactMap { selection in
            let folder = selection.resolvingSymlinksInPath(), recordURL = folder.appendingPathComponent("model.json")
            guard seen.insert(selection.path).inserted, folder.path.hasPrefix(root.resolvingSymlinksInPath().path + "/.resolved/"),
                  let size = try? recordURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_000_000,
                  let record = jsonFile(recordURL), record["version"] as? Int == 1,
                  let name = record["model"] as? String,
                  let target = (record["sources"] as? [String: [String: Any]])?["target"],
                  let repo = target["repo"] as? String, ModelOrigin.validRepository(repo),
                  let entries = record["files"] as? [String: [String: Any]], !entries.isEmpty else { return nil }
            var missing: [String] = [], bytes: Int64 = 0, counted = Set<String>()
            for (path, entry) in entries {
                guard DownloadPaths.safeRelative(path), let expected = (entry["bytes"] as? NSNumber)?.int64Value, expected >= 0,
                      let source = entry["path"] as? String, source.hasPrefix("/") else { missing.append(path); continue }
                let file = folder.appendingPathComponent(path)
                let actual = (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                if actual != expected || file.resolvingSymlinksInPath().path != URL(fileURLWithPath: source).resolvingSymlinksInPath().path { missing.append(path) }
                let resolved = file.resolvingSymlinksInPath().path
                let identity = FileIdentity.read(resolved).map { "\($0.device):\($0.inode)" } ?? resolved
                if counted.insert(identity).inserted { bytes += actual ?? 0 }
            }
            guard let vision = record["vision_format"] as? String, ["none", "safetensors", "gguf"].contains(vision),
                  let format = record["target_format"] as? String, ["mlx-affine", "gguf"].contains(format) else { return nil }
            return .init(id: "splash-upstream:\(selection.path)", name: name, format: "Splash 上游 \(record["target_format"] as? String ?? "")", path: folder.path, kind: .language, bytes: bytes, complete: missing.isEmpty, verification: missing.isEmpty ? "新版组件文件齐全" : "缺少 \(missing.count) 项文件", repository: name, missingFiles: missing, removalPath: selection.path, origin: .init(site: .huggingface, repository: repo, revision: target["revision"] as? String ?? "", files: []), splashSelection: selection.path, splashVision: vision)
        }
    }
}
