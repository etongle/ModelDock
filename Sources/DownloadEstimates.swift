import Foundation

/// Uses recent network throughput, excluding bytes that were already on disk when resuming.
enum DownloadEstimate {
    static func seconds(remaining: Int64, speed: Double) -> TimeInterval? {
        guard remaining > 0, speed.isFinite, speed > 0 else { return nil }
        let seconds = ceil(Double(remaining) / speed)
        guard seconds.isFinite, seconds <= Double(Int.max / 2) else { return nil }
        return max(1, seconds)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        let calendar = Calendar(identifier: .gregorian)
        var localized = calendar; localized.locale = L10n.locale; formatter.calendar = localized
        formatter.unitsStyle = .abbreviated; formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        return formatter.string(from: max(1, seconds)) ?? "—"
    }
}

@MainActor
extension DownloadController {
    func remainingTimeLabel(_ job: ModelDownload) -> String {
        if job.state == .complete { return L10n.text("已完成") }
        if job.state == .queued { return L10n.text("等待开始") }
        if !isActive(job.id) { return L10n.text(job.state.rawValue) }
        if retryStatuses[job.id] != nil { return L10n.text("等待自动续传") }
        switch transferPhases[job.id] {
        case .checking, .verifying: return L10n.text("校验中")
        case .connecting: return L10n.text("连接中")
        default: break
        }
        let remaining = job.files.filter { !job.finished.contains($0.path) && job.pausedFiles?.contains($0.path) != true }
        guard !remaining.isEmpty else { return L10n.text("已暂停") }
        guard remaining.allSatisfy({ $0.bytes > 0 }) else { return L10n.text("大小待确认") }
        let bytes = remaining.reduce(Int64(0)) { $0 + max(0, $1.bytes - (job.fileReceived?[$1.path] ?? 0)) }
        if bytes == 0 { return L10n.text("校验中") }
        guard let seconds = DownloadEstimate.seconds(remaining: bytes, speed: speeds[job.id] ?? 0) else { return L10n.text("估算中") }
        let time = DownloadEstimate.duration(seconds)
        return (job.pausedFiles ?? []).isEmpty ? L10n.format("约剩余 {0}", [time]) : L10n.format("本轮约剩余 {0}，另有暂停文件", [time])
    }
}
