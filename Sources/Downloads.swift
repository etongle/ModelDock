import Foundation
import Combine
import CryptoKit
import Darwin

enum ModelSite: String, Codable { case huggingface = "Hugging Face", modelscope = "ModelScope", direct = "文件直链" }
struct RemoteFile: Identifiable, Codable, Hashable {
    var id: String { path }
    var path: String; var url: URL; var bytes: Int64; var sha256: String?
}
struct RemoteListing {
    var site: ModelSite; var repository: String; var revision: String; var files: [RemoteFile]; var preferred: String?
}
enum DownloadState: String, Codable { case paused = "已暂停", downloading = "下载中", complete = "已完成", failed = "需重试" }
struct ModelDownload: Identifiable, Codable {
    var id = UUID().uuidString
    var site: ModelSite; var repository: String; var revision: String
    var root: String; var folder: String; var files: [RemoteFile]
    var state: DownloadState = .paused; var finished = Set<String>()
    var received: Int64 = 0; var currentFile = ""; var error: String?
    var resumeBlockedReason: String? = nil
    var replacementOf: String? = nil
    var fileReceived: [String: Int64]? = nil
    var pausedFiles: Set<String>? = nil
    var priorityFile: String? = nil
    var repairTarget: String? = nil
    var repairFingerprint: RepairFingerprint? = nil
    var repairModelID: String? = nil
    var displayLocation: String { repairTarget.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? URL(fileURLWithPath: root).appendingPathComponent(folder).path }
    var total: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

enum DownloadPaths {
    static func safeRelative(_ path: String) -> Bool {
        let parts = path.components(separatedBy: "/")
        return !path.isEmpty && path.utf8.count < 4096 && !path.contains("\\") && !path.contains("\0") && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) && !parts.first!.hasPrefix(".")
    }
    static func destination(root: URL, folder: String, file: String) throws -> URL {
        let root = root.standardizedFileURL
        guard safeRelative(folder), safeRelative(file), root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else { throw LaunchError.message("下载目录或文件路径无效，请重新选择目录") }
        let destination = root.appendingPathComponent(folder).appendingPathComponent(file).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { throw LaunchError.message("文件超出下载目录") }
        var parent = destination
        while parent.path != root.path {
            var value = stat()
            if lstat(parent.path, &value) == 0, value.st_mode & S_IFMT == S_IFLNK { throw LaunchError.message("下载路径包含目录链接，已停止写入") }
            parent.deleteLastPathComponent()
        }
        return destination
    }
    static func validateURL(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw LaunchError.message("请使用 HTTPS 模型地址，访问令牌填在下方单独的输入框") }
    }
}

