import Foundation
import Darwin

enum DownloadWriteLock {
    static func acquire(root: URL, folder: String, file: String) throws -> Int32 {
        let path = try DownloadPaths.destination(root: root, folder: folder, file: file + ".incomplete.lock")
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LaunchError.message("无法取得下载位置的写入锁：\(file)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw LaunchError.message("另一个任务正在写入此文件，请先暂停它：\(file)") }
        return descriptor
    }
    static func release(_ descriptor: Int32) { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}

enum DownloadResumeError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let reason) = self { return reason }; return nil }
}

extension ModelDownload {
    var totalKnown: Bool { state == .complete || (!files.isEmpty && files.allSatisfy { $0.bytes > 0 }) }
    var percentage: Double? {
        if state == .complete { return 100 }
        guard totalKnown, total > 0 else { return nil }
        return min(100, max(0, Double(received) / Double(total) * 100))
    }
    var percentageLabel: String { percentage.map { String(format: "%.1f%%", locale: L10n.locale, $0) } ?? "总量待确认" }
}

enum DownloadRecovery {
    static func sameFiles(_ left: [RemoteFile], _ right: [RemoteFile]) -> Bool {
        guard left.count == right.count, Set(left.map(\.path)).count == left.count else { return false }
        let other = Dictionary(grouping: right, by: \.path)
        return left.allSatisfy { file in
            guard let matches = other[file.path], matches.count == 1, let fresh = matches.first, file.url == fresh.url else { return false }
            if file.bytes > 0 && fresh.bytes > 0 && file.bytes != fresh.bytes { return false }
            if let sha = file.sha256, let updated = fresh.sha256, sha.lowercased() != updated.lowercased() { return false }
            return true
        }
    }
    static func matches(_ job: ModelDownload, listing: RemoteListing, files: [RemoteFile], root: URL) -> Bool {
        job.site == listing.site && job.repository == listing.repository && job.revision == listing.revision &&
        URL(fileURLWithPath: job.root).standardizedFileURL.path == root.path && sameFiles(job.files, files)
    }
    static func reconcile(_ original: ModelDownload) throws -> ModelDownload {
        var job = original; job.received = 0; job.fileReceived = [:]
        let root = URL(fileURLWithPath: job.root).standardizedFileURL
        guard root.path.hasPrefix("/"), !job.files.isEmpty, Set(job.files.map(\.path)).count == job.files.count else { throw DownloadResumeError.unavailable("任务的文件清单无效") }
        let fm = FileManager.default
        var finished = Set<String>()
        for file in job.files {
            let destination: URL, partial: URL, metadata: URL
            do {
                try DownloadPaths.validateURL(file.url)
                destination = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path)
                partial = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path + ".incomplete")
                metadata = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path + ".incomplete.metadata.json")
            } catch { throw DownloadResumeError.unavailable(error.localizedDescription) }
            if fm.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                let size = Int64(values.fileSize ?? 0)
                guard values.isRegularFile == true, file.bytes > 0, size == file.bytes else { throw DownloadResumeError.unavailable("已有文件大小与任务不符：\(file.path)") }
                job.received += size
                job.fileReceived?[file.path] = size
                if job.finished.contains(file.path) { finished.insert(file.path) }
                continue
            }
            if fm.fileExists(atPath: partial.path) {
                var identity = stat()
                guard lstat(partial.path, &identity) == 0, identity.st_nlink == 1 else { throw DownloadResumeError.unavailable("未完成文件与其他位置共用，已保留：\(file.path)") }
                let values = try partial.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]); let size = Int64(values.fileSize ?? 0)
                guard values.isRegularFile == true, file.bytes <= 0 || size <= file.bytes else { throw DownloadResumeError.unavailable("未完成文件大小异常：\(file.path)") }
                if size > 0 {
                    guard let receipt = (try? Data(contentsOf: metadata)).flatMap({ try? JSONDecoder().decode(TransferReceipt.self, from: $0) }), receipt.url == file.url else { throw DownloadResumeError.unavailable("未完成文件的来源记录无法核实：\(file.path)") }
                    guard file.sha256 != nil || receipt.etag != nil else { throw DownloadResumeError.unavailable("网站未提供校验信息，无法安全续传：\(file.path)") }
                    guard receipt.total <= 0 || size <= receipt.total else { throw DownloadResumeError.unavailable("未完成文件超过记录大小：\(file.path)") }
                }
                job.received += size
                job.fileReceived?[file.path] = size
            }
            if job.fileReceived?[file.path] == nil { job.fileReceived?[file.path] = 0 }
        }
        job.finished = finished
        if let paused = job.pausedFiles { job.pausedFiles = paused.intersection(Set(job.files.map(\.path))).subtracting(finished) }
        if let priority = job.priorityFile, finished.contains(priority) || !job.files.contains(where: { $0.path == priority }) { job.priorityFile = nil }
        if job.state == .complete && finished.count != job.files.count { job.state = .paused }
        return job
    }
    static func folder(listing: RemoteListing, recovery: Bool) -> String {
        let repo = listing.repository.replacingOccurrences(of: "/", with: "--")
        let standard = listing.site == .github ? "downloads/github/\(repo)/\(listing.revision)" : listing.site == .huggingface ? "hf-cache/hub/models--\(repo)/snapshots/\(listing.revision)" : "downloads/\(listing.site == .modelscope ? "modelscope" : "direct")/\(repo)/\(UUID().uuidString)"
        return recovery ? "downloads/recovered/\(UUID().uuidString)/" + standard : standard
    }
}

struct DownloadRate {
    private var samples: [(TimeInterval, Int64)] = []
    mutating func record(bytes: Int64, at time: TimeInterval) -> Double {
        if let last = samples.last, bytes < last.1 { samples = [] }
        samples.append((time, bytes))
        let cutoff = time - 3
        while samples.count > 2 && samples[1].0 <= cutoff { samples.removeFirst() }
        guard let first = samples.first, let last = samples.last, last.0 - first.0 >= 0.35 else { return 0 }
        return max(0, Double(last.1 - first.1) / min(3, last.0 - first.0))
    }
}
