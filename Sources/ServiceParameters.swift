import Foundation
import SwiftUI

/// Launch parameters of one managed service: the structured fields plus native engine flags.
struct ServiceParameters: Equatable {
    var port: Int
    var context: Int
    var inputMode: InputMode
    var projectorPath: String?
    var maximumLoadedModels: Int
    var extraArguments: [String]
}
extension ServiceParameters {
    init(_ spec: ServiceSpec) {
        self.init(port: spec.port, context: spec.context, inputMode: spec.inputMode ?? .automatic, projectorPath: spec.projectorPath,
                  maximumLoadedModels: spec.maximumLoadedModels ?? 3, extraArguments: spec.extraArguments ?? [])
    }
}

enum ServiceExtraArguments {
    static let limit = 64
    /// Ollama and Strata only accept their managed options; LM Studio is launched by its own app.
    static func supported(_ kind: EngineKind) -> Bool { [.llama, .prism, .mlx, .splash].contains(kind) }
    /// Flags owned by the structured fields, the listen address or credentials. Repeating them would make the launch ambiguous.
    static func reserved(_ kind: EngineKind) -> Set<String> {
        var result: Set<String> = ["--host", "--port", "--help", "-h", "--version", "--api-key", "--api-key-file", "--hf-token"]
        switch kind {
        case .llama, .prism: result.formUnion(["-m", "--model", "-mu", "--model-url", "-hf", "-hfr", "--hf-repo", "-c", "--ctx-size", "-mm", "--mmproj", "--mmproj-url", "--no-mmproj"])
        case .mlx: result.formUnion(["--model", "--max-kv-size", "--draft-model", "--draft-kind"])
        case .splash: result.formUnion(["--model", "--max-context", "--revision", "--draft-model", "--language-only", "--disable-ane"])
        default: break
        }
        return result
    }
    static func parse(_ text: String, engine: Engine) throws -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let words = try ServiceCommand.words(text)
        try validate(words, engine: engine)
        return words
    }
    static func validate(_ words: [String], engine: Engine) throws {
        guard !words.isEmpty else { return }
        guard supported(engine.kind) else { throw LaunchError.message("\(engine.name) 不支持附加启动参数") }
        guard words.count <= limit else { throw LaunchError.message("附加启动参数过多，最多 \(limit) 项") }
        let blocked = reserved(engine.kind)
        for word in words {
            guard word != "serve" else { throw LaunchError.message("附加参数不需要填写 serve 子命令") }
            guard word.hasPrefix("-") else { continue }
            let name = word.components(separatedBy: "=")[0]
            guard !blocked.contains(name) else { throw LaunchError.message("\(name) 由服务参数管理，请在上方字段中修改") }
        }
    }
    static func display(_ words: [String]) -> String {
        words.map { word in word.isEmpty || word.contains(where: { $0.isWhitespace || "'\"\\".contains($0) }) ? ServiceCommand.quote(word) : word }.joined(separator: " ")
    }
}

