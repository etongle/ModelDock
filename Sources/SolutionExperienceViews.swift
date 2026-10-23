import SwiftUI
import AppKit

@MainActor struct SolutionExperienceEntry: View {
    @ObservedObject var store: AppStore
    var record: SolutionDeployment
    private var ready: Bool { store.solutions.runtime(record, store: store).allReady && (record.solutionID == "image-generation" || store.gateway.solutionReady(record)) }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 22)).foregroundStyle(Theme.linkColor)
                .frame(width: 46, height: 46).background(Theme.selection, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L10n.text("体验方案")).font(.system(size: TypeScale.body, weight: .semibold))
                Text(verbatim: L10n.text(record.solutionID == "image-generation" ? "使用 GPT Image Playground 连续生成、标注和编辑图片，保留本地对话记录。" : ready ? "在独立对话窗口连续使用，保留本次会话的输入和结果。" : "启动并等待方案就绪后，即可打开对话窗口。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { store.openSolutionExperience(record) } label: { Label(L10n.text(record.solutionID == "image-generation" ? "打开 GPT Image Playground" : "打开对话"), systemImage: "arrow.up.forward.app") }
                .buttonStyle(AccentButton()).disabled(!ready).accessibilityIdentifier("open-solution-experience-" + record.id)
        }.padding(18).background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
    }
}

