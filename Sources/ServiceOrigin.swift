import SwiftUI

struct SolutionServiceUse: Identifiable {
    var id: String
    var solutionID: String
    var title: String
    var created: Date
    var ownsConfiguration: Bool
}

struct ServiceOrigin {
    var uses: [SolutionServiceUse]
    var createdBySolution = false
    var detached: Bool { createdBySolution && uses.isEmpty }
    var solutionCreated: Bool { createdBySolution || uses.contains { $0.ownsConfiguration } }
    var reused: Bool { uses.contains { !$0.ownsConfiguration } }
    var title: String { detached ? "独立服务（原方案创建）" : solutionCreated ? "方案服务" : "原生服务" }
    var labels: [String] { [title] + (reused ? ["方案复用"] : []) }
}

@MainActor extension AppStore {
    func serviceOrigin(_ spec: ServiceSpec) -> ServiceOrigin {
        let uses = solutions.deployments.compactMap { record -> SolutionServiceUse? in
            let references = record.components.filter { $0.serviceID == spec.id }
            guard !references.isEmpty else { return nil }
            return .init(id: record.id, solutionID: record.solutionID,
                title: SolutionCatalog.all.first { $0.id == record.solutionID }?.title ?? record.solutionID,
                created: record.created, ownsConfiguration: references.contains { $0.ownsConfiguration })
        }
        return ServiceOrigin(uses: uses, createdBySolution: spec.solutionCreated == true)
    }
    func showSolution(_ use: SolutionServiceUse) {
        solutionTrial.reset()
        solutions.selectedID = use.solutionID
        solutions.selectedDeploymentID = use.id
        solutions.section = .instances
        tab = .solutions
    }
}

@MainActor struct ServiceOriginBadges: View {
    @ObservedObject var store: AppStore
    var spec: ServiceSpec
    var body: some View {
        let origin = store.serviceOrigin(spec)
        HStack(spacing: 6) {
            Label(L10n.text(origin.title), systemImage: origin.solutionCreated ? "square.stack.3d.up" : "server.rack")
            if origin.reused { Label(L10n.text("方案复用"), systemImage: "link") }
        }.font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(origin.uses.isEmpty ? Theme.muted : Theme.linkColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(origin.uses.isEmpty ? Theme.line.opacity(0.4) : Theme.selection, in: RoundedRectangle(cornerRadius: 6))
            .help(L10n.text(origin.solutionCreated ? "由解决方案创建的服务配置。" : "在运行引擎直接创建的服务；被方案复用后仍保留原生来源。"))
            .accessibilityIdentifier("service-origin-" + spec.id)
    }
}

@MainActor struct ServiceOriginDetails: View {
    @ObservedObject var store: AppStore
    var spec: ServiceSpec
    var body: some View {
        let origin = store.serviceOrigin(spec)
        VStack(alignment: .leading, spacing: 10) {
            ServiceOriginBadges(store: store, spec: spec)
            if origin.detached {
                Text(verbatim: L10n.text("原方案实例已移除，服务保留，可在这里独立管理。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
            if !origin.uses.isEmpty {
                Text(verbatim: L10n.text("关联方案")).font(.system(size: TypeScale.callout, weight: .semibold))
                ForEach(origin.uses) { use in
                    HStack(spacing: 10) {
                        Button { store.showSolution(use) } label: { Label(L10n.text(use.title), systemImage: "arrow.up.right") }.buttonStyle(PlainAction())
                        Spacer(minLength: 8)
                        Text(verbatim: L10n.text(use.ownsConfiguration ? "方案创建" : "方案复用")).foregroundStyle(Theme.muted)
                    }.font(.system(size: TypeScale.callout))
                }
                Text(verbatim: L10n.text("停止此服务会影响所有关联方案。")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
