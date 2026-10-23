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
                SidebarHeader(title: "下载任务") {
                    // A new import has its own empty form; existing transfers continue.
                    SidebarIconButton(symbol: "plus", help: "新建下载") { downloads.beginImport() }.accessibilityIdentifier("new-download")
                    SidebarIconButton(symbol: "key", help: "全局 Hugging Face 令牌") { globalTokenSettings() }.accessibilityIdentifier("global-hf-token-entry")
                    SidebarToggleButton(store: store)
                }.padding(.bottom, 4)
                DownloadConcurrencyControl(downloads: downloads)
                if downloads.jobs.isEmpty {
                    EmptyMessage(symbol: "arrow.down.circle", title: L10n.text("还没有下载任务"), detail: "粘贴仓库或模型文件地址，选择要下载的文件。")
                    Spacer()
                } else {
                    List(selection: $downloads.selectedTaskID) {
                        ForEach(downloads.jobs) { job in
                            DownloadRow(downloads: downloads, job: job).padding(.vertical, 4).tag(Optional(job.id)).listRowSeparator(.hidden)
                                .contextMenu { DownloadTaskActions(store: store, downloads: downloads, job: job, menu: true) }
                        }
                    }.sidebarList()
                    // Removing a task keeps every downloaded and partial file, so it needs no extra confirmation.
                    .onDeleteCommand { if let job = downloads.detailJob { DownloadTaskActions.remove(job, downloads: downloads) } }
                }
            }.padding(SidebarMetrics.padding).frame(width: sidebarWidth, alignment: .leading).clipped().background(Theme.sidebar)
            SidebarResizeHandle(store: store, width: sidebarWidth)
            } else { SidebarRail(store: store) }
            ScrollView {
                if let job = downloads.detailJob {
                    DownloadFileDetails(store: store, downloads: downloads, job: job).padding(32)
                } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text(verbatim: L10n.text("从模型网站导入")).font(.system(size: TypeScale.title, weight: .bold))
                    Text(verbatim: L10n.text("支持 Hugging Face、ModelScope、GitHub 仓库与 Release，以及模型文件直链。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                    ModelSearchView(search: store.modelSearch, downloads: downloads)
                    HStack { TextField(L10n.text("输入 owner/repo，或粘贴模型下载地址"), text: Binding(get: { downloads.address }, set: { downloads.changeAddress($0) })).textFieldStyle(.roundedBorder).font(.system(size: TypeScale.body)).onSubmit { downloads.resolve() }.accessibilityIdentifier("download-address"); Button { downloads.resolve() } label: { if downloads.resolving { ProgressView().controlSize(.small) } else { Text(verbatim: L10n.text("解析地址")) } }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(downloads.resolving || downloads.address.isEmpty) }
                    // Only private or gated repositories need a token, so keep it out of the way by default.
                    DisclosureGroup(L10n.text("访问令牌（可选）")) {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField(L10n.text("单次访问令牌（可选，覆盖全局配置）"), text: $downloads.token).textFieldStyle(.roundedBorder)
                            Text(verbatim: L10n.text("Hugging Face 自动使用全局令牌。这里填写的令牌仅用于本次任务；私有或受限模型仍需访问许可。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                            Button(L10n.text("配置全局 Hugging Face 令牌…")) { globalTokenSettings() }.buttonStyle(.bordered)
                        }.padding(.top, 6)
                    }.font(.system(size: TypeScale.body))
                    HStack { VStack(alignment: .leading, spacing: 7) { Text(verbatim: L10n.text("保存到模型库")).font(.system(size: TypeScale.body, weight: .semibold)); Text(verbatim: L10n.text(downloads.destination)).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled) }; Spacer(); Button(L10n.text("选择目录…")) { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = L10n.text("选择模型库"); if panel.runModal() == .OK, let url = panel.url { downloads.chooseDestination(url.resolvingSymlinksInPath().path) } }.buttonStyle(.bordered) }
                    if let message = downloads.message { Text(verbatim: L10n.text(message)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
                    if let notice = downloads.notice { Label(L10n.text(notice), systemImage: "info.circle").font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                    if let listing = downloads.listing {
                        Divider()
                        HStack { VStack(alignment: .leading, spacing: 7) { Text(listing.repository).font(.system(size: TypeScale.section, weight: .semibold)); HStack(spacing: 6) { Text(verbatim: L10n.text("\(listing.site.rawValue) · \(listing.files.count) 个文件")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); InfoTip(text: "GGUF 通常选择一个量化版本；视觉模型还需对应 mmproj。MLX / Splash 封装应下载全部权重、配置与 tokenizer。下载完成后会自动扫描适配引擎。") } }; Spacer(); Button(L10n.text("全选")) { downloads.selected = Set(listing.files.map(\.id)) }; Button(L10n.text("取消全选")) { downloads.selected = [] } }.buttonStyle(.bordered)
                        VStack(spacing: 0) { ForEach(listing.files) { file in
                            Toggle(isOn: Binding(get: { downloads.selected.contains(file.id) }, set: { if $0 { downloads.selected.insert(file.id) } else { downloads.selected.remove(file.id) } })) { HStack { Text(file.path).font(.system(size: TypeScale.body, design: .monospaced)).lineLimit(2); if file.path.lowercased().hasSuffix(".gguf") { ModelFitTag(bytes: file.bytes, memory: store.inventory?.memoryBytes ?? 0) }; Spacer(); Text(verbatim: L10n.text(file.bytes > 0 ? sizeLabel(file.bytes) : "大小待确认")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }.padding(.vertical, 9) }.toggleStyle(.checkbox)
                            Divider()
                        } }.padding(16).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        if let task = downloads.preferredPausedTask { Label(L10n.text("已有同位置的暂停任务，将从 \(sizeLabel((try? DownloadRecovery.reconcile(task).received) ?? task.received)) 继续。"), systemImage: "arrow.clockwise").font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                        HStack { Text(verbatim: L10n.text("已选 \(downloads.selectedFiles.count) 个文件 · " + (downloads.selectedFiles.contains { $0.bytes <= 0 } ? "大小待确认" : sizeLabel(downloads.selectedFiles.reduce(0) { $0 + $1.bytes })))).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); Spacer()
                            // Say why the primary action is unavailable instead of only greying it out.
                            if let reason = downloads.selectedFiles.isEmpty ? "请至少选择一个文件" : store.maintaining ? "引擎维护进行中，完成后可开始下载" : nil {
                                Text(verbatim: L10n.text(reason)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                            }
                            Button { downloads.createJob() } label: { Label(L10n.text("下载并导入"), systemImage: downloads.preferredPausedTask == nil ? "arrow.down.circle" : "arrow.clockwise") }.buttonStyle(AccentButton()).disabled(downloads.selectedFiles.isEmpty || store.maintaining).accessibilityIdentifier("download-and-import") }
                    } else { EmptyMessage(symbol: "link", title: L10n.text("粘贴模型地址开始"), detail: "先查看文件列表与下载大小，完成后自动扫描模型，并标记专属引擎和适配关系。") }
                }.padding(32)
                }
            }.id(downloads.selectedTaskID ?? downloads.importSessionID.uuidString).frame(maxWidth: .infinity)
        }.sheet(item: $downloads.authorization) { draft in DownloadAuthorizationView(downloads: downloads, draft: draft, configureGlobal: { downloads.authorization = nil; globalTokenSettings() }) }
        .alert(L10n.text("下载导入"), isPresented: Binding(get: { downloads.message != nil }, set: { if !$0 { downloads.message = nil } })) { Button(L10n.text("好")) { downloads.message = nil } } message: { Text(verbatim: L10n.text(downloads.message ?? "")) }
    }
    func globalTokenSettings() { store.settingsTab = 3; store.showSettings?() }
}

/// Compact sidebar row: repository, state and percentage, a thin bar while unfinished, sizes and speed.
@MainActor
struct DownloadRow: View {
    @ObservedObject var downloads: DownloadController
    var job: ModelDownload
    var body: some View {
        let active = downloads.isActive(job.id)
        HStack(alignment: .top, spacing: 10) {
            SidebarSymbol(symbol: job.state == .complete ? "checkmark.circle" : job.state == .failed ? "exclamationmark.triangle" : "arrow.down.circle")
            VStack(alignment: .leading, spacing: 4) {
                Text(job.repository).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(L10n.text(job.repository))
                HStack {
                    Text(verbatim: L10n.text(downloads.retryStatuses[job.id] == nil ? job.state.rawValue : "等待自动续传")).foregroundStyle(job.state == .failed ? Theme.errorText : Color.secondary)
                    Spacer()
                    Text(verbatim: L10n.text(job.percentageLabel)).monospacedDigit()
                }.font(.system(size: TypeScale.callout)).foregroundStyle(.secondary)
                if job.state != .complete && job.totalKnown && job.total > 0 { UsageBar(fraction: Double(job.received) / Double(job.total), progress: true) }
                Text(verbatim: L10n.text(job.totalKnown ? "\(sizeLabel(job.received)) / \(sizeLabel(job.total))" : sizeLabel(job.received)) + (active ? " · " + downloads.speedLabel(job.id) : ""))
                    .font(.system(size: TypeScale.caption)).monospacedDigit().foregroundStyle(.secondary).accessibilityIdentifier("download-speed-\(job.id)")
                if active || job.state == .queued {
                    Text(verbatim: downloads.remainingTimeLabel(job)).font(.system(size: TypeScale.caption)).foregroundStyle(.secondary).accessibilityIdentifier("download-eta-\(job.id)")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Task actions shared by the detail header (buttons) and the sidebar context menu.
@MainActor
struct DownloadTaskActions: View {
    @ObservedObject var store: AppStore
    @ObservedObject var downloads: DownloadController
    var job: ModelDownload
    var menu = false
    var body: some View {
        if menu { transfer; credential; repository; directory; Divider(); cleanup; delete }
        else { HStack { transfer; credential; directory; cleanup; delete }.buttonStyle(.bordered).controlSize(.small) }
    }
    @ViewBuilder var transfer: some View {
        if downloads.isScheduled(job.id) { Button(L10n.text("暂停")) { downloads.pause(job.id) } }
        else if job.state != .complete {
            Button(L10n.text(job.needsAuthorization ? job.site == .huggingface && downloads.accessTokens.huggingFaceConfigured ? "使用全局令牌重试" : "输入令牌并继续…" : job.resumeBlockedReason != nil ? "重新下载" : (job.pausedFiles ?? []).isEmpty ? "继续下载" : "继续全部")) { downloads.resume(job.id, includingPausedFiles: true) }
                .disabled(downloads.deletingIDs.contains(job.id))
        }
    }
    var directory: some View { Button(L10n.text("打开目录")) { store.reveal(job.displayLocation) }.disabled(!store.canReveal(job.displayLocation)) }
    @ViewBuilder var repository: some View {
        if let url = job.huggingFacePage { Button(L10n.text("查看 Hugging Face 页面")) { NSWorkspace.shared.open(url) } }
    }
    @ViewBuilder var credential: some View {
        if job.state != .complete && !downloads.isScheduled(job.id), job.site != .direct {
            Button(L10n.text("访问令牌…")) { downloads.requestAuthorization(job.id) }.accessibilityIdentifier("download-authorization-entry")
        }
    }
    @ViewBuilder var cleanup: some View {
        if job.state != .complete && !downloads.isScheduled(job.id) { Button(L10n.text("清理未完成文件…"), role: .destructive) { confirmCleanup() } }
    }
    var delete: some View {
        Button(role: .destructive) { Self.remove(job, downloads: downloads) } label: { Label(L10n.text("删除任务，保留文件"), systemImage: "trash") }
            .disabled(downloads.deletingIDs.contains(job.id))
            .help(L10n.text(downloads.isActive(job.id) ? "停止下载并删除任务记录，保留文件" : "删除任务记录，保留已下载文件和未完成文件"))
            .accessibilityIdentifier("delete-download-\(job.id)")
    }
    static func remove(_ job: ModelDownload, downloads: DownloadController) {
        Task { do { try await downloads.removeTask(job.id) } catch { downloads.message = error.localizedDescription } }
    }
    func confirmCleanup() {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = L10n.text("清理此任务的未完成文件？"); alert.informativeText = L10n.text("已经下载完成并导入的模型会保留。未完成文件清理后需要重新下载。"); alert.addButton(withTitle: L10n.text("清理未完成文件")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try downloads.cleanPartials(job.id) } catch { downloads.message = error.localizedDescription }
    }
}

@MainActor
struct DownloadConcurrencyControl: View {
    @ObservedObject var downloads: DownloadController
    var body: some View {
        HStack {
            Text(verbatim: L10n.text("同时下载")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            Spacer()
            Picker(L10n.text("并发下载数量"), selection: $downloads.maximumConcurrentDownloads) {
                ForEach(1...8, id: \.self) { count in Text(verbatim: L10n.format("{0} 个模型", [String(count)])).tag(count) }
            }.labelsHidden().frame(width: 125).accessibilityIdentifier("download-concurrency")
        }
    }
}
@MainActor
struct DownloadSettingsView: View {
    @ObservedObject var downloads: DownloadController
    var body: some View {
        Form {
            Section(L10n.text("全局 Hugging Face 令牌")) { HuggingFaceTokenSettings(tokens: downloads.accessTokens) }
            Section(L10n.text("下载队列")) {
                DownloadConcurrencyControl(downloads: downloads)
                Text(verbatim: L10n.text("默认同时下载 2 个模型，可设置为 1–8 个；超出数量的任务自动排队。每个模型内依次下载文件。"))
                Text(verbatim: L10n.text("调低数量不会中断已开始的任务。相同目录会依次下载，防止文件冲突。"))
            }
        }.formStyle(.grouped).font(.system(size: TypeScale.body))
    }
}