enum ModelCatalog {
    static func request(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.timeoutInterval = 30; request.setValue("ModelManager/0.2", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LaunchError.message("模型网站未返回有效响应") }
        guard http.statusCode == 200 else { throw LaunchError.message([401, 403].contains(http.statusCode) ? "仓库需要访问授权，请填写已获许可的访问令牌。" : "读取模型仓库失败（HTTP \(http.statusCode)）") }
        guard data.count <= 16_000_000 else { throw LaunchError.message("仓库文件清单过大，请使用具体模型文件的下载地址") }
        return (data, http)
    }
    static func normalizedAddress(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelOrigin.validRepository(value) ? "https://huggingface.co/" + value : value
    }
    static func listing(_ input: String, token: String) async throws -> RemoteListing {
        guard let url = URL(string: normalizedAddress(input)) else { throw LaunchError.message("请输入有效模型地址") }
        try DownloadPaths.validateURL(url)
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "huggingface.co" {
            guard parts.count >= 2, !["datasets", "spaces", "docs", "models"].contains(parts[0]) else { throw LaunchError.message("请粘贴 Hugging Face 模型仓库地址，例如 https://huggingface.co/mlx-community/模型名") }
            let repository = parts[0] + "/" + parts[1]
            let requestedRevision = parts.count >= 4 && ["tree", "blob", "resolve"].contains(parts[2]) ? parts[3] : "main"
            let preferred = parts.count >= 5 && ["blob", "resolve"].contains(parts[2]) ? parts.dropFirst(4).joined(separator: "/") : nil
            var api = URL(string: "https://huggingface.co/api/models")!
            for part in parts.prefix(2) { api.appendPathComponent(part) }
            api.appendPathComponent("revision"); api.appendPathComponent(requestedRevision)
            var components = URLComponents(url: api, resolvingAgainstBaseURL: false)!; components.queryItems = [.init(name: "blobs", value: "true")]
            let (data, _) = try await request(components.url!, token: token)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let revision = object["sha"] as? String, let siblings = object["siblings"] as? [[String: Any]] else { throw LaunchError.message("模型仓库清单格式无法识别") }
            let files = siblings.compactMap { sibling -> RemoteFile? in
                guard let path = sibling["rfilename"] as? String, DownloadPaths.safeRelative(path) else { return nil }
                let lfs = sibling["lfs"] as? [String: Any]
                var address = URL(string: "https://huggingface.co")!
                for part in repository.components(separatedBy: "/") + ["resolve", revision] + path.components(separatedBy: "/") { address.appendPathComponent(part) }
                return .init(path: path, url: address, bytes: (sibling["size"] as? NSNumber)?.int64Value ?? (lfs?["size"] as? NSNumber)?.int64Value ?? 0, sha256: lfs?["sha256"] as? String)
            }
            guard !files.isEmpty else { throw LaunchError.message("仓库中没有可下载的文件") }
            return .init(site: .huggingface, repository: repository, revision: revision, files: files.sorted { $0.path < $1.path }, preferred: preferred)
        }
        if ["modelscope.cn", "www.modelscope.cn", "modelscope.ai", "www.modelscope.ai"].contains(url.host ?? "") && parts.first == "models" {
            guard parts.count >= 3 else { throw LaunchError.message("请粘贴完整 ModelScope 模型仓库地址") }
            let repository = parts[1] + "/" + parts[2]
            let revision = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Revision" || $0.name == "revision" }?.value ?? "master"
            var components = URLComponents(string: "https://\(url.host!)/api/v1/models/\(repository)/repo/files")!
            components.queryItems = [.init(name: "Revision", value: revision), .init(name: "Recursive", value: "true")]
            let (data, _) = try await request(components.url!, token: token)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let payload = object?["Data"] as? [String: Any]
            guard let entries = payload?["Files"] as? [[String: Any]] ?? object?["Data"] as? [[String: Any]], entries.count < 1000 else { throw LaunchError.message("仓库列表不完整或过大，请使用具体文件直链") }
            let files = entries.compactMap { entry -> RemoteFile? in
                guard entry["Type"] as? String != "tree", let path = entry["Path"] as? String, DownloadPaths.safeRelative(path) else { return nil }
                var address = URLComponents(string: "https://\(url.host!)/api/v1/models/\(repository)/repo")!
                address.queryItems = [.init(name: "Revision", value: revision), .init(name: "FilePath", value: path)]
                return .init(path: path, url: address.url!, bytes: (entry["Size"] as? NSNumber)?.int64Value ?? 0, sha256: entry["Sha256"] as? String)
            }
            guard !files.isEmpty else { throw LaunchError.message("未发现可下载的仓库文件") }
            return .init(site: .modelscope, repository: repository, revision: revision, files: files.sorted { $0.path < $1.path })
        }
        let filename = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "FilePath" }?.value ?? url.lastPathComponent
        guard DownloadPaths.safeRelative(filename), ["gguf", "safetensors", "onnx", "bin", "json", "model", "txt"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) else { throw LaunchError.message("其他网站请使用 GGUF、Safetensors 等模型文件的直接下载链接。") }
        return .init(site: .direct, repository: url.host!, revision: "direct", files: [.init(path: filename, url: url, bytes: 0)], preferred: filename)
    }
    static func suggested(_ listing: RemoteListing) -> Set<String> {
        if let preferred = listing.preferred { return [preferred] }
        let gguf = listing.files.filter { $0.path.hasSuffix(".gguf") && !URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("mmproj") }
        if gguf.count > 1 { return [] }
        if gguf.count == 1 { return Set(gguf.map(\.path) + listing.files.filter { $0.path.hasSuffix(".gguf") && URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("mmproj") }.map(\.path)) }
        return Set(listing.files.filter { !["py", "sh", "md", "ipynb"].contains(URL(fileURLWithPath: $0.path).pathExtension) }.map(\.path))
    }
}

struct TransferReceipt: Codable { var url: URL; var etag: String?; var total: Int64 }

