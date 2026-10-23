import SwiftUI

@MainActor
struct MaintenanceView: View {
    @ObservedObject var store: AppStore
    var plan: MaintenancePlan
    var chosen: [RemovalItem] { EngineMaintenance.normalized(plan.items.filter { store.maintenanceSelection.contains($0.id) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 8) { Text(verbatim: L10n.text("\(plan.mode.rawValue) · \(plan.engine.name)")).font(.system(size: TypeScale.title, weight: .bold)); Text(verbatim: L10n.text("核对范围后再执行，专属模型和个人数据默认保留。")).foregroundStyle(Theme.muted) }; Spacer(); if store.maintaining { ProgressView().controlSize(.small) } }
            let blockers = plan.blockers + EngineMaintenance.downloadBlockers(chosen, jobs: store.downloads.jobs)
            if !blockers.isEmpty { Text(verbatim: L10n.text(blockers.joined(separator: "\n"))).foregroundStyle(Theme.warningText).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
            if store.maintenanceLog.isEmpty {
                HStack {
                    Button(L10n.text("选择程序与残留")) { store.maintenanceSelection = Set(plan.items.filter(\.selectedByDefault).map(\.id)) }
                    Button(L10n.text("全选（含个人数据和专属模型）")) { store.maintenanceSelection = Set(plan.items.map(\.id)) }
                }.buttonStyle(.bordered).controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach([RemovalGroup.package, .executable, .residue, .personal, .model], id: \.self) { group in
                            let items = plan.items.filter { $0.group == group }
                            if !items.isEmpty {
                                Text(verbatim: L10n.text(group.rawValue)).font(.system(size: TypeScale.body, weight: .semibold)).padding(.top, 10)
                                ForEach(items) { item in
                                    Toggle(isOn: Binding(get: { store.maintenanceSelection.contains(item.id) }, set: { if $0 { store.maintenanceSelection.insert(item.id) } else { store.maintenanceSelection.remove(item.id) } })) {
                                        VStack(alignment: .leading, spacing: 5) { HStack { Text(verbatim: L10n.text(URL(fileURLWithPath: item.path).lastPathComponent)).fontWeight(.medium); Spacer(); Text(verbatim: L10n.text(sizeLabel(item.bytes))).foregroundStyle(Theme.muted) }; Text(item.path).font(.system(size: TypeScale.caption, design: .monospaced)).textSelection(.enabled); Text(verbatim: L10n.text(item.note)).font(.system(size: TypeScale.callout)).foregroundStyle(group == .model ? Theme.warningText : Theme.muted) }.padding(.vertical, 5)
                                    }.toggleStyle(.checkbox)
                                }
                            }
                        }
                        if plan.items.isEmpty { Text(verbatim: L10n.text("未发现可清理项目。")).foregroundStyle(Theme.muted) }
                        if plan.mode == .uninstall { Divider(); Toggle(L10n.text("移除该引擎的服务配置、日志、测速记录，以及 pi/OpenCode 中的接入登记"), isOn: $store.removeMaintenanceConfigurations).toggleStyle(.checkbox) }
                        Divider(); Text(verbatim: L10n.text("保留的模型目录与源文件")).fontWeight(.semibold)
                        Text(verbatim: L10n.text(plan.preserved.joined(separator: "\n"))).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        ForEach(plan.notes, id: \.self) { Text(verbatim: L10n.text($0)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                    }.padding(.trailing, 10)
                }
            } else {
                ScrollView { Text(verbatim: store.maintenanceLog).font(.system(size: TypeScale.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Divider()
            HStack { Text(verbatim: L10n.text("已选 \(chosen.count) 项 · \(sizeLabel(chosen.reduce(0) { $0 + $1.bytes }))")).foregroundStyle(Theme.muted); Spacer(); Button(L10n.text(store.maintenanceLog.isEmpty ? "取消" : "完成")) { store.maintenancePlan = nil }.disabled(store.maintaining).keyboardShortcut(.cancelAction); if store.maintenanceLog.isEmpty { Button(L10n.text(plan.mode.rawValue)) { store.performMaintenance(plan, selectedIDs: store.maintenanceSelection, removeConfigurations: store.removeMaintenanceConfigurations) }.buttonStyle(.borderedProminent).tint(.red).disabled(chosen.isEmpty || !blockers.isEmpty || store.maintaining) } }
        }.padding(26).frame(width: 760, height: 650).background(Theme.background).interactiveDismissDisabled(store.maintaining)
    }
}

struct UsageBadge: View {
    var model: LocalModel
    var body: some View { Text(verbatim: L10n.text(model.usageTitle)).font(.system(size: TypeScale.caption, weight: .medium)).foregroundStyle(model.exclusiveEngine == nil ? Theme.muted : Theme.warningText).padding(.horizontal, 8).padding(.vertical, 4).background(model.exclusiveEngine == nil ? Theme.line : Color.orange.opacity(0.08), in: Capsule()).help(L10n.text(model.usageExplanation)) }
}

@MainActor
struct CompatibilityRows: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var engines: [Engine] { store.enabledEngines.filter { model.supportsEngineFormat($0) } }
    var disabledMatches: [Engine] { store.engines.filter { !store.engineEnabled($0.id) && model.supportsEngineFormat($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageBadge(model: model)
            Text(verbatim: L10n.text(model.usageExplanation)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let architecture = model.architecture { Text(verbatim: L10n.text("模型架构：\(architecture)")).font(.system(size: TypeScale.callout, design: .monospaced)).foregroundStyle(Theme.muted) }
            if engines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text(disabledMatches.isEmpty ? "暂无适配基座" : "适配基座已在全局设置中禁用。"), systemImage: "info.circle")
                    if !disabledMatches.isEmpty {
                        Text(verbatim: disabledMatches.map { L10n.text($0.name) }.joined(separator: " · "))
                        Button(L10n.text("启用适配基座…")) { store.showGlobalEngines = true }.buttonStyle(.bordered)
                    }
                }.font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).padding(.vertical, 7).accessibilityIdentifier("no-compatible-engine")
            }
            ForEach(engines) { engine in
                let match = model.compatibility(with: engine)
                HStack(alignment: .top, spacing: 14) {
                    EngineIcon(engine: engine, size: 40)
                    VStack(alignment: .leading, spacing: 6) { HStack { Text(verbatim: L10n.text(engine.name)).fontWeight(.semibold); Text(verbatim: L10n.text(match.title)).font(.system(size: TypeScale.caption, weight: .medium)).foregroundStyle(match.selectable ? Theme.muted : match.level == .importRequired ? Theme.warningText : Theme.muted); if !engine.installed { Text(verbatim: L10n.text("未安装")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted) } }; Text(verbatim: L10n.text(match.reason)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                    Spacer(minLength: 6)
                    if !engine.installed { Button(L10n.text("安装基座…")) { store.chooseEngine(engine.id); store.checkInstall() }.buttonStyle(.bordered).disabled(store.maintaining || store.installation.running || store.installation.checking != nil) }
                    else if match.selectable { Button(L10n.text("配置服务")) { store.launch(model: model, engine: engine) }.buttonStyle(.bordered).disabled(!engine.canServe || store.maintaining) }
                    else if match.level == .importRequired && engine.kind == .splash { Button(L10n.text("准备并启动…")) { store.prepareSplashSource(model, engine: engine) }.buttonStyle(.bordered).disabled(!engine.canServe || store.maintaining) }
                }.padding(.vertical, 7)
            }
        }
    }
}
