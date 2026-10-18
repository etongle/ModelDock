import Foundation
import Combine
import AVFoundation
import SwiftUI

struct RealtimeSubtitle: Identifiable {
    var id = UUID(); var created = Date(); var original: String; var translated: String
}

@MainActor final class RealtimeTranslationController: ObservableObject {
    @Published var listening = false
    @Published var processing = false
    @Published var pending = 0
    @Published var level: Float = 0
    @Published var subtitles: [RealtimeSubtitle] = []
    @Published var phase = ""
    @Published var error: String?
    @Published var readAloud = false
    private var capture = MicrophoneCapture()
    private var player: AVAudioPlayer?
    private var clips: [Data] = []
    private var operation: Task<Void, Never>?
    private var session = UUID()
    private var flush: ((Data) -> Void)?

    func start(_ deployment: SolutionDeployment, store: AppStore, microphone: Bool = true) {
        guard !listening && !processing else { return }
        error = nil; subtitles = []; clips = []; pending = 0; session = UUID()
        let token = session
        flush = { [weak self, weak store] data in guard let self, let store else { return }; self.submit(data, deployment: deployment, store: store) }
        operation = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { if session == token { operation = nil } }
            do {
                guard store.solutions.runtime(deployment, store: store).allReady && store.gateway.solutionReady(deployment) else { throw LaunchError.message("请先启动方案中的全部服务并等待就绪") }
                listening = true; phase = "正在收音，停顿后翻译…"
                if microphone {
                    try await capture.start(onSegment: { [weak self, weak store] data in
                        Task { @MainActor in guard let self, let store, self.session == token, self.listening else { return }; self.submit(data, deployment: deployment, store: store) }
                    }, onLevel: { [weak self] value in Task { @MainActor in if self?.session == token { self?.level = value } } })
                    if session != token { capture.stop() }
                }
            } catch { if session == token { listening = false; self.error = error.localizedDescription; phase = "收音未启动" } }
        }
    }

    func submit(_ audio: Data, deployment: SolutionDeployment, store: AppStore) {
        guard listening else { return }
        guard clips.count < 3 else {
            capture.stop(); listening = false; error = "翻译暂时赶不上收音，已暂停麦克风。请等待队列完成后继续，并重说当前片段。"; return
        }
        clips.append(audio); pending = clips.count
        guard !processing else { return }
        processing = true
        let token = session
        operation = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { if session == token { processing = false; operation = nil; pending = clips.count; if error == nil { phase = listening ? "正在收音，停顿后翻译…" : "已停止收音" } } }
            while !clips.isEmpty && !Task.isCancelled && session == token {
                let audio = clips.removeFirst(); pending = clips.count
                do {
                    let result = try await SpeechTranslation.run(audio: audio, deployment: deployment, store: store, connection: .gateway, speech: readAloud) { [weak self] value in self?.phase = value }
                    try Task.checkCancellation(); guard session == token else { return }
                    subtitles.append(.init(original: result.transcript, translated: result.translation))
                    if subtitles.count > 100 { subtitles.removeFirst(subtitles.count - 100) }
                    if let bytes = result.audio, readAloud {
                        phase = "正在朗读译文，收音已暂停…"; capture.suspend(true)
                        defer { capture.suspend(false) }
                        player = try AVAudioPlayer(data: bytes); player?.play()
                        while player?.isPlaying == true && !Task.isCancelled { try await Task.sleep(nanoseconds: 100_000_000) }
                    }
                } catch is CancellationError { return }
                catch { self.error = error.localizedDescription; capture.stop(); listening = false; clips = []; pending = 0; return }
            }
        }
    }
    func stop() { if let audio = capture.stop(flush: true) { flush?(audio) }; listening = false; level = 0; if !processing { phase = "已停止收音" } }
    func cancel() {
        session = UUID(); capture.stop(); player?.stop(); player = nil; operation?.cancel(); operation = nil
        listening = false; processing = false; clips = []; pending = 0; level = 0; flush = nil; phase = "已停止收音"
    }
}

@MainActor struct RealtimeTranslationView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: RealtimeTranslationController
    var deployment: SolutionDeployment
    private var ready: Bool { store.solutions.runtime(deployment, store: store).allReady && store.gateway.solutionReady(deployment) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.text("麦克风实时翻译"), systemImage: "mic").font(.system(size: TypeScale.section, weight: .semibold))
                Spacer()
                Text(verbatim: TranslationLanguages.title(deployment.draft.sourceLanguage ?? "auto") + " → " + TranslationLanguages.title(deployment.draft.language)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
            Text(verbatim: L10n.text("停顿后逐段显示原文和译文；每段最长约 6 秒。录音仅用于本机方案服务，不会保存麦克风音频。"))
                .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if deployment.draft.speechOutput != false {
                Toggle(L10n.text("朗读译文（朗读时暂停收音）"), isOn: $controller.readAloud).toggleStyle(.switch)
            }
            HStack {
                if controller.listening {
                    Button(L10n.text("停止收音")) { controller.stop() }.buttonStyle(.bordered)
                } else {
                    Button(L10n.text("开始收音并翻译")) { controller.start(deployment, store: store) }.buttonStyle(AccentButton()).disabled(!ready || controller.processing)
                }
                if controller.processing { ProgressView().controlSize(.small); Button(L10n.text("取消")) { controller.cancel() }.buttonStyle(.bordered) }
                Text(verbatim: L10n.text(controller.phase)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                if controller.pending > 0 { Text(verbatim: L10n.format("等待翻译 {0} 段", [String(controller.pending)])).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            }
            if controller.listening { ProgressView(value: Double(min(1, controller.level * 8))).tint(Theme.accent).accessibilityLabel(L10n.text("麦克风音量")) }
            if !ready { Text(verbatim: L10n.text("先检查并启动方案，再开始收音。" )).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            ForEach(controller.subtitles.suffix(20)) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: item.original).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    Text(verbatim: item.translated).font(.system(size: TypeScale.body, weight: .medium)).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
            }
            if let error = controller.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
        }.padding(18).background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }.onDisappear { controller.cancel() }.accessibilityIdentifier("realtime-translation")
    }
}
