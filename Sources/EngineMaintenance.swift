import Foundation
import Darwin

enum MaintenanceMode: String, Identifiable { case uninstall = "卸载引擎", residues = "清理残留"; var id: String { rawValue } }
enum RemovalGroup: String { case package = "安装包", executable = "应用与程序", residue = "设置与缓存", personal = "个人数据", model = "专属模型" }
struct FileIdentity: Equatable {
    var device: Int32; var inode: UInt64
    static func read(_ path: String) -> FileIdentity? {
        var value = stat(); guard lstat(path, &value) == 0 else { return nil }
        return .init(device: value.st_dev, inode: value.st_ino)
    }
}
struct RemovalItem: Identifiable {
    var id: String { path }
    var path: String; var group: RemovalGroup; var note: String
    var bytes: Int64; var identity: FileIdentity; var formula: String?
    var cask = false
    var selectedByDefault: Bool { group != .personal && group != .model }
}
struct MaintenancePlan: Identifiable {
    var id = UUID()
    var engine: Engine; var mode: MaintenanceMode; var items: [RemovalItem]
    var preserved: [String]; var notes: [String]; var blockers: [String]
}
struct MaintenanceLocations {
    var home: URL = Scanner.home
    var applications: URL = URL(fileURLWithPath: "/Applications")
    var brew: URL = URL(fileURLWithPath: "/opt/homebrew")
}

