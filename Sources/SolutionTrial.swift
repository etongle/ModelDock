import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor final class SolutionTrialController: ObservableObject {
    @Published var input: URL?
    @Published var query = ""
    @Published var transcript = ""
    @Published var translation = ""
    @Published var output: URL?
    @Published var phase = ""
    @Published var error: String?
    @Published var busy = false
    @Published var connection: SolutionTrialConnection = .gateway
    private var operation: Task<Void, Never>?
    private let directory: URL
    init(directory: URL) { self.directory = directory.appendingPathComponent("solutions/outputs") }
    func chooseFile(image: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = image ? [.image] : [.audio]
        if panel.runModal() == .OK { input = panel.url; transcript = ""; translation = ""; output = nil; error = nil }
    }
    func reset() { operation?.cancel(); operation = nil; input = nil; transcript = ""; translation = ""; output = nil; phase = ""; error = nil }
    func cancel() { operation?.cancel() }
    func run(_ deployment: SolutionDeployment, store: AppStore) {
        guard !busy else { return }
        busy = true; error = nil; transcript = ""; translation = ""; output = nil
        let input = input, query = query, connection = connection
        operation = Task { [weak self, weak store] in
            guard let self, let store else { return }; defer { busy = false; operation = nil }
            do {
                if deployment.solutionID == "voice-translation" {
                    guard store.solutions.runtime(deployment, store: store).allReady else { throw LaunchError.message("请先启动方案中的全部服务并等待就绪") }
                    guard let input, let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 20 * 1024 * 1024 else { throw LaunchError.message("请选择不超过 20 MiB 的音频文件") }
                    let result = try await SpeechTranslation.run(audio: Data(contentsOf: input), deployment: deployment, store: store, connection: connection, speech: true) { [weak self] value in self?.phase = value }
                    transcript = result.transcript; translation = result.translation
                    if let audio = result.audio {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let file = directory.appendingPathComponent(UUID().uuidString + ".wav")
                        try audio.write(to: file, options: .atomic); output = file
                    }
                    phase = "试用完成"; return
                }
                let transport = try SolutionTrialTransport(connection: connection, deployment: deployment, store: store)
                @MainActor func service(_ role: SolutionRole) throws -> ServiceSpec {
                    guard let id = deployment.components.first(where: { $0.role == role })?.serviceID, let spec = store.services.records.first(where: { $0.id == id }), store.services.status(spec) == .running else { throw LaunchError.message("请先启动方案中的全部服务并等待就绪") }
                    return spec
                }
                if deployment.solutionID == "transcription" || deployment.solutionID == "voice-translation" {
                    guard let input else { throw LaunchError.message("请先选择音频文件") }
                    let metadata = try input.resourceValues(forKeys: [.fileSizeKey])
                    guard let size = metadata.fileSize, size > 0, size <= 20 * 1024 * 1024 else { throw LaunchError.message("请选择不超过 20 MiB 的音频文件") }
                    let audio = try Data(contentsOf: input)
                    phase = "正在识别语音…"
                    let asr = try service(.asr), model = try transport.model(.asr, spec: asr, store: store)
                    let boundary = "ModelDock-" + UUID().uuidString
                    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"input.audio\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
                    body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                    let result = try await transport.request(.asr, spec: asr, path: "/v1/audio/transcriptions", body: body, type: "multipart/form-data; boundary=" + boundary, store: store)
                    guard let text = (try JSONSerialization.jsonObject(with: result) as? [String: Any])?["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.message("未识别到文字，请换一段清晰的语音") }
                    transcript = text
                } else {
                    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.message("请输入试用问题") }
                    phase = "正在测试模型…"
                    let role: SolutionRole = deployment.solutionID == "vision" ? .vision : .chat
                    var message: [String: Any] = ["role": "user", "content": query]
                    if role == .vision {
                        guard let input, let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1024 * 1024 else { throw LaunchError.message("请选择不超过 10 MiB 的图片") }
                        let bytes = try Data(contentsOf: input), mime = UTType(filenameExtension: input.pathExtension)?.preferredMIMEType ?? "image/png"
                        message["content"] = [["type": "text", "text": query], ["type": "image_url", "image_url": ["url": "data:\(mime);base64," + bytes.base64EncodedString()]]]
                    }
                    translation = try await chat(service(role), role: role, transport: transport, messages: [message], store: store)
                }
                phase = "试用完成"
            } catch is CancellationError { phase = "已取消试用" }
            catch { if Task.isCancelled { phase = "已取消试用" } else { self.error = error.localizedDescription; phase = "试用未完成" } }
        }
    }
    private func chat(_ spec: ServiceSpec, role: SolutionRole, transport: SolutionTrialTransport, messages: [[String: Any]], store: AppStore) async throws -> String {
        let data = try await transport.request(role, spec: spec, path: "/v1/chat/completions", body: JSONSerialization.data(withJSONObject: ["model": transport.model(role, spec: spec, store: store), "messages": messages, "max_tokens": 2048, "stream": false, "chat_template_kwargs": ["enable_thinking": false]]), store: store)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String, !content.isEmpty else { throw LaunchError.message("模型未返回完整文字，请查看服务日志") }
        return content
    }
}
