import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 服务试聊：直接调用服务自己的 OpenAI 兼容 /chat/completions 流式接口，用于确认模型可用并观察速度。
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    struct Message: Identifiable {
        let id = UUID()
        var role: String
        var text: String
        var reasoning = ""
        var images: [String] = []
        var stats: String?
        var failed = false
    }
    let id = UUID()
    let targets: [ConnectionTarget]
    @Published var targetID: String
    @Published var messages: [Message] = []
    @Published var input = ""
    @Published var system = ""
    @Published var temperature = 0.7
    @Published var maxTokens = 1024
    @Published var attachments: [String] = []
    @Published var streaming = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    /// 完整结束的回复交给调用方写入实测历史；键为 ConnectionTarget.id。
    var benchmarkTargets: [String: BenchmarkTarget] = [:]
    var chip = "Apple Silicon"
    var record: ((BenchmarkResult) -> Void)?
    /// 对比模式：同一条消息同时发给第二个服务。
    @Published var compare: ChatSession?
    /// 可用于对比的其他本机服务。
    var compareCandidates: [ConnectionTarget] = []
    var makeSession: (([ConnectionTarget]) -> ChatSession)?

    init(targets: [ConnectionTarget]) { self.targets = targets; targetID = targets.first?.id ?? "" }
    var target: ConnectionTarget? { targets.first { $0.id == targetID } }
    var acceptsImages: Bool { target?.capabilities?.inputs.contains("image") == true }
    var canSend: Bool { !busy && target != nil && !(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) }

    func clear() { stop(); messages = []; error = nil; compare?.clear() }
    func stop() { task?.cancel(); task = nil; compare?.stop() }
    var busy: Bool { streaming || compare?.streaming == true }

    func startCompare(_ target: ConnectionTarget) {
        guard let session = makeSession?([target]) else { return }
        compare = session
    }

    func attach() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url), data.count <= 10_000_000 else { error = "图片需小于 10 MB"; continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            attachments.append("data:\(type);base64,\(data.base64EncodedString())")
        }
    }

    func send() {
        guard canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines), images = attachments
        input = ""; attachments = []
        if let compare {
            compare.system = system; compare.temperature = temperature; compare.maxTokens = maxTokens
            compare.send(text: text, images: compare.acceptsImages ? images : [])
        }
        send(text: text, images: images)
    }

    func send(text: String, images: [String]) {
        guard !streaming, let target else { return }
        messages.append(.init(role: "user", text: text, images: images))
        error = nil
        let history = messages.filter { !$0.failed }
        messages.append(.init(role: "assistant", text: ""))
        let index = messages.count - 1
        streaming = true
        let body = requestBody(history, model: target.model)
        let benchmark = benchmarkTargets[target.id]
        task = Task { [weak self] in
            await self?.stream(target: target, body: body, into: index, benchmark: benchmark)
            self?.streaming = false; self?.task = nil
        }
    }

    private func requestBody(_ history: [Message], model: String) -> [String: Any] {
        var payload: [[String: Any]] = []
        let prompt = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { payload.append(["role": "system", "content": prompt]) }
        for message in history {
            if message.images.isEmpty { payload.append(["role": message.role, "content": message.text]); continue }
            let parts: [[String: Any]] = (message.text.isEmpty ? [] : [["type": "text", "text": message.text]]) + message.images.map { ["type": "image_url", "image_url": ["url": $0]] }
            payload.append(["role": message.role, "content": parts])
        }
        return ["model": model, "messages": payload, "stream": true, "stream_options": ["include_usage": true], "temperature": temperature, "max_tokens": maxTokens]
    }

    private func stream(target: ConnectionTarget, body: [String: Any], into index: Int, benchmark: BenchmarkTarget?) async {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 }
        var metrics = StreamMetrics(), chunks = 0
        do {
            guard let url = URL(string: target.endpoint + "/chat/completions") else { throw LaunchError.message("服务地址无效") }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = target.apiKey, !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                var detail = ""
                for try await line in bytes.lines { detail += line; if detail.utf8.count > 4000 { break } }
                throw LaunchError.message(Self.errorText(detail) ?? "服务返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.hasPrefix("data:") {
                    let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let message = Self.errorText(value) { throw LaunchError.message(message) }
                        for choice in object["choices"] as? [[String: Any]] ?? [] {
                            let delta = choice["delta"] as? [String: Any] ?? [:]
                            let content = (delta["content"] as? String ?? "") + (choice["text"] as? String ?? "")
                            let reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
                            if !content.isEmpty || !reasoning.isEmpty { chunks += 1 }
                            messages[index].text += content; messages[index].reasoning += reasoning
                        }
                    }
                }
                // 指标解析失败不影响对话内容。
                try? metrics.line(line, elapsed: elapsed())
                if metrics.done { break }
            }
            try? metrics.flush(elapsed: elapsed())
            let duration = elapsed()
            messages[index].stats = Self.stats(metrics, chunks: chunks, duration: duration)
            if messages[index].text.isEmpty && messages[index].reasoning.isEmpty { messages[index].stats = L10n.text("模型没有返回内容") }
            else if let benchmark, let result = Self.result(metrics, target: benchmark, chip: chip, requested: body["max_tokens"] as? Int ?? 0, duration: duration) {
                record?(result)
            }
        } catch is CancellationError {
            messages[index].stats = L10n.text("已停止") + (Self.stats(metrics, chunks: chunks, duration: elapsed()).map { " · " + $0 } ?? "")
        } catch let failure as URLError where failure.code == .cancelled {
            messages[index].stats = L10n.text("已停止")
        } catch {
            messages[index].failed = true; messages[index].stats = nil
            if messages[index].text.isEmpty { messages.remove(at: index) }
            self.error = error.localizedDescription
        }
    }

    /// 完整结束且服务报告了 token 用量或生成计时的回复才记入实测历史，不用估算值。
    static func result(_ metrics: StreamMetrics, target: BenchmarkTarget, chip: String, requested: Int, duration: Double) -> BenchmarkResult? {
        guard metrics.done || metrics.finishReason, metrics.firstOutput != nil, metrics.outputTokens != nil || metrics.generationRate != nil else { return nil }
        return BenchmarkResult(target: target, chip: chip, requestedTokens: requested, promptTokens: metrics.promptTokens, outputTokens: metrics.outputTokens, cachedTokens: metrics.cachedTokens,
            firstOutput: metrics.firstOutput, elapsed: duration, generationRate: metrics.generationRate, promptRate: metrics.promptRate,
            endToEndRate: metrics.outputTokens.flatMap { $0 > 0 && duration > 0 ? Double($0) / duration : nil },
            rateSource: metrics.generationRate == nil ? "来自试聊；引擎未返回生成计时，端到端吞吐包含等待与输入处理" : "来自试聊；生成速度采用引擎返回的计时")
    }

    /// 从 OpenAI 兼容的错误响应中取出说明文字。
    static func errorText(_ text: String) -> String? {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["error"] else { return nil }
        if let message = (value as? [String: Any])?["message"] as? String { return message }
        return value as? String ?? "模型服务返回错误"
    }

    static func stats(_ metrics: StreamMetrics, chunks: Int, duration: Double) -> String? {
        guard let first = metrics.firstOutput else { return nil }
        let tokens = metrics.outputTokens ?? chunks
        let rate = metrics.generationRate ?? (duration > first && tokens > 1 ? Double(tokens - 1) / (duration - first) : nil)
        var parts = [L10n.text("首字 \(String(format: "%.2f", first)) 秒")]
        if let rate { parts.append(String(format: "%.1f tok/s", rate)) }
        parts.append((metrics.outputTokens == nil ? "≈" : "") + "\(tokens) tokens")
        return parts.joined(separator: " · ")
    }
}

