import SwiftUI

@MainActor
struct StrataIntegrationView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.text("Strata 服务接入")).font(.system(size: TypeScale.section, weight: .semibold))
            Text(verbatim: L10n.text("Strata Metal 为实验性支持，需要 macOS 15+ 和 Command Line Tools。从官方源码编译，可准备 Flash-Next 模型、MTP 草稿及匹配的图片组件。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            StrataPreparationView(store: store, controller: store.strata)
            Text(verbatim: L10n.text("可以登记远程工作站，或已自行启动的本机实验服务。读取接口公布的模型和媒体能力后，支持直连、统一网关及 pi / OpenCode 配置。")).font(.system(size: TypeScale.body))
            Text(verbatim: L10n.text("Flash-Next 使用配套 GGUF、分层权重及可选视觉组件；普通 Qwen 27B、MLX 权重与 Splash packed 不直接通用。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            HStack {
                Button(L10n.text("添加 Strata 接口…")) {
                    let draft = GatewayEndpointDraft(); draft.name = "Strata"; draft.engineID = "strata"; draft.url = "http://127.0.0.1:8080/v1"
                    store.gateway.editor = draft
                }.buttonStyle(.borderedProminent).tint(Theme.accent).accessibilityIdentifier("add-strata-endpoint")
                Link("官方安装说明", destination: URL(string: "https://www.stratat.com/en/install")!)
                Link("Mac 支持状态", destination: URL(string: "https://github.com/Niko1221/Strata/blob/main/docs/MAC.md")!)
            }.font(.system(size: TypeScale.body))
            ForEach(store.gateway.settings.endpoints.filter { $0.engineID == "strata" }) { endpoint in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: L10n.text(endpoint.name)).font(.system(size: TypeScale.body, weight: .semibold))
                    Text(verbatim: L10n.text(endpoint.url)).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted)
                    Text(verbatim: L10n.text("已登记 \(endpoint.models.count) 个模型 · 接入时重新检查接口")).font(.system(size: TypeScale.callout))
                    HStack {
                        Button(L10n.text("编辑接口")) { store.gateway.editor = GatewayEndpointDraft(endpoint) }
                        Button(L10n.text("查看统一网关")) { store.gatewaySelected = true; store.tab = .services }
                    }.buttonStyle(.bordered)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(22).background(Theme.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor struct StrataPreparationView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: StrataController
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(verbatim: L10n.text("Strata 本地模型与配套组件")).font(.system(size: TypeScale.body, weight: .semibold))
            if !store.engine.canServe {
                Text(verbatim: L10n.text("先在安装与更新中编译 Strata 引擎，再选择模型量化版本。模型下载和引擎安装分开管理。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            } else {
                HStack {
                    Picker(L10n.text("Flash-Next 量化版本"), selection: $controller.variant) {
                        ForEach(controller.variants) { item in Text(verbatim: item.name + " · " + String(format: "%.1f GB", item.downloadGB)).tag(item.name) }
                    }.frame(maxWidth: 360).disabled(controller.busy)
                    Spacer()
                    if controller.loading { ProgressView().controlSize(.small) }
                }
                Toggle(L10n.text("准备图片输入组件"), isOn: $controller.vision).toggleStyle(.checkbox).disabled(controller.busy)
                Text(verbatim: L10n.text("主权重与 n-gram 使用下载任务管理，可暂停、续传和查看每个文件。MTP、词表与视觉组件在准备阶段校验并关联；普通 Qwen 27B 或 Splash 草稿不能替代。型号支持以官方 Mac 列表为准。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                HStack { Button(L10n.text("下载主模型文件…")) { controller.download(store: store) }.buttonStyle(.bordered).disabled(controller.busy || controller.variants.isEmpty); Button(L10n.text("选择已下载分片目录…")) { controller.chooseLocal(store: store) }.buttonStyle(.bordered).disabled(controller.busy) }
                Text(verbatim: controller.localShards.isEmpty ? L10n.text("尚未选择已下载的 GGUF 分片") : controller.localShards).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                HStack {
                    Text(verbatim: L10n.text("模型与组件保存位置")).font(.system(size: TypeScale.callout))
                    Text(verbatim: controller.folder.isEmpty ? store.downloads.destination : controller.folder).font(.system(size: TypeScale.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L10n.text("选择目录…")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { controller.folder = url.resolvingSymlinksInPath().path }
                    }.buttonStyle(.bordered).disabled(controller.busy)
                }
                Button(L10n.text("准备模型与组件")) { controller.prepare(store: store) }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(controller.busy || controller.variants.isEmpty || store.installation.running || store.maintaining)
                Text(verbatim: L10n.text("每次准备保存为独立组合；旧模型保留，正在使用的组合不会被覆盖。准备时先停止 Strata 实例，其他基座不参与此次操作。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
            if controller.busy { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text(controller.progress)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted); Spacer(); Button(L10n.text("暂停准备")) { controller.pause() }.buttonStyle(.bordered) } }
            if let component = controller.componentProgress { Text(verbatim: component).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled) }
            if let message = controller.message { Label(L10n.text(message), systemImage: controller.messageIsError ? "exclamationmark.triangle.fill" : "info.circle").font(.system(size: TypeScale.callout)).foregroundStyle(controller.messageIsError ? Theme.errorText : Theme.muted).textSelection(.enabled) }
            if !controller.log.isEmpty { DisclosureGroup("准备日志与组件下载进度") { ScrollView { Text(verbatim: String(controller.log.suffix(18_000))).font(.system(size: TypeScale.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 180) }.font(.system(size: TypeScale.callout)) }
        }.task(id: store.engine.path) { controller.load(engine: store.engine) }
    }
}