@MainActor struct SolutionExperienceView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: SolutionExperienceSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            history.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !session.ready(store) {
                Text(verbatim: L10n.text("方案服务或配置已变化，请关闭对话并检查方案。已有记录保留。"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText).fixedSize(horizontal: false, vertical: true)
            }
            if session.isImage, let generator = session.generator {
                SolutionImageComposer(store: store, session: session, generator: generator)
            } else if !session.isImage { voiceComposer }
            if let error = session.error ?? session.microphone.error {
                Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled)
            }
            Text(verbatim: L10n.text("关闭时停止收音；已提交的任务继续完成。会话保留至退出应用。"))
                .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
        }.padding(24).frame(width: 820, height: 650).background(Theme.background)
            .accessibilityIdentifier("solution-experience-" + session.id)
            .onDisappear { session.dismiss() }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: session.isImage ? "photo.badge.plus" : "waveform").font(.system(size: 22)).foregroundStyle(Theme.linkColor)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: L10n.text(session.isImage ? "本地生图" : "多语言实时翻译")).font(.system(size: TypeScale.section, weight: .semibold))
                Text(verbatim: L10n.format("实例 {0}", [String(session.id.prefix(8))]) + (session.isImage ? "" : " · " + TranslationLanguages.title(session.deployment.draft.sourceLanguage ?? "auto") + " → " + TranslationLanguages.title(session.deployment.draft.language)))
                    .font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button(L10n.text("新会话")) { session.newConversation() }.buttonStyle(SecondaryButton()).disabled(session.busy || !session.hasHistory)
                .accessibilityIdentifier("new-solution-conversation")
            Button(L10n.text("完成")) { session.dismiss(); store.solutionExperience = nil }.buttonStyle(SecondaryButton()).keyboardShortcut(.cancelAction)
        }
    }
    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.turns.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: session.isImage ? "photo.on.rectangle.angled" : "bubble.left.and.bubble.right").font(.system(size: 34)).foregroundStyle(Theme.linkColor)
                            Text(verbatim: L10n.text(session.isImage ? "描述你想生成的图片" : "开始一段翻译对话")).font(.system(size: TypeScale.section, weight: .semibold))
                            Text(verbatim: L10n.text(session.isImage ? "每次生成都会保留。选择结果下的“使用此图继续编辑”，再输入修改要求。" : "输入文字、开启麦克风或选择音频文件，原文与译文会按顺序保留。"))
                                .font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 520)
                        }.frame(maxWidth: .infinity).padding(.top, 55)
                    }
                    ForEach(session.turns) { turn in SolutionConversationBubble(store: store, session: session, turn: turn).id(turn.id) }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }.padding(.vertical, 6).padding(.trailing, 6)
            }
            .onChange(of: session.turns.count) { _, _ in proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            .onChange(of: session.turns.last?.pending) { _, _ in proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
        }
    }
    private var voiceComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if session.microphone.listening {
                    Button { session.microphone.stop() } label: { Label(L10n.text("停止收音"), systemImage: "stop.fill") }.buttonStyle(SecondaryButton())
                } else {
                    Button { session.listen(store: store) } label: { Label(L10n.text("麦克风"), systemImage: "mic") }.buttonStyle(SecondaryButton()).disabled(session.busy || !session.ready(store))
                }
                Button { session.chooseAudio(store: store) } label: { Label(L10n.text("音频文件"), systemImage: "paperclip") }.buttonStyle(SecondaryButton()).disabled(session.busy || !session.ready(store))
                if session.deployment.draft.speechOutput != false {
                    Toggle(L10n.text("朗读译文（朗读时暂停收音）"), isOn: Binding(get: { session.microphone.readAloud }, set: { session.microphone.readAloud = $0 })).toggleStyle(.switch).font(.system(size: TypeScale.callout)).controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            if session.microphone.listening { ProgressView(value: Double(min(1, session.microphone.level * 8))).tint(Theme.accent).accessibilityLabel(L10n.text("麦克风音量")) }
            if session.busy {
                HStack(spacing: 8) {
                    if session.sending || session.microphone.processing { ProgressView().controlSize(.small) }
                    Text(verbatim: L10n.text(session.sending ? session.phase : session.microphone.phase)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    if session.microphone.pending > 0 { Text(verbatim: L10n.format("等待翻译 {0} 段", [String(session.microphone.pending)])).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                SolutionMessageField(input: $session.input, placeholder: "输入要翻译的文字，回车发送", disabled: session.busy) { session.send(store: store) }
                if session.sending || session.microphone.processing {
                    Button { session.stop() } label: { Label(L10n.text("停止"), systemImage: "stop.fill") }.buttonStyle(AccentButton(destructive: true))
                } else {
                    Button { session.send(store: store) } label: { Label(L10n.text("发送"), systemImage: "paperplane.fill") }.buttonStyle(AccentButton())
                        .disabled(session.busy || !session.ready(store) || session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.input.count > 4096)
                }
            }
        }
    }
}

@MainActor private struct SolutionConversationBubble: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: SolutionExperienceSession
    var turn: SolutionConversationTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L10n.text(turn.source)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                    Text(verbatim: turn.input).font(.system(size: TypeScale.body)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let reference = turn.referenceName { Label(reference, systemImage: "photo").font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).lineLimit(1) }
                }.padding(12).background(Theme.selection, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 10) {
                if turn.pending {
                    HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text(session.isImage ? session.generator?.progress?.title ?? "准备生成" : session.phase)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
                    if let progress = session.generator?.progress, session.isImage, progress.stage == "denoising" {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).tint(Theme.accent)
                        Text(verbatim: "\(progress.completed) / \(progress.total) · " + String(format: "%.1f s", progress.elapsed)).font(.system(size: TypeScale.caption)).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                } else if let error = turn.error {
                    Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled)
                } else {
                    if !turn.response.isEmpty {
                        Text(verbatim: turn.response).font(.system(size: TypeScale.body)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button(L10n.text("复制")) { store.copy(turn.response) }.buttonStyle(PlainAction()).font(.system(size: TypeScale.caption))
                    }
                    if let url = turn.image, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityLabel(L10n.text("生成的图片"))
                        HStack(spacing: 14) {
                            Button(L10n.text("保存 PNG…")) { session.saveImage(turn) }.buttonStyle(PlainAction())
                            Button(L10n.text("使用此图继续编辑")) { session.editImage(turn, store: store) }.buttonStyle(PlainAction()).disabled(session.busy || !session.ready(store) || session.generator?.supportsImageToImage != true)
                        }.font(.system(size: TypeScale.callout))
                    }
                    if let audio = turn.audio { Button(L10n.text("播放生成的配音")) { NSWorkspace.shared.open(audio) }.buttonStyle(PlainAction()) }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }.padding(.trailing, 44)
        }.accessibilityIdentifier("solution-conversation-turn-" + turn.id.uuidString)
    }
}

