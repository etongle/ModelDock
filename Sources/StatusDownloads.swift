import SwiftUI

@MainActor
struct StatusDownloads: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloads: DownloadController
    /// The menu bar only surfaces work that still needs attention; finished jobs stay in Downloads.
    var current: ModelDownload? {
        downloads.jobs.first { $0.id == downloads.activeID } ?? downloads.jobs.first { $0.state != .complete }
    }
    var body: some View {
        if let job = current {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: L10n.text("下载任务 · \(downloads.jobs.filter { $0.state != .complete }.count)")).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(L10n.text("管理下载")) { manage() }.buttonStyle(.plain).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.linkColor).accessibilityIdentifier("status-manage-downloads")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(job.repository).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(1).truncationMode(.middle).help(L10n.text(job.repository))
                    Spacer()
                    Text(verbatim: L10n.text(downloads.activeID == job.id ? job.percentageLabel : job.state.rawValue)).font(.system(size: TypeScale.callout)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                if job.totalKnown && job.total > 0 { UsageBar(fraction: Double(job.received) / Double(job.total), progress: true) }
                HStack {
                    Text(verbatim: L10n.text(job.totalKnown ? "\(sizeLabel(job.received)) / \(sizeLabel(job.total))" : sizeLabel(job.received)) + (downloads.activeID == job.id ? " · " + downloads.speedLabel(job.id) : ""))
                        .font(.system(size: TypeScale.caption)).monospacedDigit().foregroundStyle(Theme.muted).accessibilityIdentifier("status-download-progress")
                    Spacer()
                    if downloads.activeID == job.id { Button(L10n.text("暂停")) { downloads.pause() }.controlSize(.small) }
                    else { Button(L10n.text(job.resumeBlockedReason != nil ? "重新下载" : (job.pausedFiles ?? []).isEmpty ? "继续" : "继续全部")) { downloads.resume(job.id, includingPausedFiles: true) }.controlSize(.small).disabled(downloads.activeID != nil || downloads.deletingIDs.contains(job.id)) }
                }.accessibilityIdentifier("status-download-speed")
                if let error = job.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.errorText).lineLimit(2) }
            }.padding(16).accessibilityIdentifier("status-download-management")
        }
    }
    func manage() {
        if let job = current { downloads.showTask(job.id) }
        store.tab = .downloads; store.showMainWindow?()
    }
}
