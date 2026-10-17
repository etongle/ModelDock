import SwiftUI
import AppKit

@MainActor
struct DownloadFileDetails: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloads: DownloadController
    var job: ModelDownload
    var rows: [DownloadFileProgress] { downloads.fileProgress(in: job) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: L10n.text("下载文件详情")).font(.system(size: TypeScale.title, weight: .bold))
                    Text(job.repository).font(.system(size: TypeScale.body, weight: .semibold)).textSelection(.enabled)
                    Text(verbatim: L10n.text(job.site.rawValue + " · " + job.state.rawValue)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                }
                Spacer()
                // The sidebar's + returns to the new-download form; the header carries the task's own actions.
                DownloadTaskActions(store: store, downloads: downloads, job: job)
            }
            if let target = job.repairTarget {
                Text(verbatim: L10n.text("单文件修复：" + target)).font(.system(size: TypeScale.callout, design: .monospaced)).textSelection(.enabled)
                Button(L10n.text("查看模型文件")) { store.tab = .models; store.selectedFileID = job.repairModelID }.buttonStyle(SecondaryButton())
            } else if job.state == .complete {
                Button { store.showDownloadedModel(job) } label: { Label(L10n.text("启动模型…"), systemImage: "play.fill") }.buttonStyle(AccentButton()).accessibilityIdentifier("launch-downloaded-model")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(verbatim: L10n.text("总体进度")).font(.system(size: TypeScale.body, weight: .semibold))
                    InfoTip(text: "每次处理一个文件。暂停某个文件后继续处理其他文件；优先下载会保留当前文件断点并立即切换。")
                    Spacer()
                    Text(verbatim: L10n.text(job.percentageLabel)).monospacedDigit()
                }
                if job.totalKnown && job.total > 0 { UsageBar(fraction: Double(job.received) / Double(job.total), progress: true) }
                HStack {
                    Text(verbatim: L10n.text(job.totalKnown ? "\(sizeLabel(job.received)) / \(sizeLabel(job.total))" : "\(sizeLabel(job.received)) · 总量待确认"))
                    Spacer()
                    Text(verbatim: L10n.text("下载速度 " + downloads.speedLabel(job.id))).foregroundStyle(Theme.muted)
                }.font(.system(size: TypeScale.body)).monospacedDigit()
                if job.state != .complete {
                    HStack { Text(verbatim: L10n.text("预计剩余时间")); Spacer(); Text(verbatim: downloads.remainingTimeLabel(job)) }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).monospacedDigit().accessibilityIdentifier("download-remaining-time")
                }
                HStack(spacing: 18) {
                    Text(verbatim: L10n.text("已完成 \(rows.filter { $0.state == .complete }.count) / \(rows.count)"))
                    Text(verbatim: L10n.text("处理中 \(rows.filter { $0.state.processing }.count)"))
                    Text(verbatim: L10n.text("未下载 \(rows.filter { $0.state == .notStarted }.count)"))
                    if rows.contains(where: { $0.state == .paused }) { Text(verbatim: L10n.text("已暂停 \(rows.filter { $0.state == .paused }.count)")) }
                    if rows.contains(where: { $0.state == .failed }) { Text(verbatim: L10n.text("需重试 \(rows.filter { $0.state == .failed }.count)")).foregroundStyle(Theme.errorText) }
                }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                if !(job.pausedFiles ?? []).isEmpty { Button(L10n.text("继续所有暂停文件")) { downloads.resumeAllFiles(job.id) }.buttonStyle(.bordered).controlSize(.small).disabled(!downloads.canControlFiles(job.id)) }
            }.padding(18).background(Theme.selection.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("download-files-summary")
            if job.state == .queued { Label(L10n.text(downloads.queueReason(job.id)), systemImage: "clock").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L10n.text("保存位置")).font(.system(size: TypeScale.callout, weight: .semibold))
                Text(job.displayLocation).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                if job.site != .direct { Text(verbatim: L10n.text("版本 · " + job.revision)).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled) }
            }
            let expanded = downloads.fileListExpanded[job.id] ?? (job.state != .complete)
            let finished = rows.filter { $0.state == .complete }.count
            // 文件较多时列表很长：做成可折叠，标题行显示完成情况。
            Button { downloads.fileListExpanded[job.id] = !expanded } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(Theme.muted)
                    Text(verbatim: L10n.text("文件 · \(rows.count)")).font(.system(size: TypeScale.body, weight: .semibold))
                    Text(verbatim: L10n.text("已完成 \(finished) / \(rows.count)")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L10n.text(expanded ? "收起文件列表" : "展开文件列表"))
            if expanded {
            VStack(spacing: 0) {
                ForEach(rows) { progress in
                    DownloadFileRow(progress: progress, controlsEnabled: downloads.canControlFiles(job.id), pause: { downloads.pauseFile(job.id, path: progress.id) }, resume: { downloads.resumeFile(job.id, path: progress.id) }, prioritize: { downloads.resumeFile(job.id, path: progress.id, first: true) })
                    if progress.id != rows.last?.id { Divider() }
                }
            }.padding(.horizontal, 16).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = job.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            Label(L10n.text(job.repairTarget != nil ? "修复只替换原版本中的这个文件；其他文件保留，使用中的文件会拦截。" : "下载新版本保留旧版本文件，不会自动切换正在运行的服务。"), systemImage: "info.circle").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        }.accessibilityIdentifier("download-file-details-\(job.id)")
    }
}

