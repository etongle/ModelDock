import SwiftUI

@MainActor
struct StatusDownloads: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloads: DownloadController
    /// The menu bar only surfaces work that still needs attention; finished jobs stay in Downloads.
    var current: ModelDownload? {
        downloads.jobs.first { downloads.isActive($0.id) } ?? downloads.jobs.first { $0.state != .complete }
    }
    var visible: [ModelDownload] { Array((downloads.jobs.filter { downloads.isActive($0.id) } + downloads.jobs.filter { !downloads.isActive($0.id) && $0.state != .complete }).prefix(3)) }
    var body: some View {
        if current != nil {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: L10n.text("下载任务 · \(downloads.jobs.filter { $0.state != .complete }.count)")).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(L10n.text("管理下载")) { manage() }.buttonStyle(.plain).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.linkColor).accessibilityIdentifier("status-manage-downloads")
                }
                ScrollView { VStack(alignment: .leading, spacing: 10) {
                ForEach(visible) { job in
                HStack(alignment: .firstTextBaseline) {
                    Text(job.repository).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(1).truncationMode(.middle).help(L10n.text(job.repository))
                    Spacer()
                    Text(verbatim: L10n.text(downloads.isActive(job.id) ? job.percentageLabel : job.state.rawValue)).font(.system(size: TypeScale.callout)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                if job.totalKnown && job.total > 0 { UsageBar(fraction: Double(job.received) / Double(job.total), progress: true) }
                HStack {
                    Text(verbatim: L10n.text(job.totalKnown ? "\(sizeLabel(job.received)) / \(sizeLabel(job.total))" : sizeLabel(job.received)) + (downloads.isActive(job.id) ? " · " + downloads.speedLabel(job.id) : ""))
                        .font(.system(size: TypeScale.caption)).monospacedDigit().foregroundStyle(Theme.muted).accessibilityIdentifier("status-download-progress")
                    Spacer()
                    if downloads.isScheduled(job.id) { Button(L10n.text("暂停")) { downloads.pause(job.id) }.controlSize(.small) }
                    else { Button(L10n.text(job.resumeBlockedReason != nil ? "重新下载" : (job.pausedFiles ?? []).isEmpty ? "继续" : "继续全部")) { downloads.resume(job.id, includingPausedFiles: true) }.controlSize(.small).disabled(downloads.deletingIDs.contains(job.id)) }
                }.accessibilityIdentifier("status-download-speed")
                Text(verbatim: downloads.remainingTimeLabel(job)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                if let error = job.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.errorText).lineLimit(2) }
                }
                } }.frame(height: min(CGFloat(visible.count) * 110, 220))
            }.padding(16).accessibilityIdentifier("status-download-management")
        }
    }
    func manage() {
        if let job = current { downloads.showTask(job.id) }
        store.tab = .downloads; store.showMainWindow?()
    }
}
