import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor struct InstancePerformanceEntry: View {
    @ObservedObject var store: AppStore
    @ObservedObject var performance: PerformanceController
    var serviceID: String? = nil
    var port: Int
    var instanceKey: String { serviceID ?? "external:\(port)" }
    var latest: BenchmarkResult? { performance.records.first { $0.target.instanceKey == instanceKey } }
    var busy: Bool { performance.running && performance.activeTarget?.instanceKey == instanceKey }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("实例性能"), systemImage: "speedometer").font(.system(size: TypeScale.body, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L10n.text(busy ? "查看测试进度" : "性能测试")) { store.openInstanceBenchmark(serviceID: serviceID, port: port) }
                    .buttonStyle(.bordered).accessibilityIdentifier("benchmark-service-" + instanceKey)
            }
            if let latest {
                Text(verbatim: "\(L10n.text(latest.speedTitle)) \(latest.speedLabel) · \(L10n.text("总耗时")) \(secondsLabel(latest.elapsed)) · \(latest.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).monospacedDigit()
            } else {
                Text(verbatim: L10n.text("单独测试此实例，结果按实例与模型保存。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
    }
}

@MainActor final class InstanceBenchmarkViewState: ObservableObject {
    @Published var modelID = ""
    @Published var input = InstanceBenchmarkInput()
}

@MainActor struct InstanceBenchmarkView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var performance: PerformanceController
    var draft: InstanceBenchmarkDraft
    @StateObject private var ui = InstanceBenchmarkViewState()
        var key: String { draft.serviceID ?? "external:\(draft.port)" }
    var targets: [BenchmarkTarget] { store.instanceBenchmarkTargets(serviceID: draft.serviceID, port: draft.port) }
    var target: BenchmarkTarget? { targets.first { $0.id == ui.modelID } ?? targets.first }
    var operation: BenchmarkOperation { target?.operation ?? .chat }
    var records: [BenchmarkResult] { performance.records.filter { $0.target.instanceKey == key && (target == nil || $0.target.apiModel == target?.apiModel) } }
    var testingHere: Bool { performance.running && performance.activeTarget?.instanceKey == key }
    var ready: Bool {
        if let id = draft.serviceID {
            guard let spec = store.services.records.first(where: { $0.id == id && $0.port == draft.port }) else { return false }
            return spec.pid != nil && store.services.status(spec) == .running
        }
        return store.services.external.contains { $0.port == draft.port && $0.ready }
    }
    var validInput: Bool {
        if operation == .transcription { return ui.input.audioURL != nil }
        if operation == .speech {
            return !ui.input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ui.input.text.count <= 2000 &&
                (ui.input.audioURL == nil ? target?.apiModel.lowercased().contains("base") != true : !ui.input.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return true
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.text("实例性能测试"), systemImage: "speedometer").font(.system(size: TypeScale.section, weight: .bold))
                    Text(verbatim: "\(target?.engineName ?? "ModelDock") · 127.0.0.1:\(draft.port)").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(L10n.text("完成")) { store.instanceBenchmark = nil }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let target {
                        if targets.count > 1 {
                            Picker(L10n.text("使用模型"), selection: Binding(get: { self.target?.id ?? "" }, set: { ui.modelID = $0 })) {
                                ForEach(targets) { Text(verbatim: $0.apiModel).tag($0.id) }
                            }.disabled(performance.running)
                        } else {
                            Text(verbatim: target.modelName).font(.system(size: TypeScale.body, weight: .semibold)).textSelection(.enabled)
                            Text(verbatim: L10n.text("API 模型 ID") + " · " + target.apiModel)
                                .font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted)
                                .lineLimit(2).truncationMode(.middle).help(target.apiModel).textSelection(.enabled)
                        }
                        Text(verbatim: L10n.text(operation.title)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        parameters.disabled(performance.running)
                        Text(verbatim: L10n.text("测试会占用此实例的推理资源。首次加载、缓存和其他请求会影响结果；请使用相同参数比较。"))
                            .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        if operation != .chat { Text(verbatim: L10n.text("取消将停止等待并放弃记录；服务可能仍会完成已提交的任务。")) .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted) }
                        if !ready { Text(verbatim: L10n.text("请先启动此实例并等待服务就绪；已有测试记录仍可查看。")) .foregroundStyle(Theme.warningText) }
                        HStack {
                            if testingHere {
                                ProgressView().controlSize(.small)
                                Text(verbatim: L10n.text(performance.phase)).font(.system(size: TypeScale.body))
                                Spacer()
                                Button(L10n.text("取消测量")) { performance.cancel() }.buttonStyle(.bordered)
                            } else {
                                Button {
                                    performance.measure(target, chip: store.inventory?.chip ?? "Apple Silicon", input: ui.input)
                                } label: { Label(L10n.text("开始测试"), systemImage: "play.fill") }
                                    .buttonStyle(AccentButton()).disabled(!ready || !validInput || performance.running || store.maintaining)
                                    .accessibilityIdentifier("instance-benchmark-start")
                                if performance.running { Text(verbatim: L10n.text("另一个实例正在测试，请等待完成。")) .foregroundStyle(Theme.muted) }
                            }
                        }
                        if performance.selection == target.id, let message = performance.message {
                            Text(verbatim: L10n.text(message)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled)
                        }
                    } else { Text(verbatim: L10n.text("此实例已移除，保留的测试记录仍可查看。")) .foregroundStyle(Theme.muted) }
                    if let result = records.first {
                        Divider()
                        Text(verbatim: L10n.text("最近实测")).font(.system(size: TypeScale.body, weight: .semibold))
                        BenchmarkCards(result: result, columns: 2)
                        Text(verbatim: L10n.text(result.rateSource)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        if (result.target.operation ?? .chat) == .chat {
                            Text(verbatim: L10n.text("输入 \(result.promptTokens.map(String.init) ?? "—") / 输出 \(result.outputTokens.map(String.init) ?? "—") tokens"))
                                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                        }
                        Text(verbatim: "\(result.target.engineName) \(result.target.engineVersion) · \(result.chip) · \(result.sampleDescription ?? "\(result.requestedTokens) tokens")")
                            .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                        Text(verbatim: L10n.text("本实例测试记录")).font(.system(size: TypeScale.body, weight: .semibold))
                        ForEach(Array(records.prefix(10))) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: record.date.formatted(date: .abbreviated, time: .shortened))
                                    Text(verbatim: "\(record.target.engineVersion) · \(record.sampleDescription ?? "\(record.requestedTokens) tokens")")
                                        .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text(verbatim: record.speedLabel).monospacedDigit()
                                Text(verbatim: secondsLabel(record.elapsed)).monospacedDigit().foregroundStyle(Theme.muted).frame(width: 80, alignment: .trailing)
                            }.font(.system(size: TypeScale.callout)).padding(12).background(Theme.line.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else { Text(verbatim: L10n.text("此实例暂无测试记录。")) .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: 720, height: 640).background(Theme.background)
    }
    @ViewBuilder var parameters: some View {
        switch operation {
        case .chat:
            Picker(L10n.text("输出上限"), selection: $performance.outputLimit) {
                ForEach([64, 128, 256], id: \.self) { Text(verbatim: "\($0) tokens").tag($0) }
            }
            Text(verbatim: L10n.text("文本测试测量首个输出、生成速度和总耗时；未报告 token 数时不估算速度。")) .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        case .transcription:
            audioPicker
            Text(verbatim: L10n.text("选择清晰的短音频。样本仅发往此本地实例，历史记录不保存音频或识别文字。")) .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        case .speech:
            TextField(L10n.text("测试文本（英语）"), text: $ui.input.text, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            audioPicker
            TextField(L10n.text("参考音频对应原文"), text: $ui.input.referenceText).textFieldStyle(.roundedBorder)
            Text(verbatim: L10n.text("Base 模型需要参考音频与原文；其他语音模型可直接测试。生成音频不播放、不保存。")) .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        case .image:
            Picker(L10n.text("图片尺寸"), selection: $ui.input.imageSize) {
                Text(verbatim: "512 × 512").tag("512x512"); Text(verbatim: "1024 × 1024").tag("1024x1024")
            }
            Text(verbatim: L10n.text("使用固定提示词和 seed 42 生成一张图片；首次测试可能包含加载耗时。")) .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        case .embedding:
            Text(verbatim: L10n.text("使用固定短文本，测量向量接口耗时并核对返回维度。")) .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        }
        DisclosureGroup(L10n.text("访问密钥")) {
            SecureField(L10n.text("本地服务访问密钥（可选，仅本次打开有效）"), text: $performance.apiKey).textFieldStyle(.roundedBorder)
        }
    }
    var audioPicker: some View {
        HStack {
            Text(verbatim: ui.input.audioURL?.lastPathComponent ?? L10n.text("未选择音频")) .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.muted)
            Spacer()
            Button(L10n.text("选择音频…")) {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .aiff]; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { ui.input.audioURL = panel.url }
            }.buttonStyle(.bordered)
            if ui.input.audioURL != nil { Button(L10n.text("移除")) { ui.input.audioURL = nil }.buttonStyle(.bordered) }
        }
    }
}
