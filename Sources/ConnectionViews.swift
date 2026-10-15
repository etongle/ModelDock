import SwiftUI
import AppKit

@MainActor
struct ConnectionEntry: View {
    @ObservedObject var store: AppStore
    var port: Int
    var available: Bool { store.connectionTargets.contains { $0.port == port } }
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.up.forward.app").font(.system(size: 23)).foregroundStyle(Theme.linkColor)
                .frame(width: 48, height: 48).background(Theme.selection, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: L10n.text("接入编程助手")).font(.system(size: TypeScale.body, weight: .semibold))
                Text(verbatim: L10n.text(available ? "OpenCode、pi、Hermes · 使用这个本地模型服务" : "服务就绪后，可一键连接 OpenCode、pi 和 Hermes"))
                    .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 10)
            Button { store.connections.present(port: port, targets: store.connectionTargets) } label: { Label(L10n.text("一键接入"), systemImage: "link") }
                .buttonStyle(AccentButton()).disabled(!available).accessibilityIdentifier("connect-clients")
        }
        .padding(18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

@MainActor
struct ClientConnectionsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: ConnectionController
    var port: Int
    var targets: [ConnectionTarget] {
        let values = controller.viaGateway ? store.gatewayConnectionTargets : store.directConnectionTargets
        if let source = controller.draft?.sourceID { return values.filter { $0.sourceID == source } }
        let sources = Set(store.directConnectionTargets.filter { $0.port == port }.compactMap(\.sourceID))
        return values.filter { controller.viaGateway ? (port == store.gateway.settings.port || sources.contains($0.sourceID ?? "")) : $0.port == port }
    }
    var selected: ConnectionTarget? { targets.first { $0.id == controller.modelID } }
    var invalidContext: Bool { !(2048...1_048_576).contains(controller.context) || selected?.context.map { controller.context > $0 } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "link").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.linkColor)
                    .frame(width: 52, height: 52).background(Theme.selection, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: L10n.text("一键接入")).font(.system(size: TypeScale.title, weight: .bold))
                    Text(verbatim: L10n.text("选择助手，在终端中使用模型服务")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(L10n.text("完成")) { controller.draft = nil }.keyboardShortcut(.cancelAction).disabled(controller.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { StateLabel(title: selected.map { "\($0.engineName) · \($0.isRemote ? "外部登记" : "接口可用")" } ?? "服务当前不可用", color: selected == nil ? .orange : .green); Spacer()
                            Text(verbatim: L10n.text(selected?.endpoint ?? "127.0.0.1:\(port)")).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1) }
                        if port != store.gateway.settings.port || controller.draft?.sourceID != nil {
                            Picker(L10n.text("接入方式"), selection: $controller.viaGateway) { Text(verbatim: L10n.text("直接连接服务")).tag(false); Text(verbatim: L10n.text("通过统一网关")).tag(true) }.pickerStyle(.segmented).disabled(controller.busy || !store.gateway.ready)
                                .onChange(of: controller.viaGateway) { _, _ in controller.modelID = targets.first?.id ?? ""; controller.context = targets.first?.context ?? 8192; controller.lastConnection = nil }
                            if !store.gateway.ready { Text(verbatim: L10n.text("启动统一网关后可选择网关接入，直连服务可立即使用。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                        }
                        Picker(L10n.text("使用模型"), selection: $controller.modelID) { ForEach(targets) { target in Text(verbatim: L10n.text(target.model)).tag(target.id) } }
                            .disabled(controller.busy || targets.isEmpty)
                            .onChange(of: controller.modelID) { _, _ in
                                controller.context = selected?.context ?? 8192; controller.error = nil; controller.message = nil; controller.lastConnection = nil
                            }
                        HStack {
                            Text(verbatim: L10n.text("上下文长度")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                            if let context = selected?.context { Text(verbatim: L10n.text("\(context) tokens")).font(.system(size: TypeScale.body, design: .monospaced)) }
                            else { TextField(L10n.text("8192"), value: $controller.context, format: .number.grouping(.never)).frame(width: 105).textFieldStyle(.roundedBorder).disabled(controller.busy)
                                Text(verbatim: L10n.text("按外部服务实际设置填写")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                            Spacer()
                        }
                    }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    if let selected, selected.context.map({ $0 < 32768 }) == true {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: L10n.text("当前上下文容易被工具提示占满")).font(.system(size: TypeScale.body, weight: .semibold)).foregroundStyle(Theme.warningText)
                                Text(verbatim: L10n.text(store.connections.canExpandContext(store: store, port: port) ? "扩展至 32K 后，重新接入编程助手。" : "请先在原服务中将上下文调整至 32K。"))
                                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if store.connections.canExpandContext(store: store, port: port) {
                                Button(L10n.text("扩展至 32K…")) { controller.requestContextExpansion(store: store, port: port) }.disabled(controller.busy)
                            }
                        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack(spacing: 14) {
                        Image(systemName: "folder").foregroundStyle(Theme.linkColor).font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: L10n.text("工作目录")).font(.system(size: TypeScale.body, weight: .semibold))
                            Text(verbatim: L10n.text(controller.project)).font(.system(size: TypeScale.body)).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.muted).help(L10n.text(controller.project))
                        }
                        Spacer()
                        if controller.busy { ProgressView().controlSize(.small) }
                        Button(L10n.text("选择文件夹…")) { controller.chooseProject() }.disabled(controller.busy)
                    }.padding(.horizontal, 3)
                    HStack {
                        Text(verbatim: L10n.text("客户端")).font(.system(size: TypeScale.body, weight: .semibold))
                        Spacer()
                        if controller.discovering { ProgressView().controlSize(.small) }
                        Button(L10n.text("重新检测")) { controller.discover() }.buttonStyle(PlainAction()).disabled(controller.discovering || controller.busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L10n.text("同时写入 pi / OpenCode 用户配置"), isOn: $controller.registerInClient).toggleStyle(.checkbox)
                        Toggle(L10n.text("启用联网搜索（Exa）"), isOn: $controller.webSearch).toggleStyle(.checkbox)
                        Text(verbatim: L10n.text("保留已有模型和默认设置；写入前自动备份。搜索由客户端联网执行，pi 需要支持 MCP 的版本。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    }.disabled(controller.busy)
                    ForEach(CodingClient.allCases) { client in clientRow(client) }
                    if let error = controller.error { Label(L10n.text(error), systemImage: "exclamationmark.circle").font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
                    if let message = controller.message { Label(L10n.text(message), systemImage: "checkmark.circle").font(.system(size: TypeScale.body)).foregroundStyle(Theme.successText) }
                    if invalidContext { Text(verbatim: L10n.text("上下文长度需要在 2,048 到 1,048,576 之间，且不能超过服务的实际设置。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText) }
                    if let connection = controller.lastConnection {
                        HStack { Text(verbatim: L10n.text("连接配置已保存")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); Spacer()
                            Button(L10n.text("查看配置")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: connection.registeredConfiguration ?? connection.configuration)]) }.buttonStyle(PlainAction()) }
                    }
                }.padding(.trailing, 4)
            }
            VStack(alignment: .leading, spacing: 9) {
                Divider()
                HStack {
                    Label(L10n.text("已有配置保留，客户端配置写入前备份"), systemImage: "checkmark.shield")
                        .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(L10n.text("复制通用 API 配置")) {
                        if let selected {
                            store.copy("Base URL: \(selected.endpoint)\nModel: \(selected.model)\nAPI Key: \(selected.apiKey ?? "local-model-manager")")
                            controller.message = "已复制接口、模型名称和连接密钥，可用于其他兼容客户端。"; controller.error = nil
                        }
                    }.buttonStyle(PlainAction()).disabled(selected == nil || controller.busy)
                }
                Text(verbatim: L10n.text("常规启动可以选择已登记模型；本工具打开的连接使用独立运行配置。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
        }
        .padding(26).frame(width: 780, height: min(800, max(600, (NSScreen.main?.visibleFrame.height ?? 900) - 100))).background(Theme.background)
        .interactiveDismissDisabled(controller.busy)
    }
    @ViewBuilder func clientRow(_ client: CodingClient) -> some View {
        let installation = controller.installations.first { $0.id == client }
        let requirement = client.contextRequirement(controller.context)
        HStack(spacing: 14) {
            Image(systemName: client.symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.linkColor)
                .frame(width: 48, height: 48).background(Theme.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(verbatim: L10n.text(client.title)).font(.system(size: TypeScale.body, weight: .semibold))
                    if let installation { Text(verbatim: L10n.text(installation.executable == nil ? "未安装" : (installation.version.isEmpty ? "已安装" : installation.version))).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Text(verbatim: L10n.text(requirement ?? client.description)).font(.system(size: TypeScale.callout)).foregroundStyle(requirement == nil ? Theme.muted : Theme.warningText)
            }
            Spacer(minLength: 12)
            if installation?.executable != nil {
                if client != .hermes {
                    Button(L10n.text("写入配置")) { controller.connect(client, store: store, launch: false, registerOnly: true) }.buttonStyle(.bordered)
                        .disabled(controller.busy || selected == nil || invalidContext || requirement != nil).accessibilityIdentifier("register-client-" + client.rawValue)
                }
                Button(L10n.text("复制命令")) { controller.connect(client, store: store, launch: false) }.buttonStyle(.bordered)
                    .disabled(controller.busy || selected == nil || invalidContext || requirement != nil).accessibilityLabel(L10n.text("复制 \(client.title) 连接命令"))
                Button { controller.connect(client, store: store, launch: true) } label: { Label(L10n.text("接入并打开"), systemImage: "arrow.up.right") }
                    .buttonStyle(AccentButton()).disabled(controller.busy || selected == nil || invalidContext || requirement != nil).accessibilityLabel(L10n.text("接入并打开 \(client.title)"))
            } else {
                Button(L10n.text(controller.discovering ? "正在检测…" : "安装指南")) { NSWorkspace.shared.open(client.website) }.buttonStyle(.bordered).disabled(controller.discovering)
            }
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}
