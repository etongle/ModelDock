import Foundation
import SwiftUI

struct ServiceComponent: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var name: String
    var path: String?
    var state: String
    var confirmed: Bool
}
struct ServiceComponentSnapshot: Codable, Hashable {
    var processStart: UInt64?
    var startedAt: Date?
    var entries: [ServiceComponent]
}
enum ServiceComponentEvidence {
    static func collect(spec: ServiceSpec, models: [LocalModel], log: String, capabilities: ModelCapabilities, status: ServiceStatus) -> ServiceComponentSnapshot? {
        if spec.engineID == "strata" {
            guard let line = ServiceStartupProgress.latestAttempt(log).components(separatedBy: .newlines).last(where: { $0.hasPrefix("[ModelDock Strata components] ") }),
                  let data = line.dropFirst("[ModelDock Strata components] ".count).data(using: .utf8), let paths = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let titles = ["weights": "主模型权重", "ngram": "n-gram 配套表", "draft": "MTP 草稿加速", "vision": "视觉投影", "tokenizer": "Tokenizer"]
            let entries = ["weights", "ngram", "draft", "vision", "tokenizer"].map { role -> ServiceComponent in
                let path = paths[role] as? String
                return .init(id: role, title: titles[role]!, name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "本次未启用", path: path, state: path == nil ? "未启用" : status == .running ? "已启用" : "本次启动已指定", confirmed: path == nil || status == .running)
            }
            return .init(processStart: spec.processStart, startedAt: spec.startedAt, entries: entries)
        }
        guard ["splash", "mlx", "llama", "prism"].contains(spec.engineID) else { return nil }
        let attempt = ServiceStartupProgress.latestAttempt(log)
        let arguments = spec.launchArguments ?? ((try? ServiceCommand.words(spec.commandText ?? "")) ?? [])
        func argument(_ flag: String) -> String? { guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }; return arguments[i + 1] }
        let reference = argument("--model") ?? spec.modelName
        let installation = ServiceStartupProgress.match(#"Installing[^\n]*;\s*draft\s+([^;\s]+);\s*vision\s+(enabled|disabled)"#, in: attempt)
        let fetchedDraft = ServiceStartupProgress.draftSource(attempt)
        let explicitDraft = spec.draftModelPath ?? argument("--draft-model")
        let logDraft = installation?[1] ?? fetchedDraft?.repository ?? ServiceStartupProgress.match(#"Loading speculative drafter[^\n]*?:\s*([^\r\n]+)"#, in: attempt)?[1].trimmingCharacters(in: .whitespaces)
        let selectedDraft = explicitDraft ?? logDraft
        let revision = argument("--revision") ?? ServiceStartupProgress.match("Fetching[^\n]*from\\s+" + NSRegularExpression.escapedPattern(for: reference) + "@([a-f0-9]{12,40})", in: attempt)?[1]
        let prepared = models.flatMap(\.preparedSplashModels).filter { model in
            guard model.origin?.repository == reference || model.repository == reference else { return false }
            if let revision, model.origin?.revision.hasPrefix(revision) != true { return false }
            if let logDraft, let sources = jsonFile(URL(fileURLWithPath: model.path).appendingPathComponent("model.json"))?["sources"] as? [String: [String: Any]] {
                if sources["draft"]?["repo"] as? String != logDraft { return false }
                if let fetchedDraft, (sources["draft"]?["revision"] as? String)?.hasPrefix(fetchedDraft.revision) != true { return false }
            }
            return true
        }
        let assembly = prepared.first { $0.path == spec.modelPath } ?? (prepared.count == 1 ? prepared.first : nil)
        let record = assembly.flatMap { jsonFile(URL(fileURLWithPath: $0.path).appendingPathComponent("model.json")) }
        let files = record?["files"] as? [String: [String: Any]] ?? [:]
        let primary = models.first { $0.matchesID(spec.modelID) || (!$0.path.isEmpty && $0.path == spec.modelPath) } ?? models.first { $0.origin?.repository == reference && (revision == nil || $0.origin?.revision.hasPrefix(revision!) == true) }
        var entries: [ServiceComponent] = []
        if let selectedDraft {
            let path: String?
            if selectedDraft.hasPrefix("/") { path = selectedDraft }
            else if let value = files["draft/config.json"]?["path"] as? String { path = URL(fileURLWithPath: value).deletingLastPathComponent().path }
            else { path = nil }
            let localName = path.flatMap { path in models.first { $0.path == path }?.origin?.repository ?? ModelOrigin.displayName(folder: URL(fileURLWithPath: path)) }
            let confirmed = status == .running && (installation != nil || attempt.lowercased().contains("loading speculative drafter"))
            entries.append(.init(id: "draft", title: "草稿加速", name: selectedDraft.hasPrefix("/") ? localName ?? URL(fileURLWithPath: selectedDraft).lastPathComponent : selectedDraft, path: path, state: confirmed ? "已启用" : status == .starting ? "正在准备" : "本次启动已指定", confirmed: confirmed))
        } else if spec.engineID == "mlx" {
            entries.append(.init(id: "draft", title: "草稿加速", name: "本次启动未指定草稿模型", path: nil, state: "未启用", confirmed: true))
        }
        let textOnly = spec.inputMode == .text || arguments.contains("--language-only") || arguments.contains("--no-mmproj")
        let visionLog = installation?[2] == "enabled"
        let visionConfirmed = status == .running && (capabilities.known || installation != nil)
        let mediaEnabled = !textOnly && (capabilities.known ? capabilities.supportsMedia : visionLog)
        let projector = spec.projectorPath ?? argument("--mmproj")
        let visionPath = projector ?? (files["vision/config.json"]?["path"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? (mediaEnabled ? primary?.folder : nil)
        entries.append(.init(id: "vision", title: projector == nil ? "视觉组件" : "视觉投影", name: mediaEnabled ? (projector.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "随主模型加载 · 图片" + (capabilities.inputs.contains("file") ? " / 文件" : "")) : textOnly ? "本次按纯文本启动" : "当前服务未确认图片能力", path: visionPath, state: mediaEnabled ? (visionConfirmed ? "已启用" : "已配置") : textOnly || capabilities.known ? "未启用" : "待确认", confirmed: visionConfirmed || textOnly))
        let tokenizerPath = (files["tokenizer/tokenizer.json"]?["path"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? primary?.folder
        if tokenizerPath != nil {
            entries.append(.init(id: "tokenizer", title: "Tokenizer", name: ["llama", "prism"].contains(spec.engineID) ? "使用主模型内置 tokenizer" : "由主模型提供，草稿共用", path: tokenizerPath, state: "主模型提供", confirmed: true))
        }
        return entries.isEmpty ? nil : .init(processStart: spec.processStart, startedAt: spec.startedAt, entries: entries)
    }
}

@MainActor extension AppStore {
    func serviceComponents(_ spec: ServiceSpec) -> ServiceComponentSnapshot? {
        if let captured = spec.componentSnapshot, captured.processStart == spec.processStart, captured.startedAt == spec.startedAt { return captured }
        return ServiceComponentEvidence.collect(spec: spec, models: models, log: services.log(spec.id), capabilities: serviceCapabilities(spec), status: services.status(spec))
    }
    func captureServiceComponents() {
        guard inventory != nil, !scanning else { return }
        for spec in services.records where spec.pid != nil && services.status(spec) == .running && (spec.componentSnapshot == nil || spec.componentSnapshot?.entries.contains(where: { $0.id == "draft" && !$0.confirmed }) == true) {
            if let value = ServiceComponentEvidence.collect(spec: spec, models: models, log: services.log(spec.id), capabilities: serviceCapabilities(spec), status: services.status(spec)), value.entries.contains(where: { $0.id == "draft" && $0.confirmed && $0.state == "已启用" }) || (spec.launchArguments != nil && value.entries.contains(where: \.confirmed)) {
                services.captureComponents(value, spec: spec)
            }
        }
    }
}

@MainActor struct ServiceComponentsView: View {
    @ObservedObject var store: AppStore
    var spec: ServiceSpec
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) { Text(verbatim: L10n.text(spec.pid == nil ? "上次启动的配套组件" : "本次配套组件")).font(.system(size: TypeScale.body, weight: .semibold)); InfoTip(text: "按本次启动命令和运行日志显示；修改模型关联只影响后续启动。") }
            if let snapshot = store.serviceComponents(spec) {
                ForEach(snapshot.entries) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.id == "draft" ? "bolt.fill" : item.id == "vision" ? "photo" : "textformat").foregroundStyle(Theme.linkColor).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) { Text(verbatim: L10n.text(item.title)).font(.system(size: TypeScale.body, weight: .semibold)); Text(verbatim: L10n.text(item.name)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).textSelection(.enabled).lineLimit(2) }
                        Spacer(minLength: 8)
                        Text(verbatim: L10n.text(item.state)).font(.system(size: TypeScale.callout, weight: .medium)).foregroundStyle(item.state == "已启用" ? Theme.successText : Theme.muted)
                        if let path = item.path { Button { store.reveal(path) } label: { Image(systemName: "folder") }.buttonStyle(.bordered).help(L10n.text("查看 " + item.title + "：" + path)).accessibilityLabel(L10n.text("查看" + item.title + "文件")) }
                    }
                }
            } else { Text(verbatim: L10n.text("本次启动尚未提供组件信息，正在等待引擎日志。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
        }.padding(16).background(Theme.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("service-components")
    }
}

@MainActor struct ServiceComponentsSummary: View {
    @ObservedObject var store: AppStore
    var spec: ServiceSpec
    var body: some View {
        if let draft = store.serviceComponents(spec)?.entries.first(where: { $0.id == "draft" && $0.state != "未启用" }) {
            Label(L10n.text((spec.pid == nil ? "上次草稿：" : "草稿：") + draft.name + " · " + draft.state), systemImage: "bolt.fill").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(2)
        }
    }
}
