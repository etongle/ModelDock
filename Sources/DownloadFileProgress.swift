import Foundation

enum DownloadTransferPhase { case checking, connecting, downloading, verifying }
struct DownloadFilesSuspended: Error {}
enum DownloadFileState: String {
    case complete = "已完成", downloading = "下载中", checking = "校验中", connecting = "连接中"
    case paused = "已暂停", waiting = "等待继续", notStarted = "未下载", unverified = "待校验", failed = "需重试"
    var processing: Bool { self == .downloading || self == .checking || self == .connecting }
    var symbol: String {
        switch self {
        case .complete: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .checking, .unverified: return "checkmark.shield"
        case .connecting, .waiting: return "clock"
        case .paused: return "pause.circle"
        case .notStarted: return "circle"
        case .failed: return "exclamationmark.circle"
        }
    }
}
struct DownloadFileProgress: Identifiable {
    var id: String { file.path }
    var file: RemoteFile
    var state: DownloadFileState
    var received: Int64
    var speed: Double?
    var error: String?
    var percentage: Double? {
        if state == .complete { return 100 }
        return file.bytes > 0 ? min(100, max(0, Double(received) / Double(file.bytes) * 100)) : nil
    }
    var percentageLabel: String { percentage.map { String(format: "%.1f%%", locale: L10n.locale, $0) } ?? "总量待确认" }
}

@MainActor
extension DownloadController {
    var detailJob: ModelDownload? { jobs.first { $0.id == selectedTaskID } }
    func fileProgress(_ file: RemoteFile, in job: ModelDownload) -> DownloadFileProgress {
        let received = max(0, job.fileReceived?[file.path] ?? (job.finished.contains(file.path) ? file.bytes : 0))
        var result = DownloadFileProgress(file: file, state: .notStarted, received: received)
        if job.finished.contains(file.path) { result.state = .complete; return result }
        if job.pausedFiles?.contains(file.path) == true { result.state = .paused; return result }
        let writer = jobs.first { candidate in
            candidate.id == activeID && candidate.state == .downloading &&
            candidate.currentFile == file.path &&
            URL(fileURLWithPath: candidate.root).standardizedFileURL == URL(fileURLWithPath: job.root).standardizedFileURL &&
            candidate.folder == job.folder && candidate.files.contains { $0.path == file.path && $0.url == file.url }
        }
        if let writer {
            switch transferPhases[writer.id] ?? .checking {
            case .checking, .verifying: result.state = .checking
            case .connecting: result.state = .connecting
            case .downloading: result.state = .downloading; result.speed = speeds[writer.id] ?? 0
            }
        } else if job.state == .failed && job.currentFile == file.path {
            result.state = .failed; result.error = job.error
        } else if file.bytes > 0 && received >= file.bytes {
            result.state = .unverified
        } else if received > 0 || (job.state == .paused && job.currentFile == file.path) {
            result.state = job.state == .paused || job.state == .failed ? .paused : .waiting
        }
        return result
    }
    func fileProgress(in job: ModelDownload) -> [DownloadFileProgress] { job.files.map { fileProgress($0, in: job) } }
}
