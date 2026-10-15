import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Darwin

enum StrataRuntime {
    static var helper: String? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("strata.py").path,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
    static func source(_ engine: Engine) -> URL { URL(fileURLWithPath: engine.path).deletingLastPathComponent().appendingPathComponent("source") }
    static func validRevision(_ value: String) -> Bool { value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    static func installProblems() -> [String] {
        var issues: [String] = []
        #if !arch(arm64)
        issues.append("Strata Metal 需要 Apple Silicon Mac。")
        #endif
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)) { issues.append("Strata Metal 需要 macOS 15 或更新版本。") }
        if !FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/clang") && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/clang") { issues.append("请先安装 Apple Command Line Tools，再编译 Strata。") }
        return issues
    }
    static func release() async throws -> EngineRelease {
        let commit = try await EngineCatalog.object("https://api.github.com/repos/Niko1221/Strata/commits/main")
        guard let revision = commit["sha"] as? String, validRevision(revision) else { throw LaunchError.message("Strata 官方源码版本信息无效") }
        let file = try await EngineCatalog.object("https://api.github.com/repos/Niko1221/Strata/contents/CMakeLists.txt?ref=" + revision)
        guard let content = file["content"] as? String, let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8), let version = ServiceStartupProgress.match(#"project\(strata VERSION ([0-9.]+)"#, in: text)?[1], EngineCatalog.validVersion(version) else { throw LaunchError.message("Strata 官方源码版本信息无效") }
        return .init(kind: .strata, version: version + "+" + revision.prefix(12), source: "Niko1221/Strata · Metal 官方源码", method: .source, sourceRevision: revision)
    }
    static func python(_ engine: Engine) -> String { source(engine).appendingPathComponent(".venv/bin/python").path }
}

enum StrataModelCatalog {
    static func fileSize(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    static func argument(_ flag: String, in config: [String: Any]) -> String? {
        guard let args = config["args"] as? [String], let i = args.firstIndex(of: flag), i + 1 < args.count,
              args.filter({ $0 == flag }).count == 1 else { return nil }
        return args[i + 1]
    }
    static func validate(config path: String) throws {
        guard let config = jsonFile(URL(fileURLWithPath: path)), config["backend"] as? String == "metal",
              let tokenizer = config["tokenizer"] as? String, tokenizer.hasPrefix("/"),
              FileManager.default.fileExists(atPath: tokenizer + "/vocab.json") else { throw LaunchError.message("Strata 配置或词表不完整，请重新准备模型。") }
        for flag in ["--native", "--ple-gguf", "--pack"] {
            guard let value = argument(flag, in: config), value.hasPrefix("/"), FileManager.default.fileExists(atPath: value) else { throw LaunchError.message("Strata 主权重、n-gram 或模型包缺失，请重新准备模型。") }
        }
        if let draft = argument("--mtp", in: config), !FileManager.default.fileExists(atPath: URL(fileURLWithPath: draft).deletingLastPathComponent().appendingPathComponent("mtp-q2_0.gguf").path) { throw LaunchError.message("Strata MTP 草稿文件缺失，请重新准备配套组件。") }
        if let vision = config["vision"] as? [String: Any], let mmproj = vision["mmproj"] as? String, !FileManager.default.fileExists(atPath: mmproj) { throw LaunchError.message("Strata 视觉投影缺失，请重新准备图片组件。") }
    }
    static func model(_ folder: URL) -> LocalModel? {
        guard let record = jsonFile(folder.appendingPathComponent("modeldock-strata.json")), record["schema"] as? Int == 1,
              record["backend"] as? String == "metal", let config = record["config"] as? String,
              URL(fileURLWithPath: config).standardizedFileURL.path == folder.appendingPathComponent("strata.json").standardizedFileURL.path,
              let files = record["files"] as? [String: [String: Any]], !files.isEmpty else { return nil }
        var missing: [String] = []; var bytes: Int64 = 0; var seen = Set<String>()
        for (name, entry) in files {
            guard let path = entry["path"] as? String, path.hasPrefix("/"), let expected = entry["bytes"] as? Int64 else { missing.append(name); continue }
            if !FileManager.default.fileExists(atPath: path) || fileSize(path) != expected { missing.append(name) }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted { bytes += fileSize(path) }
        }
        if (try? validate(config: config)) == nil { missing.append("主模型配套配置") }
        return .init(id: "strata:" + folder.path, name: record["name"] as? String ?? "Strata Flash-Next", format: "Strata Metal · " + (record["model"] as? String ?? "GGUF"), path: folder.path, kind: .language, bytes: bytes, complete: missing.isEmpty, verification: missing.isEmpty ? "Strata 主模型与配套组件齐全" : "Strata 配套组件不完整", missingFiles: missing.sorted(), removalPath: folder.path, architecture: "qwen4exp", strataConfig: config)
    }
    static func scan(roots: [String]) -> [LocalModel] {
        var result: [LocalModel] = []; var seen = Set<String>()
        for root in roots {
            let base = URL(fileURLWithPath: root).appendingPathComponent("strata/assemblies")
            for folder in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
                guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      seen.insert(folder.resolvingSymlinksInPath().path).inserted, let model = model(folder) else { continue }
                result.append(model)
            }
        }
        return result
    }
}