@MainActor
struct DownloadFileRow: View {
    var progress: DownloadFileProgress
    var controlsEnabled: Bool
    var pause: () -> Void
    var resume: () -> Void
    var prioritize: () -> Void
    var statusColor: Color {
        switch progress.state {
        case .complete: return Theme.adaptive(NSColor(red: 0.12, green: 0.40, blue: 0.23, alpha: 1), NSColor(red: 0.52, green: 0.85, blue: 0.62, alpha: 1))
        case .failed: return Theme.errorText
        case .unverified, .paused: return Theme.warningText
        case .downloading, .checking, .connecting: return Theme.linkColor
        default: return Theme.muted
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: progress.state.symbol).foregroundStyle(statusColor).frame(width: 18)
                Text(progress.file.path).font(.system(size: TypeScale.callout, design: .monospaced)).lineLimit(2).help(L10n.text(progress.file.path)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: L10n.text(progress.state.rawValue)).font(.system(size: TypeScale.callout, weight: .medium)).foregroundStyle(statusColor).lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(minWidth: 66, alignment: .trailing)
            }
            HStack {
                Text(verbatim: L10n.text(progress.percentageLabel))
                Text(verbatim: L10n.text(progress.file.bytes > 0 ? "\(sizeLabel(progress.received)) / \(sizeLabel(progress.file.bytes))" : sizeLabel(progress.received)))
                Spacer(minLength: 8)
                if let speed = progress.speed { Text(verbatim: L10n.text(sizeLabel(Int64(max(0, min(Double(Int64.max / 2), speed.isFinite ? speed : 0)))) + "/s")).foregroundStyle(Theme.muted) }
                else if progress.state == .complete { Text(verbatim: L10n.text(progress.file.sha256 == nil ? "大小检查通过" : "SHA-256 已校验")) }
            }.font(.system(size: TypeScale.caption)).monospacedDigit().foregroundStyle(Theme.muted)
            if progress.state == .downloading, let seconds = DownloadEstimate.seconds(remaining: max(0, progress.file.bytes - progress.received), speed: progress.speed ?? 0) {
                Text(verbatim: L10n.format("约剩余 {0}", [DownloadEstimate.duration(seconds)])).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
            }
            if progress.state != .complete, progress.received > 0, progress.file.bytes > 0 {
                UsageBar(fraction: progress.file.bytes > 0 ? Double(progress.received) / Double(progress.file.bytes) : 0, progress: true)
            }
            if let error = progress.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            if progress.state != .complete {
                HStack {
                    if progress.state == .paused { Button(L10n.text("继续")) { resume() }.accessibilityIdentifier("resume-file-\(progress.id)") }
                    else { Button(L10n.text("暂停")) { pause() }.accessibilityIdentifier("pause-file-\(progress.id)") }
                    if !progress.state.processing { Button(L10n.text("优先下载")) { prioritize() }.accessibilityIdentifier("prioritize-file-\(progress.id)") }
                }.buttonStyle(.bordered).controlSize(.small).disabled(!controlsEnabled)
            }
        }.padding(.vertical, 12).accessibilityElement(children: .contain).accessibilityIdentifier("download-file-\(progress.file.path)")
    }
}
