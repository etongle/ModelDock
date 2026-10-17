import Foundation
import Combine
import CryptoKit
import Darwin

enum ModelSite: String, Codable { case github = "GitHub", huggingface = "Hugging Face", modelscope = "ModelScope", direct = "文件直链" }
struct RemoteFile: Identifiable, Codable, Hashable {
    var id: String { path }
    var path: String; var url: URL; var bytes: Int64; var sha256: String?
    var accept: String? = nil
}
struct RemoteListing {
    var site: ModelSite; var repository: String; var revision: String; var files: [RemoteFile]; var preferred: String?
    var sourceURL: String? = nil
}
enum DownloadState: String, Codable { case queued = "等待下载", paused = "已暂停", downloading = "下载中", complete = "已完成", failed = "需重试" }
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
    var sourceURL: String? = nil
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
        let (data, http) = try await CatalogHTTP.fetch(url, token: token)
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
        if ["github.com", "www.github.com", "raw.githubusercontent.com", "media.githubusercontent.com"].contains(url.host?.lowercased() ?? "") { return try await GitHubModels.listing(url, token: token) }
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
        return Set(listing.files.filter { listing.site == .github ? GitHubModels.isModelFile($0.path) : !["py", "sh", "md", "ipynb"].contains(URL(fileURLWithPath: $0.path).pathExtension) }.map(\.path))
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
            if file.accept == "application/octet-stream", file.url.host == "api.github.com" { request.setValue(file.accept, forHTTPHeaderField: "Accept") }
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
            if received <= 1024, let data = try? Data(contentsOf: partial), String(data: data, encoding: .utf8)?.hasPrefix("version https://git-lfs.github.com/spec/v1") == true { throw LaunchError.message("下载到的是 Git LFS 指针，请重新解析 GitHub 地址以获取实际模型文件") }
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