@MainActor private struct SolutionImageComposer: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: SolutionExperienceSession
    @ObservedObject var generator: ImageGenerationSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker(L10n.text("生成方式"), selection: $generator.mode) { ForEach(ImageGenerationMode.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) } }.pickerStyle(.segmented).fixedSize().disabled(session.busy).accessibilityIdentifier("conversation-image-mode")
                if generator.mode == .image {
                    Button(L10n.text(generator.reference == nil ? "选择参考图片…" : "更换图片…")) { generator.chooseReference() }.buttonStyle(PlainAction()).disabled(session.busy)
                    if let reference = generator.reference {
                        Text(reference.name).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            if generator.mode == .image, generator.supportsImageToImage == false { Text(verbatim: L10n.text("运行中的图片服务需要重新启动，才能启用图生图。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText) }
            DisclosureGroup(L10n.text("生成参数")) {
                HStack(spacing: 14) {
                    Picker(L10n.text("图片尺寸"), selection: $generator.size) { ForEach(["1024x1024", "1344x768", "768x1344"], id: \.self) { Text($0).tag($0) } }.fixedSize()
                    TextField(L10n.text("种子"), text: $generator.seed).textFieldStyle(.roundedBorder).frame(width: 110)
                    if generator.mode == .image {
                        Text(verbatim: L10n.text("重绘强度"))
                        Slider(value: $generator.strength, in: 0.125...1, step: 0.125).frame(width: 100)
                        Text(verbatim: String(format: "%.1f%%", generator.strength * 100)).monospacedDigit()
                    }
                }.font(.system(size: TypeScale.callout)).padding(.top, 8).disabled(session.busy)
            }.font(.system(size: TypeScale.callout))
            HStack(alignment: .bottom, spacing: 10) {
                SolutionMessageField(input: $session.input, placeholder: generator.mode == .image ? "输入对参考图片的修改要求" : "描述想生成的图片，回车发送", disabled: session.busy) { session.send(store: store) }
                if generator.busy {
                    Button(L10n.text(generator.cancelling ? "正在取消…" : "取消生成")) { generator.cancel() }.buttonStyle(AccentButton(destructive: true)).disabled(generator.cancelling)
                } else {
                    Button { session.send(store: store) } label: { Label(L10n.text("生成图片"), systemImage: "paperplane.fill") }.buttonStyle(AccentButton()).disabled(!canSend)
                }
            }
            if let error = generator.error, session.turns.last?.error != error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText) }
        }.task { await generator.checkFeatures() }
    }
    private var canSend: Bool {
        session.ready(store) && !session.busy && !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.input.count <= 4096 && UInt32(generator.seed) != nil && (generator.mode == .text || (generator.reference != nil && generator.supportsImageToImage == true))
    }
}

@MainActor private struct SolutionMessageField: View {
    @Binding var input: String
    var placeholder: String
    var disabled: Bool
    var send: () -> Void
    var body: some View {
        TextField(L10n.text(placeholder), text: $input, axis: .vertical).lineLimit(1...4).textFieldStyle(.plain).font(.system(size: TypeScale.body))
            .padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: ButtonMetrics.height)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: ButtonMetrics.radius))
            .overlay { RoundedRectangle(cornerRadius: ButtonMetrics.radius).stroke(Theme.line) }
            .disabled(disabled).onSubmit(send).accessibilityIdentifier("solution-conversation-input")
    }
}
