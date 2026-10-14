import SwiftUI

@MainActor
struct StatusDownloads: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloads: DownloadController
    var current: ModelDownload? {
        downloads.jobs.first { $0.id == downloads.activeID } ??
        downloads.jobs.first { $0.state != .complete } ?? downloads.jobs.first
    }
    var body: some View {
        if !downloads.jobs.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.text("下载任务 · \(downloads.jobs.count)"), systemImage: "arrow.down.circle").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(L10n.text("管理下载")) { manage() }.font(.system(size: 12)).buttonStyle(.bordered).accessibilityIdentifier("status-manage-downloads")
                }
                if let job = current {
                    HStack { Text(job.repository).font(.system(size: 12, weight: .medium)).lineLimit(1).help(L10n.text(job.repository)); Spacer(); Text(verbatim: L10n.text(job.state.rawValue)).font(.system(size: 11)).foregroundStyle(Theme.linkColor) }
                    if job.totalKnown && job.total > 0 { ProgressView(value: min(Double(job.received), Double(job.total)), total: Double(job.total)).tint(Theme.accent) }
                    HStack {
                        Text(verbatim: L10n.text(job.percentageLabel))
                        Spacer()
                        Text(verbatim: L10n.text(job.totalKnown ? "\(sizeLabel(job.received)) / \(sizeLabel(job.total))" : sizeLabel(job.received)))
                    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted).accessibilityIdentifier("status-download-progress")
                    HStack {
                        Text(verbatim: L10n.text("下载速度 " + downloads.speedLabel(job.id))).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.linkColor)
                        Spacer()
                        if downloads.activeID == job.id { Button(L10n.text("暂停")) { downloads.pause() }.buttonStyle(.bordered).controlSize(.small) }
                        else if job.state != .complete { Button(L10n.text(job.resumeBlockedReason != nil ? "重新下载" : (job.pausedFiles ?? []).isEmpty ? "继续" : "继续全部")) { downloads.resume(job.id, includingPausedFiles: true) }.buttonStyle(.bordered).controlSize(.small).disabled(downloads.activeID != nil || downloads.deletingIDs.contains(job.id)) }
                    }.accessibilityIdentifier("status-download-speed")
                    Text(verbatim: L10n.text(URL(fileURLWithPath: job.root).appendingPathComponent(job.folder).path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).help(L10n.text(URL(fileURLWithPath: job.root).appendingPathComponent(job.folder).path))
                    if let error = job.error { Text(verbatim: L10n.text(error)).font(.system(size: 11)).foregroundStyle(Theme.errorText).lineLimit(2) }
                }
            }.accessibilityIdentifier("status-download-management")
        }
    }
    func manage() {
        if let job = current { downloads.showTask(job.id) }
        store.tab = .downloads; store.showMainWindow?()
    }
}