final class DownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let file: RemoteFile; let destination: URL; let root: URL; let folder: String; let token: String
    var progress: @Sendable (Int64, Int64) -> Void
    let phase: @Sendable (DownloadTransferPhase) -> Void
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    private var session: URLSession?; private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?; private var digest = SHA256(); private var received: Int64 = 0; private var total: Int64 = 0
    private var receipt: TransferReceipt?; private var failure: Error?; private var lastProgress = Date.distantPast
    private let cancellationLock = NSLock()
    private var cancelled = false
    private let protocolClasses: [AnyClass]?
    private var writeLease: Int32 = -1
    var partial: URL { destination.appendingPathExtension("incomplete") }
    var receiptURL: URL { partial.appendingPathExtension("metadata.json") }
    var completedBytes: Int64 { received }
    init(file: RemoteFile, root: URL, folder: String, token: String = "", protocolClasses: [AnyClass]? = nil, phase: @escaping @Sendable (DownloadTransferPhase) -> Void = { _ in }, progress: @escaping @Sendable (Int64, Int64) -> Void) throws {
        self.file = file; self.root = root; self.folder = folder; self.token = token; self.progress = progress
        self.phase = phase
        self.protocolClasses = protocolClasses
        destination = try DownloadPaths.destination(root: root, folder: folder, file: file.path)
    }
    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in self.continuation = continuation; queue.addOperation { self.begin() } }
    }
    func cancel() { cancellationLock.lock(); cancelled = true; let current = task; cancellationLock.unlock(); current?.cancel() }
    private func checkCancelled() throws { cancellationLock.lock(); let value = cancelled; cancellationLock.unlock(); if value { throw CancellationError() } }
    private func begin() {
        do {
            try checkCancelled()
            _ = try DownloadPaths.destination(root: root, folder: folder, file: file.path)
            _ = try DownloadPaths.destination(root: root, folder: folder, file: file.path + ".incomplete")
            _ = try DownloadPaths.destination(root: root, folder: folder, file: file.path + ".incomplete.metadata.json")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            writeLease = try DownloadWriteLock.acquire(root: root, folder: folder, file: file.path)
            phase(.checking)
            if FileManager.default.fileExists(atPath: destination.path) {
                let size = Int64((try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                guard file.bytes > 0 && size == file.bytes else { throw DownloadResumeError.unavailable("目标文件已存在且大小不符，已保留：\(file.path)") }
                if let expected = file.sha256 { let h = try FileHandle(forReadingFrom: destination); defer { try? h.close() }; var existing = SHA256(); while let data = try h.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try checkCancelled(); existing.update(data: data) }; guard existing.finalize().map({ String(format: "%02x", $0) }).joined() == expected.lowercased() else { throw DownloadResumeError.unavailable("已有文件校验失败，已保留，请使用其他目录。") } }
                received = size; total = size; progress(received, total)
                finish(nil); return
            }
            receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(TransferReceipt.self, from: $0) }
            if FileManager.default.fileExists(atPath: partial.path) {
                let size = Int64((try partial.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                guard size == 0 || receipt?.url == file.url else { throw DownloadResumeError.unavailable("发现来源不同的未完成文件，已保留") }
                if size == 0 && receipt?.url != file.url { receipt = nil }
            } else { FileManager.default.createFile(atPath: partial.path, contents: nil) }
            if receipt == nil { receipt = .init(url: file.url, etag: nil, total: file.bytes) }
            try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
            handle = try FileHandle(forUpdating: partial); received = Int64(try handle!.seekToEnd())
            if received > 0 && receipt?.etag == nil && file.sha256 == nil { throw DownloadResumeError.unavailable("网站未提供校验信息，无法安全续传；现有文件已保留") }
            if received > 0 { try handle!.seek(toOffset: 0); while let data = try handle!.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try checkCancelled(); digest.update(data: data) }; try handle!.seekToEnd() }
            if file.sha256 != nil && file.bytes > 0 && received == file.bytes { total = file.bytes; try commit(); finish(nil); return }
            var request = URLRequest(url: file.url); request.timeoutInterval = 60
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range"); if let etag = receipt?.etag { request.setValue(etag, forHTTPHeaderField: "If-Range") } }
            let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForResource = 7 * 24 * 3600
            if let protocolClasses { configuration.protocolClasses = protocolClasses }
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            cancellationLock.lock(); task = session!.dataTask(with: request); let shouldCancel = cancelled; cancellationLock.unlock()
            if shouldCancel { finish(CancellationError()) } else { phase(.connecting); task!.resume() }
        } catch { finish(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" || (file.url.host == "127.0.0.1" && request.url?.host == "127.0.0.1") else { failure = LaunchError.message("下载地址重定向到非 HTTPS 网站，已停止"); completionHandler(nil); return }
        var next = request; if request.url?.host != file.url.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }; completionHandler(next)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else { throw LaunchError.message("下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），未完成文件已保留") }
            guard response.mimeType != "text/html" else { throw LaunchError.message("此链接返回网页，请使用模型文件的直接下载链接") }
            if response.statusCode == 206 {
                if let old = receipt?.etag, let new = response.value(forHTTPHeaderField: "ETag"), old != new { throw DownloadResumeError.unavailable("续传文件版本已经变化，现有文件已保留") }
                let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                let pieces = range.replacingOccurrences(of: "bytes ", with: "").components(separatedBy: "/")
                guard pieces.count == 2, let start = Int64(pieces[0].components(separatedBy: "-")[0]), start == received, let length = Int64(pieces[1]), length >= received else { throw LaunchError.message("服务器返回的续传位置异常，已停止写入") }
                total = length
            } else {
                if received > 0 { throw DownloadResumeError.unavailable("网站未接受续传请求，现有文件已保留") }
                total = response.expectedContentLength > 0 ? response.expectedContentLength : file.bytes
            }
            if file.bytes > 0 && total > 0 && total != file.bytes { throw LaunchError.message("文件大小与仓库清单不一致，已停止下载，请重新解析仓库") }
            receipt = .init(url: file.url, etag: response.value(forHTTPHeaderField: "ETag"), total: total)
            try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
            phase(.downloading); progress(received, total); completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle!.write(contentsOf: data); digest.update(data: data); received += Int64(data.count)
            if total > 0 && received > total { throw LaunchError.message("服务器发送的数据超过声明大小，已停止下载") }
            if Date().timeIntervalSince(lastProgress) > 0.25 { progress(received, total); lastProgress = Date() }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            if let failure { throw failure }; if let error { throw error }
            try commit(); finish(nil)
        } catch { finish(error) }
    }
    private func commit() throws {
            try checkCancelled()
            phase(.verifying)
            try handle?.synchronize(); try handle?.close(); handle = nil
            guard total <= 0 || total == received else { throw LaunchError.message("下载不完整，未完成文件已保留，可继续下载") }
            if let expected = file.sha256 { guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected.lowercased() else { throw DownloadResumeError.unavailable("SHA-256 校验失败，现有文件已保留") } }
            if file.path.lowercased().hasSuffix(".gguf") { let h = try FileHandle(forReadingFrom: partial); defer { try? h.close() }; guard try h.read(upToCount: 4) == Data("GGUF".utf8) else { throw LaunchError.message("下载内容不是有效 GGUF，已保留供检查") } }
            _ = try DownloadPaths.destination(root: root, folder: folder, file: file.path)
            try FileManager.default.moveItem(at: partial, to: destination)
            try? FileManager.default.removeItem(at: receiptURL)
            progress(received, total)
    }
    private func finish(_ error: Error?) {
        try? handle?.close(); handle = nil
        if writeLease >= 0 { DownloadWriteLock.release(writeLease); writeLease = -1 }
        let continuation = self.continuation; self.continuation = nil
        cancellationLock.lock(); let currentSession = session; task = nil; session = nil; cancellationLock.unlock()
        currentSession?.finishTasksAndInvalidate()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

@MainActor
final class DownloadController: ObservableObject {
    @Published var address = ""
    @Published var token = ""
    @Published var destination = Scanner.defaultRoot.path
    @Published var listing: RemoteListing?
    /// 任务详情中文件列表的展开状态；未设置时下载中展开、已完成收起。
    @Published var fileListExpanded: [String: Bool] = [:]
    @Published var selected = Set<String>()
    @Published var resolving = false
    @Published var message: String?
    @Published var jobs: [ModelDownload] = []
    @Published var activeID: String?
    @Published var speeds: [String: Double] = [:]
    @Published var notice: String?
    @Published var deletingIDs = Set<String>()
    @Published var selectedTaskID: String?
    @Published var transferPhases: [String: DownloadTransferPhase] = [:]
    private var transfer: DownloadTransfer?
    private var pauseRequested = false
    private var interruptedFile: (id: String, path: String)?
    private var speedTimer: Timer?
    private var rate = DownloadRate()
    private var networkBytes: Int64 = 0
    private var fileBaseline: Int64?
    private var speedGeneration = UUID()
    private let stateURL: URL
    var onImported: ((String) -> Void)?
    var onRepair: ((ModelDownload) throws -> Void)?
    var transferProtocolClasses: [AnyClass]?
    var directory: URL { stateURL.deletingLastPathComponent() }
    init(directory: URL) {
        stateURL = directory.appendingPathComponent("downloads.json")
        jobs = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([ModelDownload].self, from: $0) } ?? []
        for index in jobs.indices {
            if jobs[index].state == .downloading { jobs[index].state = .paused }
            do { jobs[index] = try DownloadRecovery.reconcile(jobs[index]) }
            catch let error as DownloadResumeError { jobs[index].resumeBlockedReason = error.localizedDescription; jobs[index].error = error.localizedDescription }
            catch { jobs[index].error = error.localizedDescription }
        }
        selectedTaskID = jobs.first?.id
    }
    var selectedFiles: [RemoteFile] { listing?.files.filter { selected.contains($0.id) } ?? [] }
    func speedLabel(_ id: String) -> String {
        guard activeID == id else { return "—" }
        let value = speeds[id] ?? 0
        return sizeLabel(Int64(min(Double(Int64.max / 2), max(0, value.isFinite ? value : 0)))) + "/s"
    }
    @discardableResult func save() -> Bool { do { try JSONEncoder().encode(jobs).write(to: stateURL, options: .atomic); return true } catch { message = "下载任务保存失败：\(error.localizedDescription)"; return false } }
    private func synchronizeSharedProgress(_ id: String) {
        guard let source = jobs.first(where: { $0.id == id }) else { return }
        for index in jobs.indices where jobs[index].id != id {
            guard URL(fileURLWithPath: jobs[index].root).standardizedFileURL == URL(fileURLWithPath: source.root).standardizedFileURL,
                  jobs[index].folder == source.folder, DownloadRecovery.sameFiles(jobs[index].files, source.files) else { continue }
            for fileIndex in jobs[index].files.indices {
                if let file = source.files.first(where: { $0.path == jobs[index].files[fileIndex].path }) { jobs[index].files[fileIndex].bytes = file.bytes }
            }
            jobs[index].received = source.received; jobs[index].finished = source.finished; jobs[index].currentFile = source.currentFile
            jobs[index].fileReceived = source.fileReceived
            if source.state == .complete { jobs[index].state = .complete; jobs[index].error = nil; jobs[index].resumeBlockedReason = nil }
        }
    }
    func resolve() {
        guard !resolving else { return }; resolving = true; message = nil; listing = nil; selected = []; selectedTaskID = nil
        address = ModelCatalog.normalizedAddress(address)
        let input = address; let credential = token
        Task { do { let result = try await ModelCatalog.listing(input, token: credential); if address == input { listing = result; selected = ModelCatalog.suggested(result) } } catch { message = error.localizedDescription }; resolving = false }
    }
    func createJob() {
        guard let listing, !selectedFiles.isEmpty, activeID == nil else { return }
        message = nil; notice = nil
        let root = URL(fileURLWithPath: destination).resolvingSymlinksInPath().standardizedFileURL
        let matches = matching(listing: listing, files: selectedFiles, root: root)
        for candidate in matches {
            guard candidate.resumeBlockedReason == nil else { continue }
            do {
                var restored = try DownloadRecovery.reconcile(candidate)
                // Use fresh size/hash information while keeping the task and file locations.
                restored.files = selectedFiles.map { fresh in var file = fresh; if file.bytes == 0 { file.bytes = candidate.files.first { $0.path == fresh.path }?.bytes ?? 0 }; return file }
                restored.pausedFiles = []
                if let i = jobs.firstIndex(where: { $0.id == candidate.id }) { jobs[i] = restored }
                notice = "已使用现有任务，保留已下载进度。"; selectedTaskID = candidate.id; run(candidate.id, allowReplacement: true); return
            } catch let error as DownloadResumeError {
                if let i = jobs.firstIndex(where: { $0.id == candidate.id }) { jobs[i].resumeBlockedReason = error.localizedDescription; jobs[i].error = error.localizedDescription }
            } catch { message = error.localizedDescription; return }
        }
        add(listing: listing, files: selectedFiles, root: root, replacing: matches.first)
    }
    private func matching(listing: RemoteListing, files: [RemoteFile], root: URL) -> [ModelDownload] {
        jobs.enumerated().filter { !deletingIDs.contains($0.element.id) && DownloadRecovery.matches($0.element, listing: listing, files: files, root: root) }.sorted { left, right in
            func order(_ state: DownloadState) -> Int { state == .paused ? 0 : state == .failed ? 1 : 2 }
            let l = left.element, r = right.element
            if order(l.state) != order(r.state) { return order(l.state) < order(r.state) }
            let lb = (try? DownloadRecovery.reconcile(l).received) ?? l.received, rb = (try? DownloadRecovery.reconcile(r).received) ?? r.received
            if lb != rb { return lb > rb }
            if l.received != r.received { return l.received > r.received }
            return left.offset > right.offset
        }.map(\.element)
    }
    var preferredPausedTask: ModelDownload? {
        guard activeID == nil, let listing, !selectedFiles.isEmpty else { return nil }
        let root = URL(fileURLWithPath: destination).resolvingSymlinksInPath().standardizedFileURL
        return matching(listing: listing, files: selectedFiles, root: root).first { $0.state == .paused && $0.resumeBlockedReason == nil && (try? DownloadRecovery.reconcile($0)) != nil }
    }
    private func add(listing: RemoteListing, files: [RemoteFile], root: URL, replacing old: ModelDownload?) {
        guard activeID == nil else { return }
        let folder = DownloadRecovery.folder(listing: listing, recovery: old != nil)
        var job = ModelDownload(site: listing.site, repository: listing.repository, revision: listing.revision, root: root.path, folder: folder, files: files)
        job.replacementOf = old?.id
        job.pausedFiles = old?.pausedFiles; job.priorityFile = old?.priorityFile
        do {
            for file in job.files { _ = try DownloadPaths.destination(root: root, folder: folder, file: file.path); try DownloadPaths.validateURL(file.url) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let old {
                notice = "原任务无法续传，已在独立目录重新下载；原文件保留。"
                // Reuse complete files; the worker hashes these before accepting them.
                for file in files where old.finished.contains(file.path) && file.path != old.currentFile {
                    guard let source = try? DownloadPaths.destination(root: URL(fileURLWithPath: old.root), folder: old.folder, file: file.path),
                          let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, file.bytes > 0, Int64(size) == file.bytes else { continue }
                    let target = try DownloadPaths.destination(root: root, folder: folder, file: file.path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.linkItem(at: source, to: target)
                }
            }
        } catch { message = error.localizedDescription; return }
        jobs.insert(job, at: 0); guard save() else { return }; run(job.id, allowReplacement: false)
    }
    @discardableResult
    func createRepair(file: RemoteFile, source: ModelOrigin, target: URL, modelID: String) throws -> ModelDownload {
        if let prior = jobs.first(where: { $0.repairTarget == target.path && $0.state != .complete && $0.repairFingerprint == (try? RepairFingerprint.read(target)) }) { selectedTaskID = prior.id; return prior }
        guard target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == target.deletingLastPathComponent().standardizedFileURL.path else { throw LaunchError.message("修复目录包含链接") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = target.deletingLastPathComponent().appendingPathComponent(".model-manager-repairs").standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else { throw LaunchError.message("修复暂存目录包含链接，请检查模型位置") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var job = ModelDownload(site: source.site, repository: source.repository, revision: source.revision, root: root.path, folder: UUID().uuidString + "/snapshots/" + source.revision, files: [file])
        job.repairTarget = target.path; job.repairFingerprint = try RepairFingerprint.read(target); job.repairModelID = modelID
        _ = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path); try DownloadPaths.validateURL(file.url)
        jobs.insert(job, at: 0); selectedTaskID = job.id
        guard save() else { throw LaunchError.message("修复任务未能保存") }
        if activeID == nil { run(job.id, allowReplacement: false) }
        else { notice = "单文件修复任务已创建；当前下载结束后可点“继续下载”。" }
        return job
    }
    func resume(_ id: String, includingPausedFiles: Bool = false) {
        guard activeID == nil, !deletingIDs.contains(id), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        message = nil; notice = nil
        if includingPausedFiles { jobs[index].pausedFiles = [] }
        let job = jobs[index]
        do {
            guard job.resumeBlockedReason == nil else { throw DownloadResumeError.unavailable(job.resumeBlockedReason!) }
            jobs[index] = try DownloadRecovery.reconcile(job); run(id, allowReplacement: job.replacementOf == nil)
        } catch let error as DownloadResumeError {
            jobs[index].resumeBlockedReason = error.localizedDescription; jobs[index].error = error.localizedDescription
            add(listing: .init(site: job.site, repository: job.repository, revision: job.revision, files: job.files), files: job.files, root: URL(fileURLWithPath: job.root).resolvingSymlinksInPath().standardizedFileURL, replacing: job)
        } catch { message = error.localizedDescription }
    }
    private func run(_ id: String, allowReplacement: Bool) {
        guard activeID == nil, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        activeID = id; pauseRequested = false; interruptedFile = nil; jobs[index].state = .downloading; jobs[index].error = nil
        selectedTaskID = id
        guard save() else { activeID = nil; jobs[index].state = .paused; return }
        let original = jobs[index], generation = UUID(); speedGeneration = generation
        rate = DownloadRate(); networkBytes = 0; fileBaseline = nil; speeds[id] = 0
        speedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.activeID == id, !self.pauseRequested, self.fileBaseline != nil else { return }
            guard self.transferPhases[id] == .downloading else { self.speeds[id] = 0; return }
            self.speeds[id] = self.rate.record(bytes: self.networkBytes, at: ProcessInfo.processInfo.systemUptime)
        } }
        speedTimer = timer; RunLoop.main.add(timer, forMode: .common)
        let credential = token
        Task {
            var replacement: ModelDownload?
            do {
                let root = URL(fileURLWithPath: original.root)
                while true {
                    guard let current = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    if pauseRequested { throw CancellationError() }
                    let pending = jobs[current].files.filter { !jobs[current].finished.contains($0.path) && !(jobs[current].pausedFiles?.contains($0.path) ?? false) }
                    guard let file = pending.first(where: { $0.path == jobs[current].priorityFile }) ?? pending.first else { break }
                    jobs[current].currentFile = file.path; fileBaseline = nil
                    rate = DownloadRate(); networkBytes = 0; speeds[id] = 0; transferPhases[id] = .checking
                    let fileGeneration = UUID(); speedGeneration = fileGeneration
                    try DownloadPaths.validateURL(file.url)
                    let eligible = ["huggingface.co", "modelscope.cn", "www.modelscope.cn", "modelscope.ai", "www.modelscope.ai"].contains(file.url.host ?? "")
                    let worker = try DownloadTransfer(file: file, root: root, folder: original.folder, token: eligible ? credential : "", protocolClasses: transferProtocolClasses, phase: { [weak self = self] phase in
                        Task { @MainActor in
                            guard let self, self.activeID == id, self.speedGeneration == fileGeneration else { return }
                            self.transferPhases[id] = phase
                            if phase != .downloading { self.speeds[id] = 0 }
                        }
                    }) { [weak self = self] received, total in
                        Task { @MainActor in
                            guard let self, self.activeID == id, self.speedGeneration == fileGeneration, let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .downloading else { return }
                            if let baseline = self.fileBaseline, received < baseline { return }
                            var counts = self.jobs[i].fileReceived ?? [:]; counts[file.path] = received; self.jobs[i].fileReceived = counts
                            self.jobs[i].received = counts.values.reduce(0, +)
                            if let baseline = self.fileBaseline { self.networkBytes += max(0, received - baseline) }
                            self.fileBaseline = received
                            self.speeds[id] = self.rate.record(bytes: self.networkBytes, at: ProcessInfo.processInfo.systemUptime)
                            if self.pauseRequested { self.speeds[id] = 0 }
                            if self.transferPhases[id] != .downloading { self.speeds[id] = 0 }
                            if total > 0, let f = self.jobs[i].files.firstIndex(where: { $0.path == file.path }), self.jobs[i].files[f].bytes == 0 { self.jobs[i].files[f].bytes = total }
                            self.synchronizeSharedProgress(id)
                        }
                    }
                    transfer = worker
                    do { try await worker.run() }
                    catch {
                        transfer = nil; speedGeneration = UUID()
                        if interruptedFile?.id == id && interruptedFile?.path == file.path && !pauseRequested {
                            interruptedFile = nil
                            guard let i = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                            jobs[i] = try DownloadRecovery.reconcile(jobs[i]); jobs[i].currentFile = ""
                            synchronizeSharedProgress(id); save()
                            continue
                        }
                        throw error
                    }
                    transfer = nil; interruptedFile = nil
                    guard let current = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    if let f = jobs[current].files.firstIndex(where: { $0.path == file.path }), jobs[current].files[f].bytes == 0 { jobs[current].files[f].bytes = worker.completedBytes }
                    jobs[current].finished.insert(file.path)
                    jobs[current].pausedFiles?.remove(file.path)
                    if jobs[current].priorityFile == file.path { jobs[current].priorityFile = nil }
                    var counts = jobs[current].fileReceived ?? [:]; counts[file.path] = worker.completedBytes; jobs[current].fileReceived = counts
                    jobs[current].received = counts.values.reduce(0, +); synchronizeSharedProgress(id); save()
                }
                if pauseRequested { throw CancellationError() }
                if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].finished.count < jobs[i].files.count {
                    jobs[i].currentFile = ""
                    throw DownloadFilesSuspended()
                }
                if original.site != .direct {
                    let receipt = try DownloadPaths.destination(root: root, folder: original.folder, file: "model-manager-source.json")
                    let origin = ModelOrigin(site: original.site, repository: original.repository, revision: original.revision, files: original.files.map(\.path))
                    try JSONEncoder().encode(origin).write(to: receipt, options: .atomic)
                }
                if original.site == .huggingface {
                    let parts = original.folder.components(separatedBy: "/")
                    guard let snapshot = parts.lastIndex(of: "snapshots"), snapshot > 0 else { throw LaunchError.message("模型快照目录无效") }
                    let refs = parts.prefix(snapshot).joined(separator: "/") + "/refs"
                    let ref = try DownloadPaths.destination(root: root, folder: refs, file: "main")
                    try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(original.revision.utf8).write(to: ref, options: .atomic)
                }
                if let i = jobs.firstIndex(where: { $0.id == id }) {
                    if jobs[i].repairTarget != nil { guard let onRepair else { throw LaunchError.message("修复文件已下载；请在管理界面继续任务以应用修复") }; try onRepair(jobs[i]) }
                    jobs[i].state = .complete; jobs[i].currentFile = ""; jobs[i].received = jobs[i].total
                    if jobs[i].repairTarget == nil { onImported?(jobs[i].root) }
                }
            } catch {
                if let i = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[i].state = pauseRequested || error is CancellationError || error is DownloadFilesSuspended ? .paused : .failed
                    jobs[i].error = jobs[i].state == .failed ? error.localizedDescription : nil
                    if let restored = try? DownloadRecovery.reconcile(jobs[i]) { jobs[i] = restored }
                    if error is DownloadFilesSuspended { notice = "其余文件已下载，剩余文件已单独暂停。可在文件详情中继续。"; if jobs[i].finished.isEmpty { notice = "所有文件已暂停，可在文件详情中继续。"} }
                    if error is DownloadResumeError && !pauseRequested {
                        jobs[i].resumeBlockedReason = error.localizedDescription
                        if allowReplacement && jobs[i].replacementOf == nil && !deletingIDs.contains(id) { replacement = jobs[i] }
                    }
                }
            }
            synchronizeSharedProgress(id)
            transfer = nil; interruptedFile = nil; activeID = nil; speedGeneration = UUID(); speeds.removeValue(forKey: id); transferPhases.removeValue(forKey: id); speedTimer?.invalidate(); speedTimer = nil; save()
            if let job = replacement { add(listing: .init(site: job.site, repository: job.repository, revision: job.revision, files: job.files), files: job.files, root: URL(fileURLWithPath: job.root), replacing: job) }
        }
    }
    func pause() { pauseRequested = true; if let id = activeID { speeds[id] = 0 }; transfer?.cancel() }
    func canControlFiles(_ id: String) -> Bool { !deletingIDs.contains(id) && (activeID == nil || activeID == id) && !(activeID == id && pauseRequested) }
    func pauseFile(_ id: String, path: String) {
        guard canControlFiles(id), let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].files.contains(where: { $0.path == path }), !jobs[i].finished.contains(path) else { return }
        var paused = jobs[i].pausedFiles ?? []; paused.insert(path); jobs[i].pausedFiles = paused
        if jobs[i].priorityFile == path { jobs[i].priorityFile = nil }
        if activeID == id && jobs[i].currentFile == path { interruptedFile = (id, path); speeds[id] = 0; transfer?.cancel() }
        save()
    }
    func resumeFile(_ id: String, path: String, first: Bool = false) {
        guard canControlFiles(id), let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].files.contains(where: { $0.path == path }), !jobs[i].finished.contains(path) else { return }
        jobs[i].pausedFiles?.remove(path)
        if first { jobs[i].priorityFile = path }
        if activeID == id && first && jobs[i].currentFile != path {
            interruptedFile = (id, jobs[i].currentFile); speeds[id] = 0; transfer?.cancel()
        }
        save()
        if activeID == nil { resume(id) }
    }
    func resumeAllFiles(_ id: String) {
        guard canControlFiles(id), let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].pausedFiles = []; save()
        if activeID == nil { resume(id) }
    }
    func showTask(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        selectedTaskID = id
        destination = job.root
        listing = .init(site: job.site, repository: job.repository, revision: job.revision, files: job.files)
        selected = Set(job.files.map(\.path))
        address = job.site == .huggingface ? "https://huggingface.co/\(job.repository)/tree/\(job.revision)" : job.site == .modelscope ? "https://modelscope.cn/models/\(job.repository)?Revision=\(job.revision)" : job.files.first?.url.absoluteString ?? ""
    }
    func removeTask(_ id: String) async throws {
        guard jobs.contains(where: { $0.id == id }), !deletingIDs.contains(id) else { return }
        deletingIDs.insert(id); defer { deletingIDs.remove(id) }
        if activeID == id {
            pause()
            let deadline = Date().addingTimeInterval(10)
            while activeID == id && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            guard activeID != id else { throw LaunchError.message("任务仍在停止，请稍后再删除") }
        }
        jobs.removeAll { $0.id == id }; speeds.removeValue(forKey: id)
        if selectedTaskID == id { selectedTaskID = activeID ?? jobs.first?.id }
        guard save() else { throw LaunchError.message(message ?? "删除任务未能保存") }
        notice = "任务记录已删除，已下载文件和未完成文件保留。"
    }
    func cleanPartials(_ id: String) throws {
        guard activeID != id, let job = jobs.first(where: { $0.id == id }) else { throw LaunchError.message("请先暂停任务，再清理未完成文件") }
        if let active = jobs.first(where: { $0.id == activeID }), active.root == job.root && (EngineMaintenance.contains(active.folder, job.folder) || EngineMaintenance.contains(job.folder, active.folder)) { throw LaunchError.message("另一个任务正在使用此目录，请先暂停下载") }
        let root = URL(fileURLWithPath: job.root)
        var deletions: [(URL, FileIdentity)] = [], locks: [Int32] = []
        defer { for lock in locks { DownloadWriteLock.release(lock) } }
        for file in job.files {
            let partial = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path + ".incomplete")
            let metadata = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path + ".incomplete.metadata.json")
            let hasPartial = FileManager.default.fileExists(atPath: partial.path), hasMetadata = FileManager.default.fileExists(atPath: metadata.path)
            guard hasPartial || hasMetadata else { continue }
            let shared = jobs.contains { other in
                guard other.id != id else { return false }
                return other.files.contains { entry in
                    (try? DownloadPaths.destination(root: URL(fileURLWithPath: other.root), folder: other.folder, file: entry.path + ".incomplete").path) == partial.path
                }
            }
            guard !shared else { throw LaunchError.message("此未完成文件还被其他任务共用。可先删除多余的任务记录，文件会保留。") }
            locks.append(try DownloadWriteLock.acquire(root: root, folder: job.folder, file: file.path))
            if hasPartial || hasMetadata {
                let receipt = (try? Data(contentsOf: metadata)).flatMap { try? JSONDecoder().decode(TransferReceipt.self, from: $0) }
                guard receipt?.url == file.url else { throw LaunchError.message("未完成文件的归属无法确认，已保留") }
            }
            for path in [partial, metadata] where FileManager.default.fileExists(atPath: path.path) {
                guard let identity = FileIdentity.read(path.path) else { throw LaunchError.message("未完成文件已变化，请重新检查") }
                deletions.append((path, identity))
            }
        }
        for (path, identity) in deletions { guard FileIdentity.read(path.path) == identity else { throw LaunchError.message("未完成文件已变化，已停止清理") } }
        for (path, _) in deletions { try FileManager.default.removeItem(at: path) }
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].error = nil; jobs[i].state = .paused
            if let restored = try? DownloadRecovery.reconcile(jobs[i]) { jobs[i] = restored }
        }
        save()
    }
}
