import SwiftUI

@MainActor
struct StrataIntegrationView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.text("Strata 服务接入")).font(.system(size: TypeScale.section, weight: .semibold))
            Text(verbatim: L10n.text("官方主线目前使用 Windows/Linux 的 CUDA 或 HIP 引擎。Mac Metal PR #1449 已关闭且未合并，尚无官方 Mac 发行包。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            Text(verbatim: L10n.text("可以登记远程工作站，或已自行启动的本机实验服务。读取接口公布的模型和媒体能力后，支持直连、统一网关及 pi / OpenCode 配置。")).font(.system(size: TypeScale.body))
            Text(verbatim: L10n.text("Flash-Next 使用配套 GGUF、分层权重及可选视觉组件；普通 Qwen 27B、MLX 权重与 Splash packed 不直接通用。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            HStack {
                Button(L10n.text("添加 Strata 接口…")) {
                    let draft = GatewayEndpointDraft(); draft.name = "Strata"; draft.engineID = "strata"; draft.url = "http://127.0.0.1:8080/v1"
                    store.gateway.editor = draft
                }.buttonStyle(.borderedProminent).tint(Theme.accent).accessibilityIdentifier("add-strata-endpoint")
                Link("官方安装说明", destination: URL(string: "https://www.stratat.com/en/install")!)
                Link("Mac 支持状态", destination: URL(string: "https://github.com/Niko1221/Strata/pull/1449")!)
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
