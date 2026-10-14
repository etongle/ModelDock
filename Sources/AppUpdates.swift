import Foundation
import AppKit
import Combine

struct AppRelease: Codable {
    var version: String
    var url: URL
    var page: URL
    var bytes: Int64
    var sha256: String
}
enum AppUpdateCatalog {
    static let repository = "etongle/ModelDock"
    static let endpoint = "https://api.github.com/repos/etongle/ModelDock/releases/latest"
    static var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    static func validVersion(_ version: String) -> Bool { version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil && version.count < 30 }
    static func newer(_ available: String, than installed: String) -> Bool { validVersion(available) && validVersion(installed) && available.compare(installed, options: .numeric) == .orderedDescending }
    static func parse(_ value: [String: Any]) throws -> AppRelease {
        guard value["draft"] as? Bool == false, value["prerelease"] as? Bool == false,
              value["published_at"] as? String != nil,
              let tag = value["tag_name"] as? String, tag.hasPrefix("v"), validVersion(String(tag.dropFirst())),
              let page = value["html_url"] as? String,
              page == "https://github.com/etongle/ModelDock/releases/tag/" + tag,
              let assets = value["assets"] as? [[String: Any]] else { throw LaunchError.message("GitHub 正式发行版信息无效，请稍后重试。") }
        let version = String(tag.dropFirst()), name = "ModelDock-" + version + "-AppleSilicon.zip"
        let matches = assets.filter { $0["name"] as? String == name && $0["state"] as? String == "uploaded" }
        guard matches.count == 1, let asset = matches.first,
              let size = asset["size"] as? Int64, (1...500_000_000).contains(size),
              let address = asset["browser_download_url"] as? String,
              address == "https://github.com/etongle/ModelDock/releases/download/" + tag + "/" + name,
              let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"),
              digest.dropFirst(7).count == 64, digest.dropFirst(7).allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let url = URL(string: address), let pageURL = URL(string: page) else { throw LaunchError.message("正式发行版缺少适用的安装包或 SHA-256 校验，已停止自动更新。") }
        return .init(version: version, url: url, page: pageURL, bytes: size, sha256: String(digest.dropFirst(7)))
    }
    static func latest() async throws -> AppRelease {
        var request = URLRequest(url: URL(string: endpoint)!); request.timeoutInterval = 30
        request.setValue("ModelDock/" + installedVersion, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let session = URLSession(configuration: .ephemeral); defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 3_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LaunchError.message("无法读取 GitHub 应用更新信息，请检查网络后重试。") }
        return try parse(json)
    }
}

final class AppUpdateTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let release: AppRelease
    private let destination: URL
    private let progress: @Sendable (Int64, Double) -> Void
    private var previous: (Date, Int64) = (Date(), 0)
    private var redirects = 0
    init(release: AppRelease, destination: URL, progress: @escaping @Sendable (Int64, Double) -> Void) { self.release = release; self.destination = destination; self.progress = progress }
    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 1800
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil); self.session = session
            var request = URLRequest(url: release.url); request.setValue("ModelDock/" + AppUpdateCatalog.installedVersion, forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request); self.task = task; previous = (Date(), 0)
            lock.unlock(); task.resume()
        }
    }
    func cancel() { lock.lock(); let task = task; lock.unlock(); task?.cancel() }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; task = nil; let session = session; self.session = nil; lock.unlock()
        continuation?.resume(with: result); session?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        let allowed = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
        completionHandler(redirects <= 5 && request.url?.scheme == "https" && allowed.contains(request.url?.host ?? "") ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= release.bytes else { downloadTask.cancel(); return }
        let elapsed = Date().timeIntervalSince(previous.0)
        if elapsed >= 0.3 || totalBytesWritten == release.bytes {
            progress(totalBytesWritten, elapsed > 0 ? Double(totalBytesWritten - previous.1) / elapsed : 0); previous = (Date(), totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
                  StrataModelCatalog.fileSize(location.path) == release.bytes else { throw LaunchError.message("应用安装包下载不完整，请重试；原应用保留。") }
            try FileManager.default.moveItem(at: location, to: destination); finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } }
}

struct AppUpdatePreferences: Codable {
    var automaticCheck = true
    var automaticInstall = true
    var lastCheck: Date?
}
struct ReadyAppUpdate: Codable { var release: AppRelease; var application: String; var directory: String; var requestedInstall: Bool? = nil }

