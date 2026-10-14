import Foundation
import Combine
import AppKit
import CryptoKit

struct ModelFileEntry: Identifiable {
    var id: String { path }
    var path: String
    var name: String
    var role: String
    var bytes: Int64
    var exists: Bool
    var expectedBytes: Int64?
    var references = 1
    var linked = false
    var valid: Bool { exists && (expectedBytes == nil || expectedBytes == bytes) }
}

enum ModelFileCatalog {
    static func ollamaRoot(_ manifest: URL) -> URL? {
        let parts = manifest.standardizedFileURL.pathComponents
        guard let index = parts.lastIndex(of: "manifests"), index > 1, parts.count >= index + 5 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<index])))
    }
    static func ollamaName(_ manifest: URL) -> String? {
        guard let root = ollamaRoot(manifest) else { return nil }
        let parts = String(manifest.path.dropFirst(root.path.count + "/manifests/".count)).split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        let host = parts[0], namespace = parts[1], model = parts.dropFirst(2).dropLast().joined(separator: "/") + ":" + parts.last!
        return (host == "registry.ollama.ai" ? (namespace == "library" ? "" : namespace + "/") : host + "/" + namespace + "/") + model
    }
    static func ollamaLayers(_ manifest: URL) -> [[String: Any]] {
        guard let object = jsonFile(manifest), let layers = object["layers"] as? [[String: Any]] else { return [] }
        return ((object["config"] as? [String: Any]).map { [$0] } ?? []) + layers
    }
    static func validDigest(_ digest: String) -> Bool {
        digest.hasPrefix("sha256:") && digest.count == 71 && digest.dropFirst(7).allSatisfy(\.isHexDigit)
    }
    static func entries(model: LocalModel, models: [LocalModel]) -> [ModelFileEntry] {
        let fm = FileManager.default, source = URL(fileURLWithPath: model.path)
        var rows: [ModelFileEntry] = []
        func add(_ url: URL, name: String? = nil, role: String? = nil, expected: Int64? = nil, references: Int = 1) {
            guard !rows.contains(where: { $0.path == url.path }) else { return }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            let ext = url.pathExtension.lowercased()
            let label = role ?? (["gguf", "safetensors", "bin"].contains(ext) ? "权重" : ["json", "model", "txt", "jinja"].contains(ext) ? "配置 / tokenizer" : "配套文件")
            let size = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            rows.append(.init(path: url.path, name: name ?? url.lastPathComponent, role: label, bytes: Int64(size), exists: fm.fileExists(atPath: url.path), expectedBytes: expected, references: references, linked: values?.isSymbolicLink == true))
        }
        if model.format == "Ollama", let root = ollamaRoot(source) {
            add(source, role: "模型登记清单")
            for layer in ollamaLayers(source) {
                guard let digest = layer["digest"] as? String, validDigest(digest) else { continue }
                let count = models.filter { other in other.format == "Ollama" && ollamaRoot(URL(fileURLWithPath: other.path))?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() && ollamaLayers(URL(fileURLWithPath: other.path)).contains { $0["digest"] as? String == digest } }.count
                let media = layer["mediaType"] as? String ?? ""
                let role = media.contains(".model") ? "权重层" : media.contains("config") || media.contains("image.v1") ? "配置层" : media.contains("template") ? "模板层" : media.contains("params") ? "参数层" : "配套层"
                add(root.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-")), role: role, expected: (layer["size"] as? NSNumber)?.int64Value, references: max(1, count))
            }
        } else if model.format.hasPrefix("GGUF") {
            add(source, role: model.kind == .adapter ? "适配器" : "权重")
            if let companion = model.companion { add(URL(fileURLWithPath: companion), role: "视觉投影", references: max(1, models.filter { $0.companion == companion }.count)) }
        } else {
            let folder = URL(fileURLWithPath: model.folder)
            if let iterator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                while let file = iterator.nextObject() as? URL, rows.count < 5000 {
                    let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true { if values?.isSymbolicLink == true { iterator.skipDescendants() }; continue }
                    add(file, name: String(file.path.dropFirst(folder.path.count + 1)))
                }
            }
            if let manifest = jsonFile(folder.appendingPathComponent("manifest.json")), let artifacts = manifest["artifacts"] as? [[String: Any]] {
                for artifact in artifacts {
                    guard let path = artifact["path"] as? String, DownloadPaths.safeRelative(path) else { continue }
                    let url = folder.appendingPathComponent(path)
                    if let index = rows.firstIndex(where: { $0.path == url.path }) { rows[index].expectedBytes = (artifact["size"] as? NSNumber)?.int64Value }
                    else { add(url, name: path, expected: (artifact["size"] as? NSNumber)?.int64Value) }
                }
            }
            if model.splashSelection != nil, let record = jsonFile(folder.appendingPathComponent("model.json")), let files = record["files"] as? [String: [String: Any]] {
                for (name, entry) in files where DownloadPaths.safeRelative(name) {
                    let url = folder.appendingPathComponent(name), expected = (entry["bytes"] as? NSNumber)?.int64Value
                    if let index = rows.firstIndex(where: { $0.path == url.path }) { rows[index].expectedBytes = expected }
                    else { add(url, name: name, expected: expected) }
                }
            }
            for missing in model.missingFiles where DownloadPaths.safeRelative(missing) { add(folder.appendingPathComponent(missing), name: missing) }
        }
        for assembly in model.preparedSplashModels where model.splashSelection == nil {
            guard let files = jsonFile(URL(fileURLWithPath: assembly.path).appendingPathComponent("model.json"))?["files"] as? [String: [String: Any]] else { continue }
            for (name, entry) in files {
                guard let path = entry["path"] as? String, path.hasPrefix("/") else { continue }
                let expected = (entry["bytes"] as? NSNumber)?.int64Value
                if let index = rows.firstIndex(where: { $0.path == path }) { rows[index].expectedBytes = expected; continue }
                let references = models.filter { candidate in candidate.preparedSplashModels.contains { prepared in
                    (jsonFile(URL(fileURLWithPath: prepared.path).appendingPathComponent("model.json"))?["files"] as? [String: [String: Any]])?.values.contains { $0["path"] as? String == path } == true
                } }.count
                add(URL(fileURLWithPath: path), name: "Splash / " + name, role: name.hasPrefix("draft/") ? "草稿组件" : name.hasPrefix("vision/") ? "视觉组件" : "引擎配置", expected: expected, references: max(1, references))
            }
        }
        let strata = model.strataConfig != nil ? [model.path] : model.strataAssemblies ?? []
        for assembly in strata {
            guard let files = jsonFile(URL(fileURLWithPath: assembly).appendingPathComponent("modeldock-strata.json"))?["files"] as? [String: [String: Any]] else { continue }
            for (name, item) in files {
                guard let path = item["path"] as? String, path.hasPrefix("/") else { continue }
                let expected = (item["bytes"] as? NSNumber)?.int64Value
                if let index = rows.firstIndex(where: { $0.path == path }) { rows[index].expectedBytes = expected }
                else { add(URL(fileURLWithPath: path), name: "Strata / " + name, role: name.hasPrefix("draft") ? "草稿组件" : name.hasPrefix("vision") ? "视觉组件" : name.hasPrefix("weights") ? "主模型权重" : name.hasPrefix("ngram") ? "n-gram 配套表" : "引擎配置", expected: expected) }
            }
        }
        return rows.sorted { if $0.valid != $1.valid { return !$0.valid }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class ModelFileController: ObservableObject {
    @Published var entries: [ModelFileEntry] = []
    @Published var loading = false
    @Published var search = ""
    @Published var deletingID: String?
    @Published var modelID: String?
    private var revision = 0
    var filtered: [ModelFileEntry] { entries.filter { search.isEmpty || ($0.name + $0.role).localizedCaseInsensitiveContains(search) } }
    func load(_ model: LocalModel, models: [LocalModel]) async {
        revision += 1; let version = revision
        if modelID != model.id { search = ""; entries = [] }
        modelID = model.id; loading = true
        let result = await Task.detached(priority: .utility) { ModelFileCatalog.entries(model: model, models: models) }.value
        guard revision == version else { return }
        entries = result; loading = false
    }
}

@MainActor
extension AppStore {
    func modelMatchesEngineFilter(_ model: LocalModel) -> Bool {
        guard let chosen = engines.first(where: { $0.id == modelEngineFilter }) else { return true }
        var candidate = model; candidate.complete = true
        if candidate.kind == .adapter { candidate.kind = .language }
        return candidate.compatibility(with: chosen).level != .unsupported
    }
    func importLocalModels() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("导入模型"); panel.message = L10n.text("选择本地 GGUF、Safetensors 文件或完整模型目录；文件保留在原位置。")
        guard panel.runModal() == .OK else { return }
        do { try registerModelLocations(panel.urls); modelEngineFilter = ""; search = ""; modelFilter = "全部"; tab = .models; scan() }
        catch { message = error.localizedDescription }
    }
    func registerModelLocations(_ urls: [URL]) throws {
        let roots = try urls.map { url -> String in
            guard FileManager.default.fileExists(atPath: url.path) else { throw LaunchError.message("所选模型位置已不存在") }
            let directory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            guard directory || ["gguf", "safetensors", "json", "bin"].contains(url.pathExtension.lowercased()) else { throw LaunchError.message("请选择模型权重文件或完整模型目录") }
            return (directory ? url : url.deletingLastPathComponent()).resolvingSymlinksInPath().path
        }
        let known = Set(extraRoots + (inventory?.roots ?? []))
        let next = Array(Set(extraRoots + roots.filter { !known.contains($0) })).sorted()
        try JSONEncoder().encode(next).write(to: services.stateDirectory.appendingPathComponent("locations.json"), options: .atomic)
        extraRoots = next
    }
    func unloadOllamaModel(_ name: String, port: Int) {
        guard unloadingModel == nil else { return }
        unloadingModel = "\(port):\(name)"
        Task {
            defer { unloadingModel = nil }
            do {
                await services.refresh()
                guard services.identifies(engineID: "ollama", port: port) else { throw LaunchError.message("此端口不是已确认的 Ollama 服务") }
                let identity = Set(services.listeners[port] ?? [])
                try await NativeModelAPI.load(name: name, port: port, context: 8192, unload: true)
                await services.refresh()
                guard Set(services.listeners[port] ?? []) == identity else { throw LaunchError.message("服务已变化，请重新检查常驻模型") }
            } catch { message = error.localizedDescription }
        }
    }
}
