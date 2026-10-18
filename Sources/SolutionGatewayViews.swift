import SwiftUI

@MainActor struct SolutionGatewayCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var gateway: GatewayController
    var deployment: SolutionDeployment
    var showName = false
    private var status: String {
        if !store.solutions.runtime(deployment, store: store).allReady { return "等待方案组件就绪" }
        if !gateway.ready { return "网关未启动" }
        if !gateway.supportsSolutionRoutes { return "重启网关后启用方案地址" }
        return gateway.solutionReady(deployment) ? "方案接口可用" : "等待方案组件就绪"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: L10n.text(showName ? SolutionCatalog.all.first { $0.id == deployment.solutionID }?.title ?? deployment.solutionID : "方案专属地址")).font(.system(size: TypeScale.body, weight: .semibold))
                    if showName { Text(verbatim: deployment.created.formatted(date: .abbreviated, time: .shortened)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted) }
                }
                Spacer(minLength: 8)
                StateLabel(title: status, color: gateway.solutionReady(deployment) && store.solutions.runtime(deployment, store: store).allReady ? .green : .gray)
            }
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: gateway.solutionEndpoint(deployment)).font(.system(size: TypeScale.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                CopyIconButton(help: "复制方案地址") { store.copy(gateway.solutionEndpoint(deployment)) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { controls }
                VStack(alignment: .leading, spacing: 10) { controls }
            }
            Text(verbatim: L10n.text("同一方案实例的地址保持固定；模型端口变化由网关处理。使用统一网关密钥。"))
                .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Menu(L10n.text("复制调用示例")) {
                    ForEach(SolutionGatewayExamples.all(deployment, endpoint: gateway.solutionEndpoint(deployment))) { example in
                        Button(L10n.text(example.title)) { store.copy(example.script) }
                    }
                }.fixedSize().accessibilityIdentifier("solution-copy-examples-" + deployment.id)
                Text(verbatim: L10n.text("示例使用 MODELDOCK_API_KEY 环境变量。"))
                    .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(L10n.text("组件接口与接入说明")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: L10n.text("将此地址填为 Base URL，model 使用下方组件名。每次请求只调用对应组件；语音翻译按识别、翻译、配音依次调用。"))
                        .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(deployment.components) { component in
                        Text(verbatim: component.role.gatewayModel + "  →  " + component.role.gatewayOperation).font(.system(size: TypeScale.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Text(verbatim: L10n.text("可通过 /models 查看此方案的可用组件；/health 查看组件就绪状态。服务未就绪时会明确报错，不会切换到其他方案。"))
                        .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }.font(.system(size: TypeScale.callout))
            if let error = gateway.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
            .accessibilityIdentifier("solution-gateway-" + deployment.id)
    }
    @ViewBuilder private var controls: some View {
        Button(L10n.text("复制方案接入配置")) {
            do { store.copy(try gateway.solutionConnection(deployment)) }
            catch { gateway.error = error.localizedDescription }
        }.buttonStyle(.bordered)
        if !gateway.ownsProcess() {
            Button(L10n.text("启动网关")) { gateway.start(store: store) }.buttonStyle(.bordered).disabled(gateway.busy)
        } else if gateway.ready && !gateway.supportsSolutionRoutes {
            Button(L10n.text("重启网关")) { gateway.restartForSolutions(store: store) }.buttonStyle(.bordered).disabled(gateway.busy || gateway.active > 0)
        }
        if showName {
            Button(L10n.text("查看方案")) { store.solutions.selectedID = SolutionCatalog.visible.contains(where: { $0.id == deployment.solutionID }) ? deployment.solutionID : "voice-translation"; store.solutions.selectedDeploymentID = deployment.id; store.solutions.section = .instances; store.tab = .solutions }.buttonStyle(PlainAction())
        } else {
            Button(L10n.text("查看统一网关")) { store.gatewaySelected = true; store.tab = .services }.buttonStyle(PlainAction())
        }
    }
}

@MainActor struct GatewaySolutionsSection: View {
    @ObservedObject var store: AppStore
    @ObservedObject var gateway: GatewayController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L10n.text("方案专属地址")).font(.system(size: TypeScale.section, weight: .semibold))
            if store.solutions.deployments.isEmpty {
                Text(verbatim: L10n.text("安装解决方案后，每个方案实例会获得独立的接入地址。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
            ForEach(store.solutions.deployments.reversed()) { record in
                SolutionGatewayCard(store: store, gateway: gateway, deployment: record, showName: true)
            }
        }
    }
}