@MainActor final class AppUpdateController: ObservableObject {
    @Published var automaticCheck = true { didSet { save() } }
    @Published var automaticInstall = true { didSet { automaticFailure = false; save(); tryAutomaticInstall() } }
    @Published var lastCheck: Date?
    @Published var release: AppRelease?
    @Published var status = "更新来自 GitHub 正式发行版。"
    @Published var error: String?
    @Published var busy = false
    @Published var applying = false
    @Published var received: Int64 = 0
    @Published var speed: Double = 0
    @Published var ready: ReadyAppUpdate?
    private let directory: URL
    private let preferencesURL: URL
    private var timer: Timer?
    private var transfer: AppUpdateTransfer?
    private var worker: Process?
    private var automaticFailure = false
    var installBlocker: (() -> String?)?
    var onApply: (() -> Void)?
    var hidden: (() -> Bool)?
    var available: Bool { release.map { AppUpdateCatalog.newer($0.version, than: AppUpdateCatalog.installedVersion) } ?? false }
    var progress: Double { guard let release else { return 0 }; return min(1, Double(received) / Double(release.bytes)) }
    init(directory state: URL) {
        directory = state.appendingPathComponent("app-updates"); preferencesURL = state.appendingPathComponent("app-updates.json")
        if let data = try? Data(contentsOf: preferencesURL), let prefs = try? JSONDecoder().decode(AppUpdatePreferences.self, from: data) {
            automaticCheck = prefs.automaticCheck; automaticInstall = prefs.automaticInstall; lastCheck = prefs.lastCheck
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("ready.json")), let candidate = try? JSONDecoder().decode(ReadyAppUpdate.self, from: data),
           candidate.directory.hasPrefix(directory.path + "/"), candidate.application == candidate.directory + "/unpacked/ModelDock.app",
           AppUpdateCatalog.newer(candidate.release.version, than: AppUpdateCatalog.installedVersion), FileManager.default.fileExists(atPath: candidate.application) {
            ready = candidate; release = candidate.release; status = "新版本已下载并校验，等待安装。"
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("last-result.json")), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if result["result"] as? String == "failed" { error = "上次自动安装失败，原应用已保留。" }
            else if result["version"] as? String == AppUpdateCatalog.installedVersion { status = "应用更新已完成。" }
        }
    }
    private func save() {
        do { try ConnectionFiles.privateDirectory(preferencesURL.deletingLastPathComponent()); try JSONEncoder().encode(AppUpdatePreferences(automaticCheck: automaticCheck, automaticInstall: automaticInstall, lastCheck: lastCheck)).write(to: preferencesURL, options: .atomic) }
        catch { self.error = "应用更新设置无法保存，请检查目录权限。" }
    }
    func begin() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); tick() }
    }
    private func tick() {
        guard !busy, !applying else { return }
        if ready != nil { tryAutomaticInstall(); return }
        if automaticCheck && Date().timeIntervalSince(lastCheck ?? .distantPast) >= 86_400 { check() }
    }
    func check() {
        guard !busy, !applying else { return }; busy = true; error = nil; status = "正在检查 GitHub 应用更新…"
        Task {
            do {
                let latest = try await AppUpdateCatalog.latest(); release = latest; lastCheck = Date(); save()
                if ready?.release.version != latest.version { ready = nil; try? FileManager.default.removeItem(at: directory.appendingPathComponent("ready.json")) }
                status = available ? "发现新版本，可自动下载并覆盖安装。" : (latest.version == AppUpdateCatalog.installedVersion ? "应用已是最新版本。" : "当前应用版本高于 GitHub 正式发行版。")
                busy = false
                if available && automaticInstall { download() }
            } catch { busy = false; self.error = error.localizedDescription; status = "应用更新检查失败，请重试。"; lastCheck = Date(); save() }
        }
    }
    func cancelDownload() { transfer?.cancel() }
    func download(installWhenReady: Bool = false) {
        if ready != nil { install(); return }
        guard available, !busy, !applying, let release else { return }
        busy = true; error = nil; received = 0; speed = 0; status = "正在下载应用更新…"
        Task { [self] in
            let job = directory.appendingPathComponent(UUID().uuidString)
            do {
                guard let python = EnginePaths.bundledPython, let helper = Bundle.main.url(forResource: "app_update", withExtension: "py") else { throw LaunchError.message("应用更新组件缺失，请从 GitHub 下载完整安装包。") }
                try ConnectionFiles.privateDirectory(job)
                let archive = job.appendingPathComponent("release.zip")
                let stream = AppUpdateTransfer(release: release, destination: archive) { [weak self] bytes, speed in Task { @MainActor in self?.received = bytes; self?.speed = speed } }
                transfer = stream; try await stream.run(); transfer = nil; speed = 0; status = "正在校验并准备应用更新…"
                let unpacked = job.appendingPathComponent("unpacked")
                _ = try await InstallExecutor.run(.init(executable: python, arguments: ["-B", helper.path, "--archive", archive.path, "--destination", unpacked.path, "--sha256", release.sha256, "--bytes", String(release.bytes), "--version", release.version], title: "校验应用更新"), log: { _ in })
                let app = unpacked.appendingPathComponent("ModelDock.app")
                ready = .init(release: release, application: app.path, directory: job.path, requestedInstall: installWhenReady)
                try JSONEncoder().encode(ready).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
                status = "新版本已下载并校验，等待安装。"; busy = false
                if installWhenReady { install() } else if automaticInstall { tryAutomaticInstall() }
            } catch {
                busy = false; transfer = nil; speed = 0; self.error = error.localizedDescription; status = "更新未安装，原应用保留。"
                try? FileManager.default.removeItem(at: job)
            }
        }
    }
    func tryAutomaticInstall() {
        guard (automaticInstall || ready?.requestedInstall == true), !automaticFailure, ready != nil, !busy, !applying, onApply != nil else { return }
        if installBlocker?() != nil { status = "更新已准备好，等待当前任务或配置窗口结束后自动安装。"; return }
        install()
    }
    func install() {
        automaticFailure = false
        if ready != nil { ready?.requestedInstall = true; try? JSONEncoder().encode(ready).write(to: directory.appendingPathComponent("ready.json"), options: .atomic) }
        guard !busy, !applying, let ready, onApply != nil else { return }
        if let reason = installBlocker?() { status = "更新已准备好，等待当前任务或配置窗口结束后自动安装。"; error = reason; return }
        busy = true; error = nil; status = "正在安装应用更新，即将重新打开…"
        Task {
            let target = Bundle.main.bundleURL.standardizedFileURL, parent = Bundle.main.bundleURL.deletingLastPathComponent()
            let id = UUID().uuidString
            let staged = parent.appendingPathComponent(".ModelDock-update-" + id + ".app")
            do {
                guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else { throw LaunchError.message("应用所在目录不可写。请将应用放到可写的应用程序目录，或从 GitHub 手动安装。") }
                guard !FileManager.default.fileExists(atPath: staged.path) else { throw LaunchError.message("应用更新路径已变化，原应用保留。") }
                try AppUpdateWorker.validate(target, version: AppUpdateCatalog.installedVersion)
                try AppUpdateWorker.validate(URL(fileURLWithPath: ready.application), version: ready.release.version)
                _ = try await InstallExecutor.run(.init(executable: "/usr/bin/ditto", arguments: [ready.application, staged.path], title: "准备替换应用"), log: { _ in })
                try AppUpdateWorker.validate(staged, version: ready.release.version)
                if let reason = installBlocker?() { throw LaunchError.message(reason) }
                let job = AppUpdateJob(id: id, target: target.path, staged: staged.path, backup: parent.appendingPathComponent(".ModelDock-backup-" + id + ".app").path,
                                       oldVersion: AppUpdateCatalog.installedVersion, version: ready.release.version, parentPID: getpid(), parentBirth: processStartTime(getpid()), hidden: hidden?() ?? false,
                                       receipt: directory.appendingPathComponent("last-result.json").path, stateDirectory: preferencesURL.deletingLastPathComponent().path)
                try AppUpdateWorker.validatePaths(job)
                let jobURL = URL(fileURLWithPath: ready.directory).appendingPathComponent("apply.json")
                try JSONEncoder().encode(job).write(to: jobURL, options: .atomic)
                guard let executable = Bundle.main.executableURL else { throw LaunchError.message("应用更新入口缺失") }
                let workerURL = URL(fileURLWithPath: ready.directory).appendingPathComponent("update-worker-" + id)
                try FileManager.default.copyItem(at: executable, to: workerURL)
                let task = Process(); task.executableURL = workerURL; task.arguments = ["--apply-app-update", jobURL.path]
                task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice; task.standardInput = FileHandle.nullDevice
                try task.run(); worker = task; applying = true; busy = false; onApply?()
            } catch { busy = false; automaticFailure = true; self.error = error.localizedDescription; status = "更新未安装，原应用保留。"; try? FileManager.default.removeItem(at: staged) }
        }
    }
}
