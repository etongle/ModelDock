import Foundation
import Combine
import CryptoKit
import AppKit

struct ManagedEngine: Codable {
    var kind: EngineKind; var version: String; var executable: String; var source: String; var installedAt: Date
}
enum EnginePaths {
    static var root: URL { (argumentValue("--state-dir").map { URL(fileURLWithPath: $0) } ?? Scanner.home.appendingPathComponent("Library/Application Support/ModelManager")).appendingPathComponent("engines") }
    static func manifest(_ kind: EngineKind, root: URL = root, record: String = "active.json") -> ManagedEngine? {
        let folder = root.appendingPathComponent(kind.rawValue)
        guard folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return nil }
        guard ["active.json", "vision.json"].contains(record), let data = try? Data(contentsOf: folder.appendingPathComponent(record)), let entry = try? JSONDecoder().decode(ManagedEngine.self, from: data),
              entry.kind == kind, DownloadPaths.safeRelative(entry.executable) else { return nil }
        let executable = folder.appendingPathComponent(entry.executable)
        guard executable.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return entry
    }
    static func executable(_ kind: EngineKind) -> String? { manifest(kind).map { root.appendingPathComponent(kind.rawValue).appendingPathComponent($0.executable).path } }
    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var bundledPython: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("PythonRuntime/bin/python3").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    static var gatewayPython: String? { bundledPython ?? python ?? (FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") ? "/usr/bin/python3" : nil) }
    static var python: String? {
        ["/opt/homebrew/opt/python@3.13/bin/python3.13", "/opt/homebrew/opt/python@3.12/bin/python3.12", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? bundledPython
    }
}
enum InstallMethod: String, Codable { case brew, python, archive }
struct EngineRelease: Codable {
    var kind: EngineKind; var version: String; var source: String; var method: InstallMethod
    var asset: URL?; var sha256: String?; var bytes: Int64?; var checkedAt = Date()
    var visionVersion: String? = nil
    var components: [EngineComponentRelease]? = nil
}
struct InstallCommand: Codable {
    var executable: String; var arguments: [String]; var title: String
    var display: String { ([executable] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") }
}
struct EngineInstallPlan: Identifiable {
    var id = UUID(); var engine: Engine; var release: EngineRelease; var commands: [InstallCommand]
    var notes: [String]; var blockers: [String]; var updating: Bool
    var title: String { (updating ? "更新" : "安装") + engine.name }
}
enum EngineCatalog {
    static func object(_ url: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!); request.timeoutInterval = 25
        request.setValue("ModelManager/0.4", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LaunchError.message("无法读取官方版本信息，请稍后重试") }
        return value
    }
    static func release(_ kind: EngineKind) async throws -> EngineRelease {
        switch kind {
        case .strata: throw LaunchError.message("官方 Strata 尚未发布 Mac 安装包，Metal PR #1449 已关闭且未合并。可在引擎页面登记本机实验版或远程服务。")
        case .splash:
            let value = try await object("https://api.github.com/repos/incoai/splash/releases/latest")
            guard let version = value["tag_name"] as? String else { throw LaunchError.message("Splash 版本信息缺失") }
            return .init(kind: kind, version: version, source: "incoai/tap/splash · 官方 Homebrew tap", method: .brew)
        case .llama:
            async let app = object("https://formulae.brew.sh/api/cask/llama-app.json")
            async let cli = object("https://formulae.brew.sh/api/formula/llama.cpp.json")
            let (desktop, command) = try await (app, cli)
            guard let appVersion = desktop["version"] as? String, let cliVersion = (command["versions"] as? [String: Any])?["stable"] as? String else { throw LaunchError.message("Llama 组件版本信息缺失") }
            let revision = command["revision"] as? Int ?? 0
            return .init(kind: kind, version: appVersion, source: "Homebrew · llama.cpp + llama-app", method: .brew, components: [.init(id: "llama.cpp", name: "llama.cpp 命令行", version: cliVersion + (revision > 0 ? "_\(revision)" : "")), .init(id: "llama-app", name: "Llama 桌面应用", version: appVersion)])
        case .ollama, .lmstudio:
            let name = kind == .ollama ? "ollama" : kind == .llama ? "llama-app" : "lm-studio"
            let value = try await object("https://formulae.brew.sh/api/\(kind == .ollama ? "formula" : "cask")/\(name).json")
            guard let version = (value["version"] as? String) ?? ((value["versions"] as? [String: Any])?["stable"] as? String) else { throw LaunchError.message("Homebrew 版本信息缺失") }
            let revision = kind == .ollama ? value["revision"] as? Int ?? 0 : 0
            return .init(kind: kind, version: version + (revision > 0 ? "_\(revision)" : ""), source: "Homebrew · \(name)", method: .brew)
        case .mlx:
            let value = try await object("https://pypi.org/pypi/mlx-lm/json")
            guard let version = (value["info"] as? [String: Any])?["version"] as? String, validVersion(version) else { throw LaunchError.message("MLX-LM 版本信息无效") }
            let vision = try await object("https://pypi.org/pypi/mlx-vlm/json")
            guard let visionVersion = (vision["info"] as? [String: Any])?["version"] as? String, validVersion(visionVersion) else { throw LaunchError.message("MLX-VLM 版本信息无效") }
            return .init(kind: kind, version: version, source: "PyPI · MLX-LM + MLX-VLM", method: .python, visionVersion: visionVersion)
        case .prism:
            let value = try await object("https://api.github.com/repos/PrismML-Eng/llama.cpp/releases/latest")
            #if arch(arm64)
            let suffix = "-bin-macos-arm64.tar.gz"
            #else
            let suffix = "-bin-macos-x64.tar.gz"
            #endif
            guard let version = value["tag_name"] as? String,
                  let asset = (value["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String)?.hasSuffix(suffix) == true }),
                  let address = asset["browser_download_url"] as? String, let url = URL(string: address),
                  let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"),
                  validHash(String(digest.dropFirst(7))), url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/PrismML-Eng/llama.cpp/releases/download/") else { throw LaunchError.message("尚未找到带 SHA-256 校验的适配 macOS 的 Prism 发行包") }
            return .init(kind: kind, version: version, source: "PrismML-Eng/llama.cpp · 官方发行包", method: .archive, asset: url, sha256: String(digest.dropFirst(7)), bytes: (asset["size"] as? NSNumber)?.int64Value)
        }
    }
    static func validVersion(_ value: String) -> Bool { !value.isEmpty && value.utf8.count < 80 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) } }
    static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit } }
    static func plan(engine: Engine, release: EngineRelease, brew: String? = EnginePaths.brew, python: String? = EnginePaths.python, prefix: String? = nil) -> EngineInstallPlan {
        var commands: [InstallCommand] = []; var blockers: [String] = []; var notes = ["模型文件与服务配置保留。", "运行中的此引擎服务需要先停止，再执行安装或更新。"]
        let updating = engine.kind == .mlx ? EnginePaths.manifest(.mlx) != nil : engine.installed
        let brewRoot = prefix ?? (brew.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? "/opt/homebrew")
        func package(_ name: String, cask: Bool = false) {
            let present = FileManager.default.fileExists(atPath: brewRoot + (cask ? "/Caskroom/" : "/Cellar/") + (name.components(separatedBy: "/").last ?? name))
            let missingEntry = cask ? !(engine.appPath.map { FileManager.default.fileExists(atPath: $0) } ?? false) : name == "llama.cpp" ? !FileManager.default.isExecutableFile(atPath: brewRoot + "/bin/llama-server") : !engine.canServe
            if release.components != nil, present, !missingEntry, let component = EngineVersionPolicy.rows(engine: engine, release: release).first(where: { $0.id == name }), !component.state.needsAction { return }
            let operation = present ? (missingEntry ? "reinstall" : "upgrade") : "install"
            let flags = cask ? ["--cask"] + (operation == "upgrade" ? ["--greedy-auto-updates"] : []) + (!present && engine.appPath != nil ? ["--force"] : []) : ["--formula"]
            commands.append(.init(executable: brew ?? "", arguments: [operation] + flags + [name], title: "\(operation == "reinstall" ? "重新安装" : present ? "更新" : "安装") \(name)"))
        }
        switch release.method {
        case .brew:
            if brew == nil { blockers.append("尚未安装 Homebrew。请先按官方说明安装，再重新检查。") }
            switch engine.kind {
            case .splash: package("incoai/tap/splash")
            case .ollama: package("ollama")
            case .llama: package("llama.cpp"); package("llama-app", cask: true); notes.append("同时管理 Llama 桌面应用与 Homebrew 命令行引擎；本工具优先使用更新后的命令行。")
            case .lmstudio: package("lm-studio", cask: true); notes.append("安装后打开 LM Studio，初始化运行组件并开启本地服务。")
            default: blockers.append("安装方式与引擎不匹配")
            }
            notes.append("Homebrew 可能安装所需依赖；不执行自动依赖清扫。已有桌面应用可能由安装包替换。")
        case .python:
            if python == nil { blockers.append("未发现可用的 Python 运行环境，请使用包含运行环境的安装包或安装 Python 后重试。") }
            notes.append("MLX-LM 与 MLX-VLM 安装到本工具的独立 Python 环境；保留系统 MLX 库与旧运行环境。文本模式使用 MLX-LM，多模态模式使用 MLX-VLM。")
        case .archive:
            notes.append("下载后验证 SHA-256；新版本独立保存，验证通过后切换服务入口，保留旧版程序。")
        }
        if release.kind != engine.kind { blockers.append("版本信息不属于所选引擎") }
        return .init(engine: engine, release: release, commands: commands, notes: notes, blockers: blockers, updating: updating)
    }
}

enum InstallExecutor {
    static func command(_ command: InstallCommand, log: @escaping @Sendable (String) -> Void) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: command.executable); process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        for key in ["HOMEBREW_NO_AUTOREMOVE", "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_ANALYTICS", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK", "HOMEBREW_NO_ASK"] { environment[key] = "1" }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment; process.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        var tail = Data()
        while true {
            let data = pipe.fileHandleForReading.availableData; if data.isEmpty { break }
            tail.append(data); if tail.count > 160_000 { tail.removeFirst(tail.count - 160_000) }
            log(String(decoding: data, as: UTF8.self))
        }
        process.waitUntilExit()
        let text = String(decoding: tail, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw LaunchError.message(text.isEmpty ? "操作失败（代码 \(process.terminationStatus)）" : text) }
        return text
    }
    static func run(_ command: InstallCommand, log: @escaping @Sendable (String) -> Void) async throws -> String { try await Task.detached(priority: .utility) { try self.command(command, log: log) }.value }
    static func validateArchive(_ listing: String) throws {
        let entries = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !entries.isEmpty, entries.count < 5000, entries.allSatisfy({ path in
            let path = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            return !path.hasPrefix("/") && !path.contains("\\") && !path.components(separatedBy: "/").contains("..")
        }) else { throw LaunchError.message("发行包包含无效路径，已停止安装") }
    }
    static func publish(_ entry: ManagedEngine, root: URL, record: String = "active.json") throws {
        let directory = root.appendingPathComponent(entry.kind.rawValue)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw LaunchError.message("引擎安装目录已变化") }
        guard DownloadPaths.safeRelative(entry.executable), FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(entry.executable).path),
              directory.appendingPathComponent(entry.executable).resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw LaunchError.message("新引擎入口无效；原版本保留") }
        guard ["active.json", "vision.json"].contains(record) else { throw LaunchError.message("引擎登记文件无效") }
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(record), options: .atomic)
    }
    static func validateLinks(_ listing: String) throws {
        for line in listing.components(separatedBy: .newlines) {
            let marker = line.contains(" -> ") ? " -> " : line.contains(" link to ") ? " link to " : nil
            if let marker, let range = line.range(of: marker) {
                let target = String(line[range.upperBound...])
                guard DownloadPaths.safeRelative(target) else { throw LaunchError.message("发行包包含指向安装目录外的链接") }
            } else if line.hasPrefix("l") || line.hasPrefix("h") { throw LaunchError.message("无法核对发行包中的链接") }
        }
    }
    static func install(_ plan: EngineInstallPlan, root: URL, log: @escaping @Sendable (String) -> Void) async throws {
        guard plan.blockers.isEmpty, plan.engine.kind == plan.release.kind else { throw LaunchError.message(plan.blockers.joined(separator: "\n")) }
        if plan.release.method == .brew {
            let expected = EngineCatalog.plan(engine: plan.engine, release: plan.release).commands
            guard !expected.isEmpty, expected.map(\.display) == plan.commands.map(\.display) else { throw LaunchError.message("安装包登记发生变化，请重新检查") }
            for step in expected { log("\n\(step.title)…\n"); _ = try await run(step, log: log) }
            return
        }
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { throw LaunchError.message("引擎安装目录包含链接，请检查安装位置") }
        let revision = UUID().uuidString
        let directory = root.appendingPathComponent(plan.engine.id).appendingPathComponent(revision)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw LaunchError.message("引擎安装目录包含越界链接") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var binary: URL
        if plan.release.method == .python {
            guard plan.engine.kind == .mlx, let python = EnginePaths.python, EngineCatalog.validVersion(plan.release.version) else { throw LaunchError.message("MLX-LM 安装信息无效") }
            let environment = directory.appendingPathComponent("venv")
            _ = try await run(.init(executable: python, arguments: ["-m", "venv", environment.path], title: "创建独立环境"), log: log)
            _ = try await run(.init(executable: environment.appendingPathComponent("bin/python3").path, arguments: ["-m", "pip", "--isolated", "install", "--disable-pip-version-check", "--index-url", "https://pypi.org/simple", "mlx-lm==\(plan.release.version)"], title: "安装 MLX-LM"), log: log)
            if let version = plan.release.visionVersion {
                guard EngineCatalog.validVersion(version) else { throw LaunchError.message("MLX-VLM 版本信息无效") }
                _ = try await run(.init(executable: environment.appendingPathComponent("bin/python3").path, arguments: ["-m", "pip", "--isolated", "install", "--disable-pip-version-check", "--index-url", "https://pypi.org/simple", "mlx-vlm==\(version)"], title: "安装 MLX-VLM"), log: log)
                let vision = environment.appendingPathComponent("bin/mlx_vlm.server")
                _ = try await run(.init(executable: vision.path, arguments: ["--help"], title: "验证 MLX-VLM"), log: log)
                let base = root.appendingPathComponent("mlx").path + "/"
                try publish(.init(kind: .mlx, version: version, executable: String(vision.path.dropFirst(base.count)), source: plan.release.source, installedAt: Date()), root: root, record: "vision.json")
            }
            binary = environment.appendingPathComponent("bin/mlx_lm.server")
        } else {
            guard plan.engine.kind == .prism, let asset = plan.release.asset, asset.scheme == "https", asset.host == "github.com", asset.path.hasPrefix("/PrismML-Eng/llama.cpp/releases/download/"), let hash = plan.release.sha256, EngineCatalog.validHash(hash) else { throw LaunchError.message("Prism 官方发行包信息无效") }
            log("正在下载官方发行包…\n")
            let (download, response) = try await URLSession.shared.download(from: asset)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LaunchError.message("发行包下载失败") }
            let archive = directory.appendingPathComponent("release.tar.gz"); try FileManager.default.moveItem(at: download, to: archive)
            let checked = try await run(.init(executable: "/usr/bin/shasum", arguments: ["-a", "256", archive.path], title: "校验发行包"), log: { _ in })
            guard checked.components(separatedBy: .whitespaces).first?.lowercased() == hash.lowercased() else { throw LaunchError.message("发行包 SHA-256 校验失败；原版本保留") }
            let listing = try await run(.init(executable: "/usr/bin/tar", arguments: ["-tf", archive.path], title: "检查发行包"), log: { _ in }); try validateArchive(listing)
            let links = try await run(.init(executable: "/usr/bin/tar", arguments: ["-tvf", archive.path], title: "检查链接"), log: { _ in }); try validateLinks(links)
            let extracted = directory.appendingPathComponent("runtime"); try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            _ = try await run(.init(executable: "/usr/bin/tar", arguments: ["-xf", archive.path, "-C", extracted.path], title: "解压发行包"), log: log)
            let entries = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: [.isSymbolicLinkKey])!
            var found: URL?
            while let item = entries.nextObject() as? URL {
                guard item.resolvingSymlinksInPath().path.hasPrefix(extracted.resolvingSymlinksInPath().path + "/") else { throw LaunchError.message("发行包链接超出安装目录") }
                if item.lastPathComponent == "llama-server", FileManager.default.isExecutableFile(atPath: item.path) { found = item }
            }
            guard let found else { throw LaunchError.message("发行包缺少模型服务程序") }; binary = found
        }
        log("正在验证新引擎…\n")
        _ = try await run(.init(executable: binary.path, arguments: [plan.engine.kind == .prism ? "--version" : "--help"], title: "验证引擎"), log: log)
        let folder = root.appendingPathComponent(plan.engine.id).path + "/"
        try publish(.init(kind: plan.engine.kind, version: plan.release.version, executable: String(binary.path.dropFirst(folder.count)), source: plan.release.source, installedAt: Date()), root: root)
        log("新版本验证通过，已切换服务入口。旧版程序保留。\n")
    }
}

