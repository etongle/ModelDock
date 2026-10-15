import Foundation

/// Offline checks for notification decisions; nothing is delivered and no permission is requested.
@MainActor
enum NotificationChecks {
    static func run() throws {
        let require = ConnectionChecks.require
        let notifier = AppNotifier()
        var posted: [String] = []
        notifier.deliver = { title, _ in posted.append(title) }
        let services = ServiceController(stateDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        func job(_ id: String, _ state: DownloadState) -> ModelDownload {
            var value = ModelDownload(site: .huggingface, repository: id, revision: "main", root: "/tmp", folder: id, files: [])
            value.id = id; value.state = state; return value
        }
        func statuses(_ values: [String: ServiceStatus]) { notifier.observe(services: values, controller: services) { $0 } }

        // Launch snapshot only primes the baseline.
        notifier.observe(downloads: [job("a", .complete), job("b", .downloading)])
        statuses(["s": .running, "t": .starting])
        try require(posted.isEmpty, "Notified for pre-existing state at launch")

        notifier.observe(downloads: [job("a", .complete), job("b", .complete)])
        notifier.observe(downloads: [job("a", .complete), job("b", .complete), job("c", .downloading)])
        notifier.observe(downloads: [job("a", .complete), job("b", .complete), job("c", .failed)])
        try require(posted == ["下载完成", "下载失败"], "Download transitions: \(posted)")

        posted = []
        statuses(["s": .running, "t": .running])
        try require(posted == ["服务已就绪"], "Service ready: \(posted)")

        // A requested stop that the 3 s poll sees as running → stopped (no .stopping in between) is not unexpected.
        posted = []; services.stopRequested.insert("s")
        statuses(["s": .stopped, "t": .running])
        try require(posted.isEmpty && !services.stopRequested.contains("s"), "Requested stop reported as unexpected: \(posted)")

        // An exit nobody asked for is reported; a failed start too.
        statuses(["s": .starting, "t": .stopped])
        try require(posted == ["服务意外退出"], "Unexpected exit missing: \(posted)")
        posted = []
        statuses(["s": .failed, "t": .stopped])
        try require(posted == ["服务启动失败"], "Failed start missing: \(posted)")

        // Disabled in Settings: nothing is posted.
        posted = []; notifier.enabled = { false }
        statuses(["s": .starting, "t": .stopped]); statuses(["s": .running, "t": .stopped])
        try require(posted.isEmpty, "Posted while disabled")
        print("Notification checks passed")
    }
}
