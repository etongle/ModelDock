import SwiftUI

@MainActor
struct CommandLaunchView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var draft: CommandDraft
    var engine: Engine? { store.engines.first { $0.id == draft.engineID } }
    var parsed: Result<CommandLaunch, Error> {
        guard let engine else { return .failure(LaunchError.message("引擎已移除，请重新扫描")) }
        return Result { try ServiceCommand.parse(draft.text, engine: engine, models: store.models) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: L10n.text("按命令行启动 \(engine?.name ?? "服务")")).font(.system(size: TypeScale.section, weight: .semibold))
            Text(verbatim: L10n.text("粘贴启动命令，保留模型参数。启动后可查看日志、停止服务或通过网关接入。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: L10n.text("启动命令")).font(.system(size: TypeScale.body, weight: .semibold))
                    TextEditor(text: $draft.text).font(.system(size: TypeScale.body, design: .monospaced)).frame(height: 145).padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10)).overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.line) }.onChange(of: draft.text) { draft.error = nil }.accessibilityIdentifier("service-command-editor")
                    Text(verbatim: L10n.text("支持引号、换行和 HF_HOME 等缓存目录参数。程序和端口会在启动前检查。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    switch parsed {
                    case .success(let command):
                        VStack(alignment: .leading, spacing: 12) {
                            Label(L10n.text("启动预览"), systemImage: "checkmark.circle").foregroundStyle(Theme.muted)
                            Text(command.modelName).font(.system(size: TypeScale.body, weight: .medium)).textSelection(.enabled)
                            Text(verbatim: L10n.text("端口 \(command.port) · 上下文 \(command.context) · \(command.mode.title)")).font(.system(size: TypeScale.body))
                            if command.downloadsModel { Text(verbatim: L10n.text("Splash 会验证模型，必要时下载目标权重、草稿和视觉组件。第一次启动可能较久，可在模型服务中查看准备日志。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                            DisclosureGroup("实际启动参数") { Text(verbatim: L10n.text(([command.plan.executable] + command.plan.arguments).map(ServiceCommand.quote).joined(separator: " "))).font(.system(size: TypeScale.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.selection, in: RoundedRectangle(cornerRadius: 12))
                    case .failure: EmptyView()
                    }
                }
            }
            switch parsed {
            case .success(let command):
                if let conflict = store.services.portConflict(command.port) { Label(L10n.text(conflict + "，请修改 --port"), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warningText).font(.system(size: TypeScale.body)) }
            case .failure(let error): Text(verbatim: L10n.text(error.localizedDescription)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled)
            }
            if let error = draft.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            Divider()
            HStack {
                Button(L10n.text("取消")) { store.commandDraft = nil }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Spacer()
                Button { store.startCommand(draft) } label: { Label(L10n.text("启动服务"), systemImage: "play.fill") }.buttonStyle(AccentButton()).disabled(!canStart).accessibilityIdentifier("launch-service-command")
            }
        }.padding(26).frame(width: 700, height: 620).background(Theme.background)
    }
    var canStart: Bool {
        if case .success(let command) = parsed { return store.services.portConflict(command.port) == nil && !store.maintaining && !store.installation.running }; return false
    }
}