extension LocalModel {
    func preparedForStrata(_ mode: InputMode = .automatic) -> LocalModel? {
        let candidates = strataConfig != nil ? [self] : (strataAssemblies ?? []).compactMap { StrataModelCatalog.model(URL(fileURLWithPath: $0)) }
        let preferred = association?.strataAssembly
        var selected = candidates.filter { preferred == nil || $0.path == preferred }.sorted {
            if $0.complete != $1.complete { return $0.complete }
            let left = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date ?? .distantPast
            let right = (try? FileManager.default.attributesOfItem(atPath: $1.path)[.modificationDate]) as? Date ?? .distantPast
            return left > right
        }.first { model in
            mode != .multimodal || model.strataConfig.flatMap { jsonFile(URL(fileURLWithPath: $0)) }?["vision"] != nil
        }
        selected?.association = association
        return selected
    }
}

struct StrataVariant: Decodable, Identifiable {
    var id: String { name }
    var name: String; var repository: String; var revision: String; var files: [String]; var downloadGB: Double
}
struct StrataVariants: Decodable { var variants: [StrataVariant] }

final class StrataPreparationProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var birth: UInt64 = 0
    private var stopped = false
    func pause() {
        lock.lock(); defer { lock.unlock() }; stopped = true
        if let process, birth > 0, processStartTime(process.processIdentifier) == birth {
            _ = kill(getpgid(process.processIdentifier) == process.processIdentifier ? -process.processIdentifier : process.processIdentifier, SIGTERM)
        }
    }
    func run(_ command: InstallCommand, log: @escaping @Sendable (String) -> Void) throws {
        let task = Process(); task.executableURL = Bundle.main.executableURL
        task.arguments = ["--child-exec", command.executable] + command.arguments
        var environment = ProcessInfo.processInfo.environment; environment["PYTHONDONTWRITEBYTECODE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment; task.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        lock.lock()
        if stopped { lock.unlock(); throw LaunchError.message("Strata 准备已暂停，未完成文件保留。") }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task; birth = processStartTime(task.processIdentifier); lock.unlock()
        while true { let data = pipe.fileHandleForReading.availableData; if data.isEmpty { break }; log(String(decoding: data, as: UTF8.self)) }
        task.waitUntilExit()
        lock.lock(); let paused = stopped; process = nil; lock.unlock()
        if paused { throw LaunchError.message("Strata 准备已暂停，未完成文件保留；再次准备会继续。") }
        guard task.terminationStatus == 0 else { throw LaunchError.message("Strata 配套准备失败，请查看日志；已有文件保留，可继续准备。") }
    }
}

