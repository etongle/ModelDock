import Foundation
@preconcurrency import UserNotifications

/// Posts macOS notifications for background events: downloads finished or failed, services ready,
/// failed to start or exited unexpectedly. It diffs state snapshots, so the download and service code
/// need no notification hooks; the first snapshot only primes the baseline (no alerts at launch).
@MainActor
final class AppNotifier {
    private var downloadStates: [String: DownloadState]?
    private var serviceStatuses: [String: ServiceStatus]?
    var enabled: () -> Bool = { true }
    /// Overridden by checks to record notifications instead of delivering them.
    var deliver: ((String, String) -> Void)?

    func observe(downloads jobs: [ModelDownload]) {
        defer { downloadStates = Dictionary(jobs.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last }) }
        guard let previous = downloadStates else { return }
        for job in jobs {
            guard let old = previous[job.id], old != job.state else { continue }
            if job.state == .complete { post("下载完成", job.repository) }
            else if job.state == .failed { post("下载失败", job.repository + (job.error.map { " · " + L10n.text($0) } ?? "")) }
        }
    }

    func observe(services statuses: [String: ServiceStatus], controller: ServiceController, name: (String) -> String) {
        defer { serviceStatuses = statuses }
        guard let previous = serviceStatuses else { return }
        for (id, status) in statuses {
            guard let old = previous[id], old != status else { continue }
            if status == .starting { controller.stopRequested.remove(id) }
            if old == .starting && status == .running { post("服务已就绪", name(id)) }
            else if old == .starting && status == .failed { post("服务启动失败", name(id)) }
            else if old == .running && (status == .stopped || status == .failed) {
                // Requested stops (UI, context restart, rollbacks) are expected; anything else is an unexpected exit.
                if controller.stopRequested.remove(id) == nil { post("服务意外退出", name(id)) }
            }
        }
    }

    private func post(_ title: String, _ body: String) {
        guard enabled() else { return }
        if let deliver { deliver(title, body); return }
        let content = UNMutableNotificationContent(); content.title = L10n.text(title); content.body = body; content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        // The first post asks for permission; macOS remembers the answer.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { center.add(request) } }
    }
}