enum EngineMaintenance {
    static func diskBytes(_ path: String) -> Int64 {
        var value = stat(); guard lstat(path, &value) == 0 else { return 0 }
        if value.st_mode & S_IFMT != S_IFDIR { return Int64(value.st_blocks) * 512 }
        var bytes: Int64 = 0
        if let all = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
            while let item = all.nextObject() as? URL {
                if lstat(item.path, &value) == 0 { bytes += Int64(value.st_blocks) * 512; if value.st_mode & S_IFMT == S_IFLNK { all.skipDescendants() } }
            }
        }
        return bytes
    }
    static func dependents(of formulas: Set<String>, locations: MaintenanceLocations = .init()) -> [String] {
        let cellar = locations.brew.appendingPathComponent("Cellar")
        let fm = FileManager.default
        var result = Set<String>()
        for package in (try? fm.contentsOfDirectory(at: cellar, includingPropertiesForKeys: nil)) ?? [] where !formulas.contains(package.lastPathComponent) {
            for version in (try? fm.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)) ?? [] {
                let receipt = jsonFile(version.appendingPathComponent("INSTALL_RECEIPT.json"))
                let dependencies = receipt?["runtime_dependencies"] as? [[String: Any]] ?? []
                if dependencies.contains(where: { formulas.contains(($0["full_name"] as? String ?? "").components(separatedBy: "/").last ?? "") }) { result.insert(package.lastPathComponent) }
            }
        }
        return result.sorted()
    }
    static func contains(_ ancestor: String, _ path: String) -> Bool { path == ancestor || path.hasPrefix(ancestor + "/") }
    static func untrackedWeights(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true, url.pathExtension != "app" else { return false }
        if ["gguf", "safetensors", "onnx"].contains(url.pathExtension.lowercased()) { return true }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
        while let file = files.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { files.skipDescendants(); continue }
            if ["gguf", "safetensors", "onnx"].contains(file.pathExtension.lowercased()) { return true }
        }
        return false
    }
    static func protected(_ path: String, inventory: Inventory, locations: MaintenanceLocations = .init()) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let roots = inventory.roots + [locations.home.appendingPathComponent("Library/Application Support/Splash/models").path]
        // Trash removes a link itself. It never grants permission to remove its target.
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        let effective = isLink ? url.path : url.resolvingSymlinksInPath().path
        if roots.contains(where: { contains(effective, $0) || (!isLink && contains($0, effective)) }) { return true }
        return inventory.models.contains { contains(effective, URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path) }
    }
    static func plan(engine: Engine, mode: MaintenanceMode, inventory: Inventory, locations: MaintenanceLocations = .init()) -> MaintenancePlan {
        let home = locations.home; let fm = FileManager.default
        var items: [RemovalItem] = []; var preserved = inventory.roots; var notes: [String] = []
        func add(_ url: URL, _ group: RemovalGroup = .residue, _ note: String = "移至废纸篓，可恢复", formula: String? = nil, cask: Bool = false) {
            let path = url.standardizedFileURL.path
            guard let identity = FileIdentity.read(path), !items.contains(where: { $0.path == path }) else { return }
            if protected(path, inventory: inventory, locations: locations) || (formula == nil && untrackedWeights(path)) { preserved.append(path); return }
            items.append(.init(path: path, group: group, note: note, bytes: diskBytes(path), identity: identity, formula: formula, cask: cask))
        }
        func user(_ path: String, _ group: RemovalGroup = .residue, _ note: String = "移至废纸篓，可恢复") { add(home.appendingPathComponent(path), group, note) }
        func package(_ name: String, cask: Bool = false) { if mode == .uninstall { add(locations.brew.appendingPathComponent((cask ? "Caskroom/" : "Cellar/") + name), .package, "由 Homebrew 卸载已安装版本", formula: name, cask: cask) } }
        func managed(_ kind: EngineKind) {
            let root = home.appendingPathComponent("Library/Application Support/ModelManager/engines")
            let folder = root.appendingPathComponent(kind.rawValue)
            if mode == .uninstall { add(folder, .executable, "移除本工具管理的引擎和旧版；模型库保留") }
            else {
                let current = EnginePaths.manifest(kind, root: root)?.executable.components(separatedBy: "/").first
                for child in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where child.lastPathComponent != "active.json" && child.lastPathComponent != current { add(child, .residue, "旧版程序或未完成安装；当前版本保留") }
            }
        }
        func application(_ name: String) { if mode == .uninstall { add(locations.applications.appendingPathComponent(name + ".app"), .executable) } }
        var bundleNames: [String] = []
        switch engine.kind {
        case .strata:
            managed(.strata)
            notes.append("只管理本工具登记的安装目录；远程 Strata 主机的程序与模型不在本机卸载。")
        case .splash:
            package("splash")
            for child in ["catalog", "runtime", "thinking.key"] { user("Library/Application Support/Splash/" + child) }
            preserved.append(home.appendingPathComponent("Library/Application Support/Splash/models").path)
            bundleNames = ["Splash", "ai.inco.splash", "com.incoai.splash"]
        case .llama:
            package("llama.cpp"); package("llama-app", cask: true)
            if !fm.fileExists(atPath: locations.brew.appendingPathComponent("Caskroom/llama-app").path) { application("Llama") }
            if mode == .uninstall { user(".local/bin/llama", .executable) }
            user("Library/Application Support/Llama")
            bundleNames = ["Llama", "app.llama.Llama"]
        case .ollama:
            package("ollama"); application("Ollama")
            if mode == .uninstall { user("Library/LaunchAgents/homebrew.mxcl.ollama.plist", .residue, "卸载前停止此 Homebrew 服务，并移除自启动登记") }
            user("Library/Application Support/Ollama", .personal, "数据库与个人设置，默认保留")
            user(".ollama/id_ed25519", .personal, "身份密钥，默认保留"); user(".ollama/id_ed25519.pub", .personal, "身份公钥，默认保留")
            let models = home.appendingPathComponent(".ollama/models")
            if (try? models.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { add(models, .residue, "只移除目录链接，原始模型保留") }
            else { preserved.append(models.path) }
            bundleNames = ["Ollama", "com.electron.ollama", "com.ollama.ollama"]
        case .mlx:
            managed(.mlx)
            let ownedMLX = home.appendingPathComponent("Library/Application Support/ModelManager/engines/mlx")
            if !fm.fileExists(atPath: ownedMLX.path) { package("mlx-c"); package("mlx") }
            if mode == .uninstall {
                for path in [".local/bin/mlx_lm.server"] { user(path, .executable, "移除服务入口；共享 Python 环境保留") }
            }
            notes.append("MLX 是推理库。被其他软件依赖时，必须先卸载对应软件；不会强制破坏共享依赖。")
            bundleNames = ["mlx", "mlx-lm"]
        case .prism:
            managed(.prism)
            if mode == .uninstall { user("workspace_llm/llama.cpp-prism/build", .executable, "移除本地编译程序及其构建产物") }
            preserved.append(home.appendingPathComponent("workspace_llm/llama.cpp-prism").path + "（源代码保留）")
            bundleNames = ["Prism", "llama.cpp-prism"]
        case .lmstudio:
            package("lm-studio", cask: true)
            if !fm.fileExists(atPath: locations.brew.appendingPathComponent("Caskroom/lm-studio").path) { application("LM Studio") }
            if mode == .uninstall || !engine.installed { user(".lmstudio/bin", .executable); user(".lmstudio/extensions", .executable) }
            for child in (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".lmstudio").path)) ?? [] where !["models", "bin", "extensions", ".internal"].contains(child) {
                user(".lmstudio/" + child, child == "server-logs" || child == ".DS_Store" ? .residue : .personal, "应用设置或个人数据，可自行选择")
            }
            for child in (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".lmstudio/.internal").path)) ?? [] {
                let url = home.appendingPathComponent(".lmstudio/.internal/" + child)
                if child == "bundled-models", (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true { preserved.append(url.path); continue }
                let disposable = child.contains("cache") || child.contains("temp-downloads") || child.contains("staged-updates") || child == "bundled-models" || child == "llmster-pid.lock"
                add(url, disposable ? .residue : .personal, disposable ? "组件缓存；模型目录链接仅移除链接" : "配置或历史数据，默认保留")
            }
            let modelLink = home.appendingPathComponent(".lmstudio/models")
            if (try? modelLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { add(modelLink, .residue, "只移除目录链接，原始模型保留") }
            else { preserved.append(modelLink.path) }
            bundleNames = ["LM Studio", "com.lmstudio.LM-Studio", "ai.lmstudio"]
        }
        for name in bundleNames {
            for path in ["Library/Caches/\(name)", "Library/Logs/\(name)", "Library/Preferences/\(name).plist", "Library/Saved Application State/\(name).savedState"] { user(path) }
        }
        let formulas = Set(items.compactMap(\.formula))
        let dependentNames = dependents(of: formulas, locations: locations)
        var blockers = dependentNames.isEmpty ? [] : ["共享依赖正在被 \(dependentNames.joined(separator: "、")) 使用，请先卸载这些软件。"]
        if mode == .uninstall {
            for model in inventory.models where model.exclusiveEngine == engine.kind && model.kind == .language && model.format != "Ollama" {
                let broad = URL(fileURLWithPath: model.removalPath).standardizedFileURL
                let containsShared = inventory.models.contains { $0.id != model.id && contains(broad.path, $0.path) && $0.exclusiveEngine != engine.kind }
                let url = containsShared ? URL(fileURLWithPath: model.path).standardizedFileURL : broad
                guard let identity = FileIdentity.read(url.path), !inventory.roots.contains(url.path), url.pathComponents.count > 4 else { continue }
                items.append(.init(path: url.path, group: .model, note: "\(model.name) · \(model.usageTitle) · 默认保留", bytes: diskBytes(url.path), identity: identity))
            }
        }
        if let app = engine.appPath, NSRunningApplicationCheck.isRunning(app) { blockers.append("请先退出 \(engine.name) 应用。") }
        return .init(engine: engine, mode: mode, items: items, preserved: Array(Set(preserved)).sorted(), notes: notes, blockers: blockers)
    }
    static func runningPrograms(_ engine: Engine, allowBrewOllama: Bool) -> [String] {
        if engine.kind == .ollama && allowBrewOllama { return [] }
        let resolved = URL(fileURLWithPath: engine.path).resolvingSymlinksInPath().path
        let prefix: String
        switch engine.kind {
        case .splash: prefix = "/opt/homebrew/Cellar/splash/"
        case .prism: prefix = Scanner.home.appendingPathComponent("workspace_llm/llama.cpp-prism/build/").path
        case .lmstudio: prefix = Scanner.home.appendingPathComponent(".lmstudio/extensions/").path
        default: prefix = resolved + "/"
        }
        return runText("/bin/ps", ["-axo", "comm="]).components(separatedBy: "\n").filter { command in
            let path = URL(fileURLWithPath: command.trimmingCharacters(in: .whitespaces)).resolvingSymlinksInPath().path
            return path == resolved || path.hasPrefix(prefix)
        }
    }
    static func isBrewOllamaAgent(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["Label"] as? String == "homebrew.mxcl.ollama",
              let arguments = plist["ProgramArguments"] as? [String], let program = arguments.first else { return false }
        return URL(fileURLWithPath: program).resolvingSymlinksInPath().path == URL(fileURLWithPath: "/opt/homebrew/bin/ollama").resolvingSymlinksInPath().path
    }
    static func normalized(_ items: [RemovalItem]) -> [RemovalItem] {
        items.filter { child in !items.contains { parent in parent.path != child.path && contains(parent.path, child.path) } }
    }
    static func downloadBlockers(_ items: [RemovalItem], jobs: [ModelDownload]) -> [String] {
        jobs.filter { $0.state == .downloading || $0.state == .queued }.compactMap { job in
            let locations = [URL(fileURLWithPath: job.root).appendingPathComponent(job.folder).resolvingSymlinksInPath().path] + (job.repairTarget.map { [URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] } ?? [])
            guard let item = items.first(where: { item in
                let path = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
                return locations.contains { contains(path, $0) || contains($0, path) }
            }) else { return nil }
            return "下载任务“\(job.repository)”正在使用所选位置，请先暂停这个任务：\n\(item.path)"
        }
    }
    static func validate(_ selected: [RemovalItem], original: MaintenancePlan, fresh: MaintenancePlan) throws {
        guard fresh.blockers.isEmpty else { throw LaunchError.message(fresh.blockers.joined(separator: "\n")) }
        guard !selected.isEmpty else { throw LaunchError.message("请先选择要处理的项目") }
        for item in selected {
            guard original.items.contains(where: { $0.path == item.path && $0.identity == item.identity && $0.group == item.group && $0.formula == item.formula && $0.cask == item.cask }),
                  fresh.items.contains(where: { $0.path == item.path && $0.group == item.group && $0.formula == item.formula && $0.cask == item.cask }),
                  FileIdentity.read(item.path) == item.identity else { throw LaunchError.message("文件或归属已经变化，请重新扫描清理清单：\(item.path)") }
            guard item.path != "/", item.path != Scanner.home.path, item.path != "/Applications", !["Cellar", "Library", "models", "hub", "hf-cache", "workspace_llm"].contains(URL(fileURLWithPath: item.path).lastPathComponent) || (try? URL(fileURLWithPath: item.path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { throw LaunchError.message("不能清理共享目录：\(item.path)") }
        }
    }
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_AUTOREMOVE", "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_ANALYTICS"] { environment[key] = "1" }
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw LaunchError.message(text.isEmpty ? "操作失败（\(process.terminationStatus)）" : text) }
        return text
    }
}

// Isolated to keep the planner usable by the command-line checks.
import AppKit
enum NSRunningApplicationCheck {
    static func isRunning(_ path: String) -> Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path } }
}