@MainActor extension AppStore {
    func openChat(port: Int) {
        let targets = directConnectionTargets.filter { !$0.isRemote && $0.port == port }
        guard !targets.isEmpty else { message = "服务接口尚未就绪，请等待模型加载完成。"; return }
        let session = makeChatSession(targets)
        session.compareCandidates = directConnectionTargets.filter { !$0.isRemote }
        chat = session
    }

    /// 创建试聊会话：完整回复的速度写入实测历史。
    func makeChatSession(_ targets: [ConnectionTarget]) -> ChatSession {
        let session = ChatSession(targets: targets)
        let benchmarks = Dictionary(benchmarkTargets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        session.benchmarkTargets = benchmarks.filter { key, _ in targets.contains { $0.id == key } }
        session.chip = inventory?.chip ?? "Apple Silicon"
        session.record = { [weak self, weak session] result in
            do { try self?.performance.add(result) } catch { session?.error = L10n.text("实测记录未保存：") + error.localizedDescription }
        }
        session.makeSession = { [weak self] targets in self?.makeChatSession(targets) ?? ChatSession(targets: targets) }
        return session
    }
}

@MainActor struct ChatPlaygroundView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ChatSession
    var others: [ConnectionTarget] { session.compareCandidates.filter { $0.id != session.targetID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(verbatim: L10n.text("试聊")).font(.system(size: TypeScale.section, weight: .bold))
                if session.targets.count > 1 {
                    Picker(L10n.text("模型"), selection: $session.targetID) { ForEach(session.targets) { Text(verbatim: $0.model).tag($0.id) } }.labelsHidden().fixedSize().disabled(session.busy)
                } else if session.compare == nil, let target = session.target { Text(verbatim: target.model).font(.system(size: TypeScale.body, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle) }
                Spacer()
                if session.compare == nil && !others.isEmpty {
                    Menu {
                        ForEach(others) { target in Button(target.engineName + " · " + target.model) { session.startCompare(target) } }
                    } label: { Label(L10n.text("对比…"), systemImage: "rectangle.split.2x1") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(session.busy).help(L10n.text("同一条消息同时发给另一个服务，并排比较回答和速度"))
                }
                Button(L10n.text("清空")) { session.clear() }.buttonStyle(SecondaryButton()).disabled(session.messages.isEmpty || session.busy)
                Button(L10n.text("完成")) { session.stop(); store.chat = nil }.buttonStyle(SecondaryButton()).keyboardShortcut(.cancelAction)
            }
            DisclosureGroup(L10n.text("对话参数")) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow(alignment: .top) {
                        Text(verbatim: L10n.text("系统提示词"))
                        TextField(L10n.text("可选，例如“用中文简洁回答”"), text: $session.system, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(verbatim: L10n.text("温度"))
                        HStack { Slider(value: $session.temperature, in: 0...2, step: 0.1).frame(width: 220); Text(verbatim: String(format: "%.1f", session.temperature)).monospacedDigit().frame(width: 32, alignment: .leading) }
                    }
                    GridRow {
                        Text(verbatim: L10n.text("最大输出"))
                        Picker(L10n.text("最大输出"), selection: $session.maxTokens) { ForEach([256, 512, 1024, 2048, 4096, 8192], id: \.self) { Text(verbatim: "\($0) tokens").tag($0) } }.labelsHidden().fixedSize()
                    }
                }.font(.system(size: TypeScale.body)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.system(size: TypeScale.body)).disabled(session.busy)
            Divider()
            if let compare = session.compare {
                // 对比模式：两栏共用输入和参数，各自显示回复与速度。
                HStack(alignment: .top, spacing: 16) {
                    ChatColumn(store: store, session: session, title: session.target.map { $0.engineName + " · " + $0.model }, onClose: nil)
                    Divider()
                    ChatColumn(store: store, session: compare, title: compare.target.map { $0.engineName + " · " + $0.model }, onClose: { session.compare?.stop(); session.compare = nil })
                }.frame(maxHeight: .infinity)
            } else {
                ChatColumn(store: store, session: session, title: nil, onClose: nil).frame(maxHeight: .infinity)
            }
            if !session.attachments.isEmpty {
                HStack(spacing: 8) {
                    Label(L10n.text("已附加 \(session.attachments.count) 张图片"), systemImage: "photo").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    Button(L10n.text("移除")) { session.attachments = [] }.buttonStyle(PlainAction())
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                if session.acceptsImages {
                    Button { session.attach() } label: { Image(systemName: "photo.badge.plus") }.buttonStyle(SecondaryButton()).help(L10n.text("附加图片")).accessibilityLabel(L10n.text("附加图片")).disabled(session.busy)
                }
                TextField(L10n.text("输入消息，回车发送"), text: $session.input, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).font(.system(size: TypeScale.body))
                    // 与两侧按钮同高（ButtonMetrics.height），多行时向上增高。
                    .padding(.horizontal, 10).padding(.vertical, 7).frame(minHeight: ButtonMetrics.height)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: ButtonMetrics.radius))
                    .overlay { RoundedRectangle(cornerRadius: ButtonMetrics.radius).stroke(Theme.line, lineWidth: 1) }
                    .onSubmit { session.send() }
                if session.busy { Button { session.stop() } label: { Label(L10n.text("停止"), systemImage: "stop.fill") }.buttonStyle(AccentButton(destructive: true)) }
                else { Button { session.send() } label: { Label(L10n.text("发送"), systemImage: "paperplane.fill") }.buttonStyle(AccentButton()).disabled(!session.canSend) }
            }
        }.padding(24).frame(width: session.compare == nil ? 760 : 1120, height: 640).background(Theme.background)
        .onDisappear { session.stop() }
    }
}

