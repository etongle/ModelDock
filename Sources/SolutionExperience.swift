import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

struct SolutionConversationTurn: Identifiable {
    let id = UUID()
    var source: String
    var input: String
    var response = ""
    var referenceName: String?
    var image: URL?
    var audio: URL?
    var error: String?
    var pending = true
}

/// A conversation belongs to one deployment configuration, even when deployments share a service.
@MainActor final class SolutionExperienceSession: ObservableObject, Identifiable {
    let id: String
    let configuration: String
    let deployment: SolutionDeployment
    let microphone = RealtimeTranslationController()
    @Published var turns: [SolutionConversationTurn] = []
    @Published var input = ""
    @Published var sending = false
    @Published var phase = ""
    @Published var error: String?
    @Published private(set) var generator: ImageGenerationSession?
    private var operation: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var imageSubscriptions = Set<AnyCancellable>()
    private var subtitleIDs = Set<UUID>()
    private var imageTurn: UUID?
    private let directory: URL
    var isImage: Bool { deployment.solutionID == "image-generation" }
    var busy: Bool { sending || generator?.busy == true || microphone.listening || microphone.processing }
    var hasHistory: Bool { !turns.isEmpty }

    static func fingerprint(_ deployment: SolutionDeployment) -> String {
        struct Configuration: Encodable { var draft: SolutionDraft; var components: [SolutionComponent] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Configuration(draft: deployment.draft, components: deployment.components)).base64EncodedString()) ?? deployment.id
    }
    init(_ deployment: SolutionDeployment) {
        self.deployment = deployment; id = deployment.id; configuration = Self.fingerprint(deployment)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelDock-conversation-" + UUID().uuidString)
        microphone.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        microphone.$subtitles.sink { [weak self] values in
            guard let self else { return }
            for value in values where self.subtitleIDs.insert(value.id).inserted {
                self.turns.append(.init(source: "麦克风实时翻译", input: value.original, response: value.translated, pending: false))
            }
        }.store(in: &subscriptions)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func ready(_ store: AppStore) -> Bool {
        guard let current = store.solutions.deployments.first(where: { $0.id == id }),
              Self.fingerprint(current) == configuration, current.state == .configured,
              store.solutions.runtime(current, store: store).allReady else { return false }
        return isImage || store.gateway.solutionReady(current)
    }
    func bindImage(_ store: AppStore) {
        guard isImage, !busy, let component = deployment.components.first(where: { $0.role == .image }),
              let spec = store.services.records.first(where: { $0.id == component.serviceID }), store.services.status(spec) == .running else { return }
        let apiModel = component.serviceBinding?.model ?? store.services.reportedModels[spec.port]?.first ?? ImageModelPolicy.repository
        if let generator, generator.spec.id == spec.id, generator.spec.processStart == spec.processStart, generator.apiModel == apiModel { return }
        imageSubscriptions.removeAll()
        let value = ImageGenerationSession(spec: spec, apiModel: apiModel)
        // Keep unsent controls across a service restart; completed turns already live independently.
        if let generator { value.mode = generator.mode; value.reference = generator.reference; value.size = generator.size; value.seed = generator.seed; value.strength = generator.strength }
        generator = value
        value.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &imageSubscriptions)
        value.$busy.dropFirst().sink { [weak self, weak value] busy in
            guard !busy, let self, let value, let id = self.imageTurn,
                  let index = self.turns.firstIndex(where: { $0.id == id }) else { return }
            self.turns[index].pending = false
            do {
                if let data = value.data { self.turns[index].image = try self.save(data, extension: "png") }
                else { self.turns[index].error = value.error ?? "已取消生成" }
            } catch { self.turns[index].error = error.localizedDescription }
            self.imageTurn = nil
        }.store(in: &imageSubscriptions)
        Task { await value.checkFeatures() }
    }
    func send(store: AppStore) {
        guard !busy, ready(store) else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096 else { return }
        error = nil
        if isImage {
            bindImage(store)
            guard let generator else { return }
            generator.prompt = text
            guard generator.canGenerate else { return }
            let turn = SolutionConversationTurn(source: generator.mode.rawValue, input: text, referenceName: generator.mode == .image ? generator.reference?.name : nil)
            turns.append(turn); imageTurn = turn.id; input = ""; generator.generate()
        } else {
            let context = translationContext
            let turn = SolutionConversationTurn(source: "文字翻译", input: text)
            turns.append(turn); input = ""; sending = true; phase = "正在翻译文字…"
            operation = Task { [weak self, weak store] in
                guard let self, let store else { return }
                defer { sending = false; operation = nil }
                do {
                    let transport = try SolutionTrialTransport(connection: .gateway, deployment: deployment, store: store)
                    guard let component = deployment.components.first(where: { $0.role == .text }),
                          let service = store.services.records.first(where: { $0.id == component.serviceID }) else { throw LaunchError.message("请先启动方案中的全部服务并等待就绪") }
                    let response = try await SpeechTranslation.translate(text, deployment: deployment, store: store, transport: transport, service: service, history: context)
                    try Task.checkCancellation()
                    finish(turn.id, response: response)
                } catch { fail(turn.id, error: error) }
            }
        }
    }
    var translationContext: [[String: String]] {
        // Bound the model context without removing anything from the visible conversation.
        var length = 0, selected: [SolutionConversationTurn] = []
        for turn in turns.reversed() where !turn.pending && turn.error == nil && !turn.response.isEmpty {
            let count = turn.input.count + turn.response.count
            if selected.count == 8 || length + count > 12000 { break }
            selected.append(turn); length += count
        }
        return selected.reversed().flatMap { [["role": "user", "content": $0.input], ["role": "assistant", "content": $0.response]] }
    }
    func chooseAudio(store: AppStore) {
        guard !busy, ready(store) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        translateAudio(file, store: store)
    }
    func translateAudio(_ file: URL, store: AppStore) {
        guard !busy, ready(store) else { return }
        let turn = SolutionConversationTurn(source: "音频文件翻译", input: file.lastPathComponent)
        turns.append(turn); sending = true; error = nil
        operation = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { sending = false; operation = nil }
            do {
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 20 * 1024 * 1024 else { throw LaunchError.message("请选择不超过 20 MiB 的音频文件") }
                let result = try await SpeechTranslation.run(audio: Data(contentsOf: file), deployment: deployment, store: store, connection: .gateway, speech: microphone.readAloud) { [weak self] in self?.phase = $0 }
                try Task.checkCancellation()
                let audio = try result.audio.map { try self.save($0, extension: "wav") }
                if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index].input = result.transcript; turns[index].audio = audio }
                finish(turn.id, response: result.translation)
            } catch { fail(turn.id, error: error) }
        }
    }
    func listen(store: AppStore) {
        guard !busy, ready(store) else { return }
        error = nil; microphone.start(deployment, store: store, preserveHistory: true)
    }
    func stop() {
        operation?.cancel(); microphone.cancel(); generator?.cancel()
    }
    /// Closing the sheet stops capture; submitted image/text tasks can finish into this session.
    func dismiss() { microphone.cancel() }
    func newConversation() {
        guard !busy else { return }
        turns = []; input = ""; error = nil; phase = ""; subtitleIDs = []; microphone.subtitles = []; microphone.error = nil
        generator?.reference = nil; generator?.mode = .text; generator?.image = nil; generator?.error = nil
        // Only files created by this transient conversation are removed, never model or service files.
        try? FileManager.default.removeItem(at: directory)
    }
    func editImage(_ turn: SolutionConversationTurn, store: AppStore) {
        guard !busy, ready(store), let url = turn.image else { return }
        bindImage(store)
        do { generator?.reference = try ImageReference.read(url); generator?.mode = .image; input = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func saveImage(_ turn: SolutionConversationTurn) {
        guard let image = turn.image else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "ModelDock-Qwen-Image.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(contentsOf: image).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    private func save(_ data: Data, extension suffix: String) throws -> URL {
        try ConnectionFiles.privateDirectory(directory)
        let file = directory.appendingPathComponent(UUID().uuidString + "." + suffix)
        try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
    private func finish(_ id: UUID, response: String) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].response = response; turns[index].pending = false; phase = "试用完成"
    }
    private func fail(_ id: UUID, error: Error) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].error = Task.isCancelled ? "已取消试用" : error.localizedDescription
        turns[index].pending = false; phase = "试用未完成"
    }
}

@MainActor extension AppStore {
    func experienceSession(_ record: SolutionDeployment) -> SolutionExperienceSession {
        if let value = solutionExperiences[record.id], value.configuration == SolutionExperienceSession.fingerprint(record) { return value }
        solutionExperiences[record.id]?.stop()
        let value = SolutionExperienceSession(record); solutionExperiences[record.id] = value
        return value
    }
    func openSolutionExperience(_ record: SolutionDeployment) {
        if record.solutionID == "image-generation" {
            Task { do { try await imagePlayground.open(record, store: self) } catch { message = error.localizedDescription } }
            return
        }
        let session = experienceSession(record)
        guard session.ready(self) else { message = "请先启动方案中的全部服务并等待就绪"; return }
        session.bindImage(self); solutionExperience = session
    }
}
