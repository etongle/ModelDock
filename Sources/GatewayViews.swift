import SwiftUI
import AppKit

@MainActor
struct GatewayWorkspace: View {
    @ObservedObject var store: AppStore
    @ObservedObject var gateway: GatewayController
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 36)).foregroundStyle(Theme.linkColor).frame(width: 72, height: 72).background(Theme.selection, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 8) { Text(verbatim: L10n.text("统一网关")).font(.system(size: TypeScale.display, weight: .bold)); Text(verbatim: L10n.text("一个接口，按模型路由到各个服务")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack { StateLabel(title: gateway.ready ? "网关运行中" : gateway.busy ? "正在处理" : "网关未启动", color: gateway.ready ? .green : gateway.busy ? .orange : .gray); Spacer(); Text(verbatim: L10n.text("\(gateway.routes.filter(\.enabled).count) 个模型路由")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                HStack { TextField(L10n.text("18790"), text: $gateway.portText).textFieldStyle(.roundedBorder).frame(width: 90).disabled(gateway.ownsProcess()); Text(verbatim: L10n.text(gateway.endpoint)).font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled); Spacer() }
                ViewThatFits(in: .horizontal) { HStack(spacing: 12) { controls }; VStack(alignment: .leading, spacing: 12) { controls } }
                Text(verbatim: L10n.text("网关只监听本机，使用独立密钥。停止网关只停止转发，各模型服务仍可直连。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                if gateway.ready { HStack(spacing: 22) { Text(verbatim: L10n.text("已转发 \(gateway.requests) 次")); Text(verbatim: L10n.text("当前并发 \(gateway.active)")); Text(verbatim: L10n.text("失败 \(gateway.failed) 次")) }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                if let error = gateway.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            }.padding(18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 13)).overlay { RoundedRectangle(cornerRadius: 13).stroke(Theme.line) }
            HStack { Text(verbatim: L10n.text("模型路由与输入模式")).font(.system(size: TypeScale.section, weight: .semibold)); Spacer(); Button(L10n.text("刷新")) { store.synchronizeGateway(); Task { await gateway.poll(); await store.services.refresh() } }.buttonStyle(PlainAction()) }
            if gateway.routes.isEmpty { EmptyMessage(symbol: "point.3.connected.trianglepath.dotted", title: L10n.text("还没有可用模型"), detail: "启动本地模型服务，或添加一个外部 OpenAI 兼容接口。") }
            ForEach(gateway.routes) { route in
                VStack(alignment: .leading, spacing: 13) {
                    HStack { VStack(alignment: .leading, spacing: 6) { Text(verbatim: L10n.text(route.name)).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1); Text(verbatim: L10n.text(route.alias)).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).help(L10n.text(route.alias)) }; Spacer(); Toggle(L10n.text("接入"), isOn: Binding(get: { gateway.routes.first { $0.id == route.id }?.enabled ?? false }, set: { gateway.setEnabled(route, $0, store: store) })).toggleStyle(.switch).controlSize(.small) }
                    HStack { Text(verbatim: L10n.text(route.capabilities.known ? route.capabilities.title : L10n.text("能力未声明 · 默认文本"))).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); Spacer(); Picker(L10n.text("输入模式"), selection: Binding(get: { gateway.routes.first { $0.id == route.id }?.mode ?? .automatic }, set: { gateway.setMode(route, $0, store: store) })) { Text(verbatim: L10n.text(InputMode.automatic.title)).tag(InputMode.automatic); Text(verbatim: L10n.text(InputMode.text.title)).tag(InputMode.text); if route.capabilities.supportsMedia { Text(verbatim: L10n.text(InputMode.multimodal.title)).tag(InputMode.multimodal) } }.labelsHidden().frame(width: 190) }
                    HStack { Text(verbatim: L10n.text(route.endpoint)).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1); Spacer(); Button(L10n.text("复制网关配置")) { copy(route) }.buttonStyle(PlainAction()).disabled(!gateway.ready || !route.enabled) }
                }.padding(16).background(Theme.line.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(verbatim: L10n.text("纯文本模式会明确拒绝媒体请求；多模态按原模型实际支持的图片、音频或文件转发。网关设置不改变直连服务的能力。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            Divider()
            HStack { Text(verbatim: L10n.text("手动添加的外部接口")).font(.system(size: TypeScale.section, weight: .semibold)); Spacer(); Button { gateway.editor = GatewayEndpointDraft() } label: { Label(L10n.text("添加接口…"), systemImage: "plus") }.buttonStyle(.bordered) }
            Text(verbatim: L10n.text("本机已发现的模型服务自动进入路由。也可添加远程或需要密钥的接口，每个接口都能直连或通过网关使用。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            ForEach(gateway.settings.endpoints) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text(verbatim: L10n.text(entry.name)).font(.system(size: TypeScale.body, weight: .semibold)); Text(verbatim: L10n.text(entry.url)).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1) }; Spacer(); Button(L10n.text("重新检测 / 编辑")) { gateway.editor = GatewayEndpointDraft(entry) }.buttonStyle(PlainAction()) }
                    HStack { Text(verbatim: L10n.text("\(entry.models.count) 个模型")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); Spacer(); if let target = store.configuredConnectionTargets.first(where: { $0.sourceID == "remote:\(entry.id)" }) { Button(L10n.text("直连 / 网关接入")) { store.connections.present(target: target) }.buttonStyle(.bordered) }; Button(role: .destructive) { gateway.removeEndpoint(entry, store: store) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.buttonStyle(.plain).help(L10n.text("只移除此接口登记，保留原服务和模型")) }
                }.padding(16).background(Theme.line.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder var controls: some View {
        if gateway.ownsProcess() { Button { gateway.stop() } label: { Label(L10n.text("停止网关"), systemImage: "stop.fill") }.buttonStyle(AccentButton(destructive: true)).disabled(gateway.busy) }
        else { Button { gateway.start(store: store) } label: { Label(L10n.text("启动网关"), systemImage: "play.fill") }.buttonStyle(AccentButton()).disabled(gateway.busy) }
        Button(L10n.text("复制接口与密钥")) { store.copy("Base URL: \(gateway.endpoint)\nAPI Key: \(gateway.settings.apiKey)") }.buttonStyle(.bordered).disabled(!gateway.ready)
        Button(L10n.text("一键接入")) { store.connections.present(port: gateway.settings.port, targets: store.gatewayConnectionTargets) }.buttonStyle(.bordered).disabled(!gateway.ready || store.gatewayConnectionTargets.isEmpty)
        Button { store.reveal(gateway.root.appendingPathComponent("gateway.log").path) } label: { Image(systemName: "doc.text") }.buttonStyle(.bordered).help(L10n.text("查看网关日志"))
    }
    func copy(_ route: GatewayRoute) { store.copy("Base URL: \(gateway.endpoint)\nModel: \(route.alias)\nAPI Key: \(gateway.settings.apiKey)") }
}

@MainActor
struct GatewayEndpointView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var gateway: GatewayController
    @ObservedObject var draft: GatewayEndpointDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: L10n.text(draft.editingID == nil ? "添加外部模型接口" : "编辑外部模型接口")).font(.system(size: TypeScale.section, weight: .bold))
            Text(verbatim: L10n.text("添加后可选择直连或网关；本机接口会核对监听进程，远程接口按登记地址与模型验证。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow { Text(verbatim: L10n.text("模型基座")); Picker(L10n.text("模型基座"), selection: $draft.engineID) { Text(verbatim: L10n.text("其他兼容接口")).tag("external"); Text(verbatim: L10n.text("Strata · Niko1221")).tag("strata") }.labelsHidden() }
                GridRow { Text(verbatim: L10n.text("名称")); TextField(L10n.text("例如：工作站模型"), text: $draft.name).textFieldStyle(.roundedBorder) }
                GridRow { Text(verbatim: L10n.text("Base URL")); TextField(L10n.text("https://example.com/v1"), text: $draft.url).textFieldStyle(.roundedBorder) }
                GridRow { Text(verbatim: L10n.text("API 密钥")); SecureField(L10n.text("无认证可留空"), text: $draft.apiKey).textFieldStyle(.roundedBorder) }
                GridRow { Text(verbatim: L10n.text("上下文长度")); TextField(L10n.text("按实际服务设置填写，未知可留空"), text: $draft.context).textFieldStyle(.roundedBorder) }
            }.font(.system(size: TypeScale.body))
            Divider()
            Text(verbatim: L10n.text("服务未声明能力时的手动配置")).font(.system(size: TypeScale.body, weight: .semibold))
            HStack(spacing: 20) { Toggle(L10n.text("支持图片"), isOn: $draft.images); Toggle(L10n.text("支持音频"), isOn: $draft.audio); Toggle(L10n.text("支持文件"), isOn: $draft.files) }.font(.system(size: TypeScale.body))
            Text(verbatim: L10n.text("只勾选原模型与服务确实支持的输入。接口明确声明能力时，以接口声明为准；网关不会为文本模型增加视觉能力。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            if let message = draft.message { Text(verbatim: L10n.text(message)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            Spacer()
            Divider()
            HStack { Button(L10n.text("取消")) { gateway.editor = nil }.disabled(draft.busy); Spacer(); if draft.busy { ProgressView().controlSize(.small) }; Button(L10n.text(draft.busy ? "正在检测…" : "检测模型并保存")) { gateway.addEndpoint(draft, store: store) }.buttonStyle(AccentButton()).disabled(draft.busy || draft.url.isEmpty) }
        }.padding(26).frame(width: 670, height: 550).background(Theme.background).interactiveDismissDisabled(draft.busy)
    }
}