@MainActor
final class ServiceParameterDraft: ObservableObject {
    @Published var port: String
    @Published var context: Int
    @Published var inputMode: InputMode
    @Published var projectorPath: String
    @Published var maximumLoadedModels: Int
    @Published var extra: String
    @Published var error: String?
    @Published var notice: String?
    init(_ spec: ServiceSpec) {
        port = String(spec.port); context = spec.context; inputMode = spec.inputMode ?? .automatic; projectorPath = spec.projectorPath ?? ""
        maximumLoadedModels = spec.maximumLoadedModels ?? 3; extra = ServiceExtraArguments.display(spec.extraArguments ?? [])
    }
    func reset(_ spec: ServiceSpec) {
        port = String(spec.port); context = spec.context; inputMode = spec.inputMode ?? .automatic; projectorPath = spec.projectorPath ?? ""
        maximumLoadedModels = spec.maximumLoadedModels ?? 3; extra = ServiceExtraArguments.display(spec.extraArguments ?? []); error = nil
    }
    func value(engine: Engine) throws -> ServiceParameters {
        guard let port = Int(port.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else { throw LaunchError.message("端口需要在 1024–65535 之间") }
        guard (1024...262144).contains(context), (1...16).contains(maximumLoadedModels) else { throw LaunchError.message("上下文或常驻模型数量无效") }
        let projector = projectorPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(port: port, context: context, inputMode: inputMode, projectorPath: projector.isEmpty ? nil : ServiceCommand.expanded(projector),
                     maximumLoadedModels: maximumLoadedModels, extraArguments: try ServiceExtraArguments.parse(extra, engine: engine))
    }
}

@MainActor
extension AppStore {
    /// Saves edited parameters. A running service (or `launch`) is stopped, restarted with them, and rolled back on failure.
    func saveServiceParameters(_ draft: ServiceParameterDraft, spec: ServiceSpec, launch: Bool) {
        guard relaunchingServiceID == nil else { return }
        guard let engine = engines.first(where: { $0.id == spec.engineID }) else { draft.error = "未找到此服务的引擎，请重新扫描"; return }
        guard !maintaining, installation.activeEngineID != engine.id, !(engine.kind == .strata && strata.busy), !appUpdates.applying else { draft.error = "请等待当前引擎操作完成"; return }
        draft.error = nil; draft.notice = nil
        let current = services.records.first { $0.id == spec.id } ?? spec
        let model = models.first { $0.id == current.modelID || $0.path == current.modelPath }
        let value: ServiceParameters
        do {
            value = try draft.value(engine: engine)
            if current.pid == nil && !launch { try services.updateParameters(current.id, value); draft.notice = "已保存，下次启动时生效。"; return }
            guard model != nil || engine.kind == .ollama else { throw LaunchError.message("未找到服务使用的模型文件。") }
            // Build the new plan before stopping anything; invalid settings fail without downtime.
            _ = try LaunchBuilder.plan(engine: engine, model: model, port: value.port, context: value.context, maximumLoadedModels: value.maximumLoadedModels, inputMode: value.inputMode, projectorPath: value.projectorPath)
            if value.port != current.port, let conflict = services.portConflict(value.port, excluding: current.id) { throw LaunchError.message(conflict + "，请使用空闲端口") }
        } catch { draft.error = error.localizedDescription; return }
        relaunchingServiceID = current.id
        draft.notice = current.pid != nil ? "正在停止服务并使用新参数重新启动…" : "正在使用新参数启动服务…"
        Task {
            defer { relaunchingServiceID = nil }
            do {
                let started = try await relaunchService(current, engine: engine, model: model, value: value)
                draft.notice = services.status(started) == .running ? "服务已使用新参数启动。" : "新参数已生效，服务仍在加载。"
            } catch { draft.notice = nil; draft.error = error.localizedDescription }
        }
    }