@MainActor
struct ModelUpdateEntry: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: L10n.text("模型版本")).font(.system(size: TypeScale.section, weight: .semibold)); Spacer()
                Button { store.modelUpdate = ModelUpdateDraft(model: model) } label: { Label(L10n.text(ModelOrigin.replacement(model) == nil ? "检查模型更新…" : "更新为新版模型…"), systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.bordered).accessibilityIdentifier("model-update-entry")
            }
            if let source = ModelOrigin.read(model) {
                Text(source.repository).font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled)
                Text(verbatim: L10n.text("本地版本 · " + (source.revision.isEmpty ? "未记录" : source.revision))).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).textSelection(.enabled)
            } else { Text(verbatim: L10n.text(model.format == "Ollama" ? "通过管理此模型的 Ollama 服务同步最新版本。" : "更新前可以补充模型仓库地址。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
            if let replacement = ModelOrigin.replacement(model) { Text(verbatim: L10n.text("旧 packed 已停止支持。新版对应 \(replacement)，更新会下载独立版本。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.warningText) }
        }
    }
}

@MainActor
struct ModelUpdateView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var draft: ModelUpdateDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: L10n.text(draft.replacement == nil ? "更新模型" : "更新旧 Splash 模型")).font(.system(size: TypeScale.section, weight: .semibold))
            Text(verbatim: L10n.text(draft.model.name)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if draft.model.format == "Ollama" {
                        Text(verbatim: L10n.text("更新所选模型的同名标签。请先从内存卸载此模型，其他模型和服务可以继续运行。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                        if draft.updating { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text("Ollama 正在下载并校验模型，请保持应用运行…")) }.font(.system(size: TypeScale.body)) }
                        if let result = draft.result { Label(L10n.text(result), systemImage: "checkmark.circle").foregroundStyle(Theme.successText) }
                    } else {
                        if draft.replacement != nil { Text(verbatim: L10n.text("新版 Splash 使用上游 MLX 权重。下载完成后，用下方启动入口让 Splash 准备匹配组件。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                        Text(verbatim: L10n.text("模型仓库地址")).font(.system(size: TypeScale.body, weight: .semibold))
                        TextField(L10n.text("https://huggingface.co/owner/model"), text: $draft.address).textFieldStyle(.roundedBorder).disabled(draft.checking).onChange(of: draft.address) { draft.listing = nil; draft.selected = [] }.accessibilityIdentifier("model-update-address")
                        SecureField(L10n.text("访问令牌（可选，不保存）"), text: $draft.token).textFieldStyle(.roundedBorder).disabled(draft.checking)
                        HStack {
                            Button(L10n.text("检查版本")) { draft.check() }.buttonStyle(.bordered).disabled(draft.address.isEmpty || draft.checking)
                            if draft.checking { ProgressView().controlSize(.small); Text(verbatim: L10n.text("正在读取仓库清单…")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                        }
                        if let listing = draft.listing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: L10n.text(draft.sameRevision ? "仓库版本与本地相同 · 可补齐文件" : draft.original == nil ? "仓库版本已读取" : "可下载独立模型版本")).font(.system(size: TypeScale.body, weight: .semibold))
                                Text(listing.repository).font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled)
                                Text(verbatim: L10n.text("仓库版本 · " + listing.revision)).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.selection, in: RoundedRectangle(cornerRadius: 10))
                            Text(verbatim: L10n.text("GGUF 选择当前量化权重与投影；MLX 选择完整权重、配置和 tokenizer。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                            HStack { Text(verbatim: L10n.text("更新文件")).font(.system(size: TypeScale.body, weight: .semibold)); Spacer(); Button(L10n.text("全选")) { draft.selected = Set(listing.files.map(\.path)) }; Button(L10n.text("取消全选")) { draft.selected = [] } }.buttonStyle(.bordered).controlSize(.small)
                            ForEach(listing.files) { file in
                                Toggle(isOn: Binding(get: { draft.selected.contains(file.path) }, set: { if $0 { draft.selected.insert(file.path) } else { draft.selected.remove(file.path) } })) {
                                    HStack { Text(file.path).font(.system(size: TypeScale.callout, design: .monospaced)).lineLimit(2); Spacer(); Text(verbatim: L10n.text(file.bytes > 0 ? sizeLabel(file.bytes) : "大小待确认")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                                }.toggleStyle(.checkbox)
                            }
                            Text(verbatim: L10n.text("已选 \(draft.selectedFiles.count) 个文件 · \(sizeLabel(draft.selectedFiles.reduce(0) { $0 + $1.bytes }))")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                        }
                        Label(L10n.text(draft.sameRevision ? "相同版本只补齐缺失文件，不覆盖已有文件。现有服务继续运行。" : "新版本下载到独立目录，旧版本文件保留。现有服务继续使用原版本，切换版本需另行启动服务。"), systemImage: "info.circle").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        if let engine = store.engines.first(where: { $0.kind == .splash }), draft.replacement != nil || draft.model.splashSelection != nil {
                            Button { openSplash(engine) } label: { Label(L10n.text("用 Splash 命令准备并启动…"), systemImage: "terminal") }.buttonStyle(.bordered).disabled(!engine.canServe || draft.checking)
                        }
                    }
                    if let error = draft.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
                }
            }
            Divider()
            HStack {
                Button(L10n.text("关闭")) { store.modelUpdate = nil }.buttonStyle(.bordered).disabled(draft.updating).keyboardShortcut(.cancelAction)
                Spacer()
                if draft.model.format == "Ollama" { Button(L10n.text("更新此模型")) { draft.ollamaUpdate(store: store) }.buttonStyle(AccentButton()).disabled(draft.updating || store.maintaining) }
                else { Button { draft.download(store: store) } label: { Label(L10n.text("下载模型版本"), systemImage: "arrow.down.circle") }.buttonStyle(AccentButton()).disabled(draft.selectedFiles.isEmpty || draft.checking || store.downloads.activeID != nil || store.maintaining).accessibilityIdentifier("download-model-version") }
            }
        }.padding(26).frame(width: 710, height: 705).background(Theme.background).interactiveDismissDisabled(draft.updating)
    }
    func openSplash(_ engine: Engine) {
        var repo = draft.listing?.repository ?? draft.replacement ?? draft.model.repository ?? ""
        if let original = draft.model.repository, original.contains(":"), draft.listing?.repository == draft.original?.repository { repo += ":" + original.components(separatedBy: ":").dropFirst().joined(separator: ":") }
        guard ModelOrigin.validRepository(repo.components(separatedBy: ":")[0]) else { draft.error = "请先检查仓库地址"; return }
        let free = (try? EnginePortPolicy.available(engine: engine, base: engine.defaultPort, count: 1, occupied: { self.store.services.portReserved($0) || NetworkProbe.portOccupied($0) }).first) ?? engine.defaultPort
        var command = "\(ServiceCommand.quote(engine.path)) serve --model \(ServiceCommand.quote(repo)) --port \(free) --max-context 32768"
        if let listing = draft.listing, listing.site == .huggingface { command += " --revision \(ServiceCommand.quote(listing.revision))" }
        store.modelUpdate = nil
        // Present the next sheet after SwiftUI dismisses this one.
        Task { try? await Task.sleep(nanoseconds: 250_000_000); store.prepareCommand(engine: engine, text: command) }
    }
}
