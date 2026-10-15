import Foundation
import SwiftUI

struct EngineComponentRelease: Codable, Identifiable {
    var id: String
    var name: String
    var version: String
}
enum EngineVersionState: String {
    case missing, update, current, newer, unknown
    var title: String {
        switch self { case .missing: return "未安装"; case .update: return "有新版本"; case .current: return "已是最新"; case .newer: return "已安装较新版本"; case .unknown: return "版本待核实" }
    }
    var needsAction: Bool { self == .missing || self == .update || self == .unknown }
}
struct EngineVersionRow: Identifiable {
    var id: String; var name: String; var installed: String?; var available: String
    var state: EngineVersionState { EngineVersionPolicy.state(installed: installed, available: available) }
}
enum EngineVersionPolicy {
    static func state(installed: String?, available: String) -> EngineVersionState {
        guard let installed else { return .missing }
        if let old = ServiceStartupProgress.match(#"^([0-9.]+)\+([a-f0-9]{12})$"#, in: installed), let new = ServiceStartupProgress.match(#"^([0-9.]+)\+([a-f0-9]{12})$"#, in: available) {
            if old == new { return .current }
            return old[1].compare(new[1], options: .numeric) == .orderedDescending ? .newer : .update
        }
        func normalized(_ value: String) -> String? {
            let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
            return text.range(of: #"^(?:b)?[0-9]+(?:[._,][0-9]+)*$"#, options: .regularExpression) != nil ? text : nil
        }
        guard let current = normalized(installed), let latest = normalized(available), current.hasPrefix("b") == latest.hasPrefix("b") else { return .unknown }
        switch current.compare(latest, options: .numeric) { case .orderedSame: return .current; case .orderedAscending: return .update; case .orderedDescending: return .newer }
    }
    static func appVersion(_ path: String?, available: String) -> String? {
        guard let path else { return nil }
        guard let data = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"), let version = data["CFBundleShortVersionString"] as? String else { return "版本未知" }
        if available.contains(","), let build = data["CFBundleVersion"] as? String { return version + "," + build }
        return version
    }
    static func rows(engine: Engine, release: EngineRelease) -> [EngineVersionRow] {
        let components = release.components ?? (engine.kind == .mlx ? [EngineComponentRelease(id: "mlx-lm", name: "MLX-LM 文本组件", version: release.version)] + (release.visionVersion.map { [.init(id: "mlx-vlm", name: "MLX-VLM 多模态组件", version: $0)] } ?? []) : [.init(id: engine.kind == .llama ? "llama-app" : engine.id, name: engine.kind == .llama ? "Llama 桌面应用" : engine.name, version: release.version)])
        return components.map { component in
            let installed: String?
            switch component.id {
            case "llama.cpp": installed = engine.canServe ? Scanner.version(engine.path, fallback: "版本未知") : nil
            case "llama-app": installed = appVersion(engine.appPath, available: component.version)
            case "mlx-lm": installed = EnginePaths.manifest(.mlx)?.version ?? (URL(fileURLWithPath: engine.path).lastPathComponent == "mlx_lm.server" && engine.canServe ? engine.version.components(separatedBy: " · ").first : nil)
            case "mlx-vlm": installed = engine.visionPath == nil ? nil : engine.visionVersion ?? "版本未知"
            case "strata": installed = engine.installed ? engine.version : nil
            default:
                if !engine.installed { installed = nil }
                else if engine.kind == .lmstudio { installed = appVersion(engine.appPath, available: component.version) }
                else { installed = Scanner.version(engine.path, fallback: engine.version) }
            }
            return .init(id: component.id, name: component.name, installed: installed, available: component.version)
        }
    }
    static func summary(_ rows: [EngineVersionRow]) -> String {
        if rows.contains(where: { $0.state == .update }) { return "发现可更新的组件" }
        if rows.contains(where: { $0.state == .missing }) { return "有组件尚未安装" }
        if rows.contains(where: { $0.state == .unknown }) { return "部分组件版本需要核实" }
        if rows.contains(where: { $0.state == .newer }) { return "已安装版本高于更新源" }
        return "所有组件已是最新版本"
    }
    static func displayVersion(_ engine: Engine) -> String { engine.kind == .llama ? (engine.canServe ? "CLI " : "应用 ") + engine.version : engine.version }
}
struct EngineVersionTable: View {
    var rows: [EngineVersionRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(verbatim: L10n.text("组件")).frame(width: 150, alignment: .leading); Text(verbatim: L10n.text("当前已安装")).frame(width: 85, alignment: .leading); Text(verbatim: L10n.text("最新可安装")).frame(width: 85, alignment: .leading); Spacer(); Text(verbatim: L10n.text("更新状态")).frame(width: 115, alignment: .leading) }.font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
            ForEach(rows) { row in
                HStack(alignment: .top) {
                    Text(verbatim: L10n.text(row.name)).fontWeight(.medium).frame(width: 150, alignment: .leading)
                    Text(verbatim: L10n.text(row.installed ?? "未安装")).frame(width: 85, alignment: .leading)
                    Text(verbatim: L10n.text(row.available)).frame(width: 85, alignment: .leading)
                    Spacer(minLength: 4)
                    Label(L10n.text(row.state.title), systemImage: row.state == .current || row.state == .newer ? "checkmark.circle" : row.state == .update ? "arrow.up.circle" : "info.circle").foregroundStyle(row.state == .update ? Theme.warningText : Theme.muted).frame(width: 115, alignment: .leading)
                }.font(.system(size: TypeScale.callout)).textSelection(.enabled).accessibilityElement(children: .combine)
            }
        }.padding(14).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}