@MainActor final class StrataController: ObservableObject {
    @Published var variants: [StrataVariant] = []
    @Published var variant = "Q2_0"
    @Published var vision = false
    @Published var folder = ""
    @Published var localShards = ""
    @Published var busy = false
    @Published var loading = false
    @Published var log = ""
    /// Guidance or result text; errors set `messageIsError` so the view renders them as errors, not info.
    @Published var message: String? { didSet { messageIsError = false } }
    @Published var messageIsError = false
    func fail(_ error: Error) { message = error.localizedDescription; messageIsError = true }
    @Published var progress = ""
    @Published var currentRoot: String?
    private var currentInputs: [String] = []
    @Published var componentProgress: String?
    var pendingDirectory: String?
    private var stateURL: URL?
    private var worker: StrataPreparationProcess?
    var enginePath = ""
    func uses(_ path: String) -> Bool {
        guard busy else { return false }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return ([currentRoot].compactMap { $0 } + currentInputs).contains { EngineMaintenance.contains($0, canonical) || EngineMaintenance.contains(canonical, $0) }
    }
    func restore(directory: URL) {
        stateURL = directory.appendingPathComponent("strata-preparation.json")
        if let object = jsonFile(stateURL!) {
            variant = object["variant"] as? String ?? variant; vision = object["vision"] as? Bool ?? false
            folder = object["folder"] as? String ?? ""; localShards = object["shards"] as? String ?? ""; pendingDirectory = object["pending"] as? String
        }
    }
    func pause() { worker?.pause(); progress = "正在暂停准备，保留已有文件" }
    func load(engine: Engine) {
        guard engine.canServe, !busy, !loading, enginePath != engine.path, let helper = StrataRuntime.helper else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let value = try await InstallExecutor.run(.init(executable: StrataRuntime.python(engine), arguments: [helper, "catalogue", "--runtime", StrataRuntime.source(engine).path], title: "读取 Strata 模型目录"), log: { _ in })
                guard let data = value.components(separatedBy: .newlines).last(where: { $0.hasPrefix("{") })?.data(using: .utf8) else { throw LaunchError.message("Strata 模型目录无法识别") }
                variants = try JSONDecoder().decode(StrataVariants.self, from: data).variants; enginePath = engine.path
            } catch { fail(error) }
        }
    }
    func download(store: AppStore) {
        guard !busy, let selection = variants.first(where: { $0.name == variant }) else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                let address = "https://huggingface.co/" + selection.repository + "/tree/" + selection.revision
                let listing = try await ModelCatalog.listing(address, token: store.downloads.token)
                guard Set(selection.files).isSubset(of: Set(listing.files.map(\.path))) else { throw LaunchError.message("官方模型版本缺少所需分片，请重新检查 Strata 版本。") }
                store.downloads.listing = listing; store.downloads.address = address
                store.downloads.selected = Set(selection.files); store.downloads.selectedTaskID = nil
                if !folder.isEmpty { store.downloads.destination = folder }
                store.tab = .downloads
                store.downloads.notice = "已选择 Strata 主权重和 n-gram 文件；完成后回到 Strata 准备配套组件。"
            } catch { fail(error) }
        }
    }
    func chooseLocal(store: AppStore) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = L10n.text("选择包含所有 Strata GGUF 分片的目录。")
        if panel.runModal() == .OK, let url = panel.url { localShards = url.resolvingSymlinksInPath().path }
    }
    func prepare(store: AppStore) {
        guard !busy, !store.installation.running, !store.maintaining, store.engine.kind == .strata,
              store.engine.canServe, let helper = StrataRuntime.helper else { return }
        guard !store.services.records.contains(where: { $0.engineID == "strata" && $0.pid != nil }), store.updateProcesses(store.engine).isEmpty else { message = "请先停止 Strata 服务再准备模型；配套处理可能需要较多内存。"; return }
        guard let choice = variants.first(where: { $0.name == variant }) else { message = "请先选择支持的模型版本。"; return }
        if localShards.isEmpty, let job = store.downloads.jobs.last(where: { $0.state == .complete && $0.repository == choice.repository && $0.revision == choice.revision && Set(choice.files).isSubset(of: Set($0.files.map(\.path))) }), let first = choice.files.first {
            localShards = URL(fileURLWithPath: job.displayLocation).appendingPathComponent(first).deletingLastPathComponent().path
        }
        let initial = URL(fileURLWithPath: localShards)
        if let first = choice.files.first, !localShards.isEmpty, !FileManager.default.fileExists(atPath: initial.appendingPathComponent(URL(fileURLWithPath: first).lastPathComponent).path), FileManager.default.fileExists(atPath: initial.appendingPathComponent(first).path) { localShards = initial.appendingPathComponent(first).deletingLastPathComponent().path }
        guard !localShards.isEmpty, choice.files.allSatisfy({ FileManager.default.fileExists(atPath: URL(fileURLWithPath: localShards).appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).path) }) else { message = "请先下载全部模型分片，并选择其所在目录。"; return }
        if let active = store.downloads.jobs.first(where: { $0.id == store.downloads.activeID }), EngineMaintenance.contains(active.displayLocation, localShards) || EngineMaintenance.contains(localShards, active.displayLocation) { message = "这些模型分片仍在下载，请等待任务完成后再准备。"; return }
        let root = URL(fileURLWithPath: folder.isEmpty ? store.downloads.destination : folder).resolvingSymlinksInPath()
        let source = StrataRuntime.source(store.engine)
        let python = StrataRuntime.python(store.engine)
        let request: [String: Any] = ["runtime": source.path, "model": variant, "gguf": URL(fileURLWithPath: localShards).resolvingSymlinksInPath().path, "vision": vision ? "yes" : "no", "context": store.context]
        let data: URL
        if let pendingDirectory, let previous = jsonFile(URL(fileURLWithPath: pendingDirectory).appendingPathComponent("modeldock-preparation.json")), NSDictionary(dictionary: request).isEqual(to: previous), !FileManager.default.fileExists(atPath: pendingDirectory + "/modeldock-strata.json") { data = URL(fileURLWithPath: pendingDirectory) }
        else { data = root.appendingPathComponent("strata/assemblies").appendingPathComponent(variant.lowercased() + "-" + UUID().uuidString); pendingDirectory = data.path }
        busy = true; log = ""; message = nil; progress = "准备主模型与配套组件"; currentRoot = data.path; componentProgress = nil
        currentInputs = [URL(fileURLWithPath: localShards).resolvingSymlinksInPath().path] + choice.files.map { URL(fileURLWithPath: localShards).appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).resolvingSymlinksInPath().path }
        let arguments = ["-u", helper, "prepare", "--runtime", source.path, "--model", variant,
                         "--data-dir", data.path, "--gguf-dir", localShards, "--vision", vision ? "yes" : "no", "--context", String(store.context)]
        let operation = StrataPreparationProcess(); worker = operation
        Task { [self] in
            defer { busy = false; currentRoot = nil; currentInputs = []; worker = nil }
            do {
                try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let stateURL { try ConnectionFiles.json(["variant": variant, "vision": vision, "folder": root.path, "shards": localShards, "pending": data.path]).write(to: stateURL, options: .atomic) }
                try await Task.detached(priority: .utility) {
                    try operation.run(.init(executable: python, arguments: arguments, title: "准备 Strata 模型")) { [weak self] text in
                    Task { @MainActor in
                        guard let self else { return }
                        self.log += text; self.log = String(self.log.suffix(80_000))
                        self.progress = ServiceStartupProgress.parse(log: self.log, status: .starting).summary
                        if let line = self.log.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines).last(where: { $0.contains("%") || $0.contains("MiB/s") || $0.contains("MB/s") }) { self.componentProgress = String(line.suffix(350)) }
                    }
                    }
                }.value
                guard let model = StrataModelCatalog.model(data), model.complete else { throw LaunchError.message("Strata 模型配套检查未通过，请查看准备日志。") }
                try store.registerModelRoot(root.path)
                message = "Strata 模型准备完成，可在下方选择并启动服务。"
                pendingDirectory = nil
                if let stateURL { try? FileManager.default.removeItem(at: stateURL) }
                store.scan()
            } catch { fail(error) }
        }
    }
}