    private func relaunchService(_ saved: ServiceSpec, engine: Engine, model: LocalModel?, value: ServiceParameters) async throws -> ServiceSpec {
        let previous = ServiceParameters(saved), wasRunning = saved.pid != nil
        if wasRunning {
            await services.refresh()
            guard let current = services.records.first(where: { $0.id == saved.id }), current.pid == saved.pid, current.processStart == saved.processStart else {
                throw LaunchError.message("服务进程已经改变，未执行重启。")
            }
            try services.stop(current)
            try await services.waitForRelease(port: current.port)
        }
        try services.updateParameters(saved.id, value)
        var replacement: ServiceSpec?
        func launch(_ parameters: ServiceParameters) throws -> ServiceSpec {
            try services.start(engine: engine, model: model, port: parameters.port, context: parameters.context, maximumLoadedModels: parameters.maximumLoadedModels,
                               inputMode: parameters.inputMode, projectorPath: parameters.projectorPath, extraArguments: parameters.extraArguments)
        }
        // Large models can load for minutes; only an actual exit or port conflict counts as failure.
        func settle(_ spec: ServiceSpec) async throws -> ServiceSpec {
            for _ in 0..<120 {
                await services.refresh()
                if services.status(spec) != .starting { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if [.failed, .conflicted, .stopped].contains(services.status(spec)) { throw LaunchError.message(services.errors[spec.id] ?? "引擎启动失败，请查看运行日志。") }
            return services.records.first { $0.id == spec.id } ?? spec
        }
        do {
            let spec = try launch(value); replacement = spec
            return try await settle(spec)
        } catch {
            let failure = error.localizedDescription
            do {
                await services.refresh()
                if let replacement, let current = services.records.first(where: { $0.id == replacement.id }), current.pid != nil {
                    try services.stop(current); try await services.waitForRelease(port: current.port)
                }
                try services.updateParameters(saved.id, previous)
                if wasRunning { _ = try await settle(try launch(previous)) }
            } catch { throw LaunchError.message("新参数启动失败，自动恢复也未成功，请查看日志：\(failure)；\(error.localizedDescription)") }
            throw LaunchError.message(wasRunning ? "新参数启动失败，已按原参数重新启动：\(failure)" : "新参数启动失败，已恢复原参数：\(failure)")
        }
    }
}

/// Lists a managed service's launch parameters and lets the user edit them in place.
@MainActor
struct ServiceParametersView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    var spec: ServiceSpec
    @StateObject private var draft: ServiceParameterDraft
    init(store: AppStore, services: ServiceController, spec: ServiceSpec) {
        self.store = store; self.services = services; self.spec = spec
        _draft = StateObject(wrappedValue: ServiceParameterDraft(spec))
    }
    // One width for every value column so the fields share a left and right edge.
    static let fieldWidth: CGFloat = 220
    var engine: Engine? { store.engines.first { $0.id == spec.engineID } }
    var contexts: [Int] { Array(Set([2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, spec.context])).sorted() }
    var busy: Bool { store.relaunchingServiceID != nil }
    var body: some View {
        let status = services.status(spec)
        let kind = engine?.kind
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L10n.text("服务参数")).font(.system(size: TypeScale.body, weight: .semibold))
            if spec.commandText != nil {
                // Command-launched services keep the user's full command as the single source of truth.
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow { Text(verbatim: L10n.text("端口")).foregroundStyle(Theme.muted); Text(verbatim: String(spec.port)).font(.system(size: TypeScale.body, design: .monospaced)) }
                    GridRow { Text(verbatim: L10n.text("上下文")).foregroundStyle(Theme.muted); Text(verbatim: L10n.text(spec.context.formatted() + " tokens")) }
                    GridRow { Text(verbatim: L10n.text("输入模式")).foregroundStyle(Theme.muted); Text(verbatim: L10n.text((spec.inputMode ?? .automatic).title)) }
                }.font(.system(size: TypeScale.body))
                Text(verbatim: L10n.text("此服务由启动命令创建；停止服务后点“配置并启动”编辑命令。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    GridRow { Text(verbatim: L10n.text("端口")); TextField(L10n.text("1024–65535"), text: $draft.port).textFieldStyle(.roundedBorder).frame(width: Self.fieldWidth) }
                    GridRow { Text(verbatim: L10n.text("上下文")); Picker(L10n.text("上下文"), selection: $draft.context) { ForEach(contexts, id: \.self) { Text(verbatim: L10n.text($0.formatted() + " tokens")).tag($0) } }.labelsHidden().fixedSize().frame(width: Self.fieldWidth, alignment: .leading) }
                    if kind != .ollama {
                        GridRow { Text(verbatim: L10n.text("输入模式")); Picker(L10n.text("输入模式"), selection: $draft.inputMode) { ForEach(InputMode.allCases) { Text(verbatim: L10n.text($0.title)).tag($0) } }.labelsHidden().fixedSize().frame(width: Self.fieldWidth, alignment: .leading) }
                    }
                    if kind == .llama || kind == .prism {
                        GridRow { Text(verbatim: L10n.text("视觉投影")); TextField(L10n.text("自动匹配"), text: $draft.projectorPath).textFieldStyle(.roundedBorder) }
                    }
                    if kind == .ollama {
                        GridRow { Text(verbatim: L10n.text("常驻模型")); Stepper("最多常驻 \(draft.maximumLoadedModels) 个模型", value: $draft.maximumLoadedModels, in: 1...16) }
                    }
                }.font(.system(size: TypeScale.body))
                if let kind, ServiceExtraArguments.supported(kind) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: L10n.text("附加启动参数")).font(.system(size: TypeScale.body))
                        TextField(L10n.text(kind == .mlx ? "例如 --temp 0.7 --max-tokens 4096" : "例如 -ngl 99 --threads 8 --temp 0.7"), text: $draft.extra, axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(.system(size: TypeScale.callout, design: .monospaced)).lineLimit(1...4)
                        Text(verbatim: L10n.text("引擎原生参数，追加在默认参数之后；同名参数以这里为准。端口、模型、上下文等请使用上方字段。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    }
                } else if kind == .ollama || kind == .strata {
                    Text(verbatim: L10n.text("此引擎只接受上方的受管参数。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 12) {
                    if spec.pid != nil {
                        Button { store.saveServiceParameters(draft, spec: spec, launch: true) } label: { Label(L10n.text("保存并重启"), systemImage: "arrow.clockwise") }
                            .buttonStyle(AccentButton()).disabled(busy || status == .stopping).accessibilityIdentifier("service-parameters-restart")
                    } else {
                        Button { store.saveServiceParameters(draft, spec: spec, launch: true) } label: { Label(L10n.text("保存并启动"), systemImage: "play.fill") }
                            .buttonStyle(AccentButton()).disabled(busy).accessibilityIdentifier("service-parameters-start")
                        Button(L10n.text("保存")) { store.saveServiceParameters(draft, spec: spec, launch: false) }.buttonStyle(SecondaryButton()).disabled(busy)
                    }
                    Button(L10n.text("还原")) { draft.reset(spec); draft.notice = nil }.buttonStyle(SecondaryButton()).disabled(busy)
                    if store.relaunchingServiceID == spec.id { ProgressView().controlSize(.small) }
                }
                if let notice = draft.notice { Text(verbatim: L10n.text(notice)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                if let error = draft.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: ServiceParameters(spec)) { _, _ in if store.relaunchingServiceID != spec.id { draft.reset(spec) } }
    }
}
