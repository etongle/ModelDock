import SwiftUI
import AppKit

@MainActor
struct DownloadWorkspace: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloads: DownloadController
    var sidebarWidth: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarHidden {
            VStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
                SidebarHeader(title: "下载任务") { SidebarToggleButton(store: store) }.padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if downloads.jobs.isEmpty { EmptyMessage(symbol: "arrow.down.circle", title: L10n.text("还没有下载任务"), detail: "粘贴仓库或模型文件地址，选择要下载的文件。") }
                        ForEach(downloads.jobs) { job in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(job.repository).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(2)
                                HStack { Text(verbatim: L10n.text(job.site.rawValue)); Spacer(); Text(verbatim: L10n.text(job.state.rawValue)).foregroundStyle(job.state == .failed ? Theme.errorText : Theme.linkColor) }.font(.system(size: TypeScale.callout))
                                if job.totalKnown && job.total > 0 { ProgressView(value: min(Double(job.received), Double(job.total)), total: Double(job.total)) }
                                else if job.state == .downloading { ProgressView().controlSize(.small) }
                                HStack { Text(verbatim: L10n.text(job.percentageLabel)).fontWeight(.medium); Spacer(); Text(verbatim: L10n.text(job.totalKnown ? "\(sizeLabel(job.received)) / \(sizeLabel(job.total))" : sizeLabel(job.received))) }.font(.system(size: TypeScale.callout)).monospacedDigit().foregroundStyle(Theme.muted).accessibilityIdentifier("download-percentage-\(job.id)")
                                HStack { Label(L10n.text("下载速度"), systemImage: "arrow.down"); Spacer(); Text(verbatim: L10n.text(downloads.speedLabel(job.id))).monospacedDigit() }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).accessibilityIdentifier("download-speed-\(job.id)")
                                Text(job.displayLocation).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(2).help(L10n.text(job.displayLocation)).textSelection(.enabled)
                                Text(verbatim: L10n.text("已完成 \(job.finished.count) / \(job.files.count) 个文件")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                                Text(verbatim: L10n.text(job.state == .complete ? (job.repairTarget != nil ? "单文件修复已应用" : "已导入 · 可在模型文件中查看") : job.currentFile)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).lineLimit(2)
                                if let error = job.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
                                DownloadTaskActions(store: store, downloads: downloads, job: job)
                                if job.state != .complete && downloads.activeID != job.id {
                                    Button(L10n.text("清理未完成文件…")) { confirmCleanup(job) }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).buttonStyle(.plain).frame(minHeight: 30)
                                }
                            }.padding(16).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Text(verbatim: L10n.text("下载优先续传同位置的匹配任务。\n删除任务保留文件；清理会检查文件共用情况。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }.padding(SidebarMetrics.padding).frame(width: sidebarWidth).background(Theme.sidebar)
            Rectangle().fill(Theme.line).frame(width: 1)
            } else { SidebarRail(store: store) }
            ScrollView {
                if let job = downloads.detailJob {
                    DownloadFileDetails(store: store, downloads: downloads, job: job).padding(32)
                } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text(verbatim: L10n.text("从模型网站导入")).font(.system(size: TypeScale.title, weight: .bold))
                    Text(verbatim: L10n.text("支持 Hugging Face、ModelScope 仓库，以及其他网站的模型文件直链。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                    HStack { TextField(L10n.text("输入 owner/repo，或粘贴模型下载地址"), text: $downloads.address).textFieldStyle(.roundedBorder).font(.system(size: TypeScale.body)).onSubmit { downloads.resolve() }.accessibilityIdentifier("download-address"); Button { downloads.resolve() } label: { if downloads.resolving { ProgressView().controlSize(.small) } else { Text(verbatim: L10n.text("解析地址")) } }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(downloads.resolving || downloads.address.isEmpty) }
                    SecureField(L10n.text("访问令牌（可选，仅用于 Hugging Face / ModelScope）"), text: $downloads.token).textFieldStyle(.roundedBorder)
                    Text(verbatim: L10n.text("私有或受限仓库需先获访问许可。令牌不会保存到磁盘，重新打开应用后需重新填写。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    HStack { VStack(alignment: .leading, spacing: 7) { Text(verbatim: L10n.text("保存到模型库")).font(.system(size: TypeScale.body, weight: .semibold)); Text(verbatim: L10n.text(downloads.destination)).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled) }; Spacer(); Button(L10n.text("选择目录…")) { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = L10n.text("选择模型库"); if panel.runModal() == .OK, let url = panel.url { downloads.destination = url.resolvingSymlinksInPath().path } }.buttonStyle(.bordered) }
                    if let message = downloads.message { Text(verbatim: L10n.text(message)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
                    if let notice = downloads.notice { Label(L10n.text(notice), systemImage: "info.circle").font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                    if let listing = downloads.listing {
                        Divider()
                        HStack { VStack(alignment: .leading, spacing: 7) { Text(listing.repository).font(.system(size: TypeScale.section, weight: .semibold)); Text(verbatim: L10n.text("\(listing.site.rawValue) · \(listing.files.count) 个文件")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }; Spacer(); Button(L10n.text("全选")) { downloads.selected = Set(listing.files.map(\.id)) }; Button(L10n.text("取消全选")) { downloads.selected = [] } }.buttonStyle(.bordered)
                        Text(verbatim: L10n.text("GGUF 通常选择一个量化版本；视觉模型还需对应 mmproj。MLX / Splash 封装应下载全部权重、配置与 tokenizer。下载完成后会自动扫描适配引擎。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                        VStack(spacing: 0) { ForEach(listing.files) { file in
                            Toggle(isOn: Binding(get: { downloads.selected.contains(file.id) }, set: { if $0 { downloads.selected.insert(file.id) } else { downloads.selected.remove(file.id) } })) { HStack { Text(file.path).font(.system(size: TypeScale.body, design: .monospaced)).lineLimit(2); Spacer(); Text(verbatim: L10n.text(file.bytes > 0 ? sizeLabel(file.bytes) : "大小待确认")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }.padding(.vertical, 9) }.toggleStyle(.checkbox)
                            Divider()
                        } }.padding(16).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        if let task = downloads.preferredPausedTask { Label(L10n.text("已有同位置的暂停任务，将从 \(sizeLabel((try? DownloadRecovery.reconcile(task).received) ?? task.received)) 继续。"), systemImage: "arrow.clockwise").font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                        Text(verbatim: L10n.text("勾选表示选择下载，不代表文件已下载完成。查看任务的“查看文件”可确认每个文件的状态。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        HStack { Text(verbatim: L10n.text("已选 \(downloads.selectedFiles.count) 个文件 · " + (downloads.selectedFiles.contains { $0.bytes <= 0 } ? "大小待确认" : sizeLabel(downloads.selectedFiles.reduce(0) { $0 + $1.bytes })))).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); Spacer()
                            // Say why the primary action is unavailable instead of only greying it out.
                            if let reason = downloads.selectedFiles.isEmpty ? "请至少选择一个文件" : downloads.activeID != nil ? "已有下载进行中，完成或暂停后可开始" : store.maintaining ? "引擎维护进行中，完成后可开始下载" : nil {
                                Text(verbatim: L10n.text(reason)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                            }
                            Button { downloads.createJob() } label: { Label(L10n.text("下载并导入"), systemImage: downloads.preferredPausedTask == nil ? "arrow.down.circle" : "arrow.clockwise") }.buttonStyle(AccentButton()).disabled(downloads.selectedFiles.isEmpty || downloads.activeID != nil || store.maintaining).accessibilityIdentifier("download-and-import") }
                    } else { EmptyMessage(symbol: "link", title: L10n.text("粘贴模型地址开始"), detail: "先查看文件列表与下载大小，完成后自动扫描模型，并标记专属引擎和适配关系。") }
                }.padding(32)
                }
            }.frame(maxWidth: .infinity)
        }.alert(L10n.text("下载导入"), isPresented: Binding(get: { downloads.message != nil }, set: { if !$0 { downloads.message = nil } })) { Button(L10n.text("好")) { downloads.message = nil } } message: { Text(verbatim: L10n.text(downloads.message ?? "")) }
    }
    func confirmCleanup(_ job: ModelDownload) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = L10n.text("清理此任务的未完成文件？"); alert.informativeText = L10n.text("已经下载完成并导入的模型会保留。未完成文件清理后需要重新下载。"); alert.addButton(withTitle: L10n.text("清理未完成文件")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try downloads.cleanPartials(job.id) } catch { downloads.message = error.localizedDescription }
    }
}

@MainActor
private struct DownloadTaskActions: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloads: DownloadController
    var job: ModelDownload
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { transfer; details; directory; delete }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) {
                HStack { transfer; details }
                HStack { directory; delete }
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }
    @ViewBuilder var transfer: some View {
        if downloads.activeID == job.id { Button(L10n.text("暂停")) { downloads.pause() } }
        else if job.state != .complete {
            Button(L10n.text(job.resumeBlockedReason != nil ? "重新下载" : (job.pausedFiles ?? []).isEmpty ? "继续下载" : "继续全部")) { downloads.resume(job.id, includingPausedFiles: true) }
                .disabled(downloads.activeID != nil || downloads.deletingIDs.contains(job.id))
        }
    }
    var details: some View { Button(L10n.text("查看文件")) { downloads.showTask(job.id) }.accessibilityIdentifier("show-download-files-\(job.id)") }
    var directory: some View { Button(L10n.text("打开目录")) { store.reveal(job.displayLocation) } }
    var delete: some View {
        Button { Task { do { try await downloads.removeTask(job.id) } catch { downloads.message = error.localizedDescription } } } label: { Image(systemName: "trash") }
            .disabled(downloads.deletingIDs.contains(job.id))
            .help(L10n.text(downloads.activeID == job.id ? "停止下载并删除任务记录，保留文件" : "删除任务记录，保留已下载文件和未完成文件"))
            .accessibilityLabel(L10n.text("删除任务，保留文件")).accessibilityIdentifier("delete-download-\(job.id)")
    }
}