/// 一个会话的消息列表；对比模式下带标题和关闭按钮。
@MainActor private struct ChatColumn: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ChatSession
    var title: String?
    var onClose: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 8) {
                    Text(verbatim: title).font(.system(size: TypeScale.callout, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let onClose { Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(PlainAction()).help(L10n.text("退出对比")).accessibilityLabel(L10n.text("退出对比")).disabled(session.streaming) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.messages.isEmpty {
                            Text(verbatim: L10n.text("发送一条消息，确认模型能正常回答，并查看首字延迟和生成速度。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).padding(.top, 30).frame(maxWidth: .infinity)
                        }
                        ForEach(session.messages) { ChatBubble(store: store, message: $0, streaming: session.streaming && $0.id == session.messages.last?.id).id($0.id) }
                    }.padding(.vertical, 4).padding(.trailing, 6)
                }
                .onChange(of: session.messages.last?.text) { _, _ in if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: session.messages.count) { _, _ in if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if let error = session.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor private struct ChatBubble: View {
    @ObservedObject var store: AppStore
    var message: ChatSession.Message
    var streaming: Bool
    var user: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .top) {
            if user { Spacer(minLength: 80) }
            VStack(alignment: user ? .trailing : .leading, spacing: 6) {
                if !message.reasoning.isEmpty {
                    DisclosureGroup(L10n.text(streaming && message.text.isEmpty ? "思考中…" : "思考过程")) {
                        Text(verbatim: message.reasoning).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: TypeScale.callout))
                }
                if !message.images.isEmpty { Label(L10n.text("\(message.images.count) 张图片"), systemImage: "photo").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                if !message.text.isEmpty || (streaming && message.reasoning.isEmpty) {
                    Group {
                        if message.text.isEmpty { ProgressView().controlSize(.small) }
                        else { Text(Self.markdown(message.text)).textSelection(.enabled) }
                    }
                    .font(.system(size: TypeScale.body)).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(user ? Theme.accent.opacity(0.14) : Theme.line.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                }
                if !user, let stats = message.stats {
                    HStack(spacing: 6) {
                        Text(verbatim: stats).font(.system(size: TypeScale.callout).monospacedDigit()).foregroundStyle(Theme.muted)
                        if !message.text.isEmpty { CopyIconButton(help: "复制回答") { store.copy(message.text) } }
                    }
                }
            }
            if !user { Spacer(minLength: 80) }
        }
    }
    /// 行内 Markdown（粗体、代码、链接），保留原有换行。
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
