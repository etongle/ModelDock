import SwiftUI

@MainActor
extension AppStore {
    func engineServices(_ id: String) -> [ServiceSpec] {
        services.records.filter { $0.engineID == id }.sorted {
            if ($0.pid != nil) != ($1.pid != nil) { return $0.pid != nil }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.id < $1.id
        }
    }
    func externalEngineServices(_ id: String) -> [ObservedService] {
        services.external.filter { $0.engineID == id }.sorted { $0.port < $1.port }
    }
    func engineServiceCount(_ id: String) -> Int {
        engineServices(id).count + externalEngineServices(id).count
    }
}

@MainActor
struct EngineServicesView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    private var records: [ServiceSpec] { store.visibleEngineServices(store.engineID) }
    private var external: [ObservedService] { store.visibleExternalEngineServices(store.engineID) }
    private var running: Int { records.filter { services.status($0) == .running }.count + external.filter(\.ready).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(verbatim: L10n.text("服务实例")).font(.system(size: TypeScale.section, weight: .semibold))
                Spacer()
                Text(verbatim: L10n.text("\(records.count + external.count) 个服务 · \(running) 个运行中")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            }
            if let filter = store.engineInstanceFilter, filter.engineID == store.engineID {
                HStack {
                    Label(filter.model.name, systemImage: "line.3.horizontal.decrease.circle").font(.system(size: TypeScale.body)).lineLimit(2)
                    Spacer()
                    Button(L10n.text("显示全部实例")) { store.engineInstanceFilter = nil }.buttonStyle(.bordered).accessibilityIdentifier("show-all-engine-instances")
                }.foregroundStyle(Theme.muted)
            }
            if records.isEmpty && external.isEmpty {
                Text(verbatim: L10n.text("暂无服务。在下方选择模型和端口即可启动。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).padding(.vertical, 6)
            } else {
                ForEach(records) { spec in managedRow(spec) }
                ForEach(external) { service in externalRow(service) }
            }
        }.accessibilityIdentifier("engine-service-list")
    }
    private func managedRow(_ spec: ServiceSpec) -> some View {
        let status = services.status(spec)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(spec.modelName).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1).help(L10n.text(spec.modelName))
                    Text(verbatim: "127.0.0.1:\(spec.port)/v1").font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                StateLabel(title: services.statusTitle(spec), color: status.color)
            }
            ViewThatFits(in: .horizontal) {
                HStack { metadata(spec); Spacer(minLength: 12); actions(spec) }
                VStack(alignment: .leading, spacing: 12) { metadata(spec); actions(spec) }
            }
            ServiceOriginBadges(store: store, spec: spec)
            if !spec.modelID.isEmpty { ModelCapabilityBadge(capabilities: store.serviceCapabilities(spec), prefix: spec.pid == nil ? "启动设置 · " : "当前输入 · ") }
            ServiceComponentsSummary(store: store, spec: spec)
            if status == .starting { StartupProgressView(services: services, spec: spec, compact: true) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1) }
            .accessibilityIdentifier("engine-service-\(spec.id)")
    }
    private func metadata(_ spec: ServiceSpec) -> some View {
        Text(verbatim: L10n.text("端口 \(spec.port) · 上下文 \(spec.context.formatted()) tokens" + (spec.engineVersion.map { " · v\($0)" } ?? "")))
            .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false)
    }
    private func actions(_ spec: ServiceSpec) -> some View {
        HStack(spacing: 12) {
            Button(L10n.text("查看详情")) { store.showService(spec) }.buttonStyle(PlainAction()).accessibilityIdentifier("show-engine-service-\(spec.id)")
            if spec.pid != nil {
                Button { store.stop(spec) } label: { Label(L10n.text("停止"), systemImage: "stop.fill") }.buttonStyle(.bordered).disabled(services.status(spec) == .stopping).accessibilityIdentifier("stop-engine-service-\(spec.id)")
            } else {
                Button(L10n.text("配置")) { store.configureService(spec) }.buttonStyle(.bordered)
                Button(role: .destructive) { store.removeServiceConfiguration(spec) } label: { Label(L10n.text("删除"), systemImage: "trash") }.buttonStyle(.bordered).disabled(!services.canRemoveConfiguration(spec)).help(L10n.text("删除服务配置，保留模型文件和运行日志")).accessibilityIdentifier("delete-engine-service-\(spec.id)")
            }
        }.font(.system(size: TypeScale.body)).fixedSize()
    }
    private func externalRow(_ service: ObservedService) -> some View {
        let names = service.models.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent : $0 }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: L10n.text(names.isEmpty ? "外部模型服务" : names.joined(separator: "、"))).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1).help(L10n.text(service.models.joined(separator: "、")))
                Spacer(minLength: 8)
                StateLabel(title: service.ready ? "运行中 · 外部启动" : "端口占用 · 外部启动", color: service.ready ? .green : .orange)
            }
            HStack {
                Text(verbatim: "127.0.0.1:\(service.port)/v1").font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button(L10n.text("查看详情")) { if !store.serviceEngineFilter.isEmpty && store.serviceEngineFilter != service.engineID { store.serviceEngineFilter = "" }; store.selectedExternal = service.port; store.tab = .services }.buttonStyle(PlainAction())
            }
            if service.models.count == 1, let name = service.models.first { ModelCapabilityBadge(capabilities: services.modelCapabilities[service.port]?[name] ?? ModelCapabilities(), prefix: "当前输入 · ") }
        }.padding(18).background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1) }
            .accessibilityIdentifier("engine-external-service-\(service.port)")
    }
}
