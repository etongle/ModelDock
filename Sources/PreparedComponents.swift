import SwiftUI

struct PreparedSplashGroup: Identifiable {
    var registrations: [SplashRegistration]
    var id: String { registrations[0].path }
    var title: String { registrations[0].vision == "none" ? "Splash · 纯文本" : "Splash · 文本 / 图片 / 文件" }
    var complete: Bool { registrations.allSatisfy(\.complete) }
    func contains(_ spec: ServiceSpec) -> Bool {
        spec.engineID == "splash" && registrations.contains { ModelInstancePolicy.samePath($0.path, spec.modelPath) }
    }
    var draft: String {
        let item = registrations[0]
        let sources = jsonFile(URL(fileURLWithPath: item.path).appendingPathComponent("model.json"))?["sources"] as? [String: [String: Any]]
        guard let repo = sources?["draft"]?["repo"] as? String else { return L10n.text("未记录草稿来源") }
        if !repo.hasPrefix("/") { return repo }
        var local = item.model(); local.path = repo; local.origin = nil; local.splashSelection = nil
        return ModelOrigin.read(local)?.repository ?? URL(fileURLWithPath: repo).lastPathComponent
    }
    static func all(_ registrations: [SplashRegistration]) -> [Self] {
        var groups = [Self](), keys = [String: Int]()
        for item in registrations.sorted(by: { $0.path < $1.path }) {
            let key = componentKey(item)
            if let index = keys[key] { groups[index].registrations.append(item) }
            else { keys[key] = groups.count; groups.append(.init(registrations: [item])) }
        }
        return groups.sorted { $0.title < $1.title }
    }
    private static func componentKey(_ item: SplashRegistration) -> String {
        guard item.complete, let files = jsonFile(URL(fileURLWithPath: item.path).appendingPathComponent("model.json"))?["files"] as? [String: [String: Any]], !files.isEmpty else { return item.path }
        var signature = [item.origin?.repository ?? item.name, item.origin?.revision ?? "", item.vision ?? "unknown"]
        for name in files.keys.sorted() {
            guard let path = files[name]?["path"] as? String,
                  let identity = FileIdentity.read(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) else { return item.path }
            signature += [name, "\(identity.device):\(identity.inode)"]
        }
        return String(decoding: (try? JSONEncoder().encode(signature)) ?? Data(item.path.utf8), as: UTF8.self)
    }
}

@MainActor private final class PreparedComponentsState: ObservableObject { @Published var expanded = Set<String>() }

@MainActor struct PreparedEngineComponentsView: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    @StateObject private var ui = PreparedComponentsState()
    var body: some View {
        if let registrations = model.splashRegistrations, !registrations.isEmpty {
            let groups = PreparedSplashGroup.all(registrations)
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: L10n.text("Splash 启动配置")).font(.system(size: TypeScale.body, weight: .semibold))
                Text(verbatim: ModelOrigin.read(model)?.repository ?? model.repository ?? model.name).font(.system(size: TypeScale.callout, design: .monospaced)).textSelection(.enabled)
                Text(verbatim: L10n.text("下面是同一主模型的可选启动方式，共用主权重。草稿用于加速，视觉组件处理图片和文件；实际加载情况请查看对应服务。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: L10n.format("{0} 种启动配置 · {1} 条准备记录", [String(groups.count), String(registrations.count)])).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                ForEach(groups) { group in
                    let services = store.services.records.filter(group.contains)
                    let running = services.filter { store.services.status($0) == .running }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(verbatim: L10n.text(group.title)).fontWeight(.semibold)
                            Spacer(minLength: 4)
                            StateLabel(title: !running.isEmpty ? L10n.format("{0} 个服务运行中", [String(running.count)]) : group.complete ? "可启动" : "Splash 组件需修复", color: !running.isEmpty ? .green : group.complete ? .gray : .orange)
                            if let spec = running.first ?? services.first { Button(L10n.text("查看服务")) { store.showService(spec) }.buttonStyle(.bordered) }
                        }
                        Text(verbatim: L10n.text("草稿加速") + " · " + group.draft).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        Text(verbatim: L10n.text("Tokenizer 与主模型共用；不同主模型可共用匹配的草稿组件。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        Button {
                            if !ui.expanded.insert(group.id).inserted { ui.expanded.remove(group.id) }
                        } label: {
                            HStack {
                                Text(verbatim: L10n.format("查看准备记录（{0}）", [String(group.registrations.count)]))
                                Spacer()
                                Image(systemName: ui.expanded.contains(group.id) ? "chevron.up" : "chevron.down")
                            }.contentShape(Rectangle()).padding(.vertical, 7)
                        }.buttonStyle(.plain).foregroundStyle(Theme.linkColor).accessibilityIdentifier("prepared-component-records-" + group.id)
                        if ui.expanded.contains(group.id) {
                            ForEach(group.registrations, id: \.path) { item in
                                HStack(spacing: 10) {
                                    Text(String(URL(fileURLWithPath: item.path).lastPathComponent.prefix(12))).font(.system(size: TypeScale.caption, design: .monospaced))
                                    Spacer(minLength: 4)
                                    Button(L10n.text("查看组件目录")) { store.reveal(item.path) }.buttonStyle(.bordered)
                                    Button(L10n.text("移除登记…")) { store.deleteModel(item.model()) }.buttonStyle(.bordered).disabled(store.modelFiles.deletingID != nil)
                                }
                            }
                        }
                    }.font(.system(size: TypeScale.body)).padding(12).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(18).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("prepared-engine-components")
        }
    }
}