@MainActor
final class EngineInstallController: ObservableObject {
    @Published var releases: [String: EngineRelease] = [:]
    @Published var checking: String?
    @Published var plan: EngineInstallPlan?
    @Published var running = false
    @Published var log = ""
    @Published var message: String?
    @Published var succeeded = false
    @Published var activeEngineID: String?
    let root: URL
    init(directory: URL) { root = directory.appendingPathComponent("engines") }
    func check(_ engine: Engine) {
        guard checking == nil && !running else { return }; checking = engine.id; message = nil; log = ""; succeeded = false
        Task {
            do {
                let release = try await EngineCatalog.release(engine.kind); releases[engine.id] = release
                // Runtime blockers belong to the live view, not the immutable install plan.
                plan = EngineCatalog.plan(engine: engine, release: release)
            } catch { message = error.localizedDescription }
            checking = nil
        }
    }
    func perform(_ plan: EngineInstallPlan, blockers: [String], finished: @escaping () -> Void) {
        guard !running && plan.blockers.isEmpty && blockers.isEmpty else { message = (plan.blockers + blockers).joined(separator: "\n"); return }
        running = true; activeEngineID = plan.engine.id; log = "开始\(plan.title)…\n"; message = nil; succeeded = false
        Task { [self] in
            do {
                try await InstallExecutor.install(plan, root: root) { [weak self] text in Task { @MainActor in self?.log += text; if let self, self.log.count > 100_000 { self.log = String(self.log.suffix(100_000)) } } }
                succeeded = true; message = "安装操作完成，正在核对各组件的实际版本。"; finished()
            } catch { message = error.localizedDescription; finished() }
            running = false; activeEngineID = nil
        }
    }
}
