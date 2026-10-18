import Foundation

struct SpeechTranslationResult { var transcript: String; var translation: String; var audio: Data? }

@MainActor enum SpeechTranslation {
    static func run(audio: Data, deployment: SolutionDeployment, store: AppStore, connection: SolutionTrialConnection, speech: Bool, stage: (String) -> Void) async throws -> SpeechTranslationResult {
        let transport = try SolutionTrialTransport(connection: connection, deployment: deployment, store: store)
        func service(_ role: SolutionRole) throws -> ServiceSpec {
            guard let component = deployment.components.first(where: { $0.role == role }), let spec = store.services.records.first(where: { $0.id == component.serviceID }), store.services.status(spec) == .running else { throw LaunchError.message("请先启动方案中的全部服务并等待就绪") }
            if role == .text, let model = store.models.first(where: { $0.id == component.modelID }), let issue = TranslationLanguages.modelIssue(model) { throw LaunchError.message(issue) }
            return spec
        }
        stage("正在识别语音…")
        let asr = try service(.asr)
        var request: [String: Any] = ["model": try transport.model(.asr, spec: asr, store: store), "audio": audio.base64EncodedString()]
        if let language = deployment.draft.sourceLanguage { request["language"] = language }
        let recognized = try await transport.request(.asr, spec: asr, path: "/v1/audio/transcriptions", body: JSONSerialization.data(withJSONObject: request), store: store)
        guard let text = (try JSONSerialization.jsonObject(with: recognized) as? [String: Any])?["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.message("未识别到文字，请换一段清晰的语音") }
        stage("正在翻译文字…")
        let translator = try service(.text)
        let translated = try await transport.request(.text, spec: translator, path: "/v1/chat/completions", body: JSONSerialization.data(withJSONObject: ["model": transport.model(.text, spec: translator, store: store), "messages": [["role": "system", "content": "Translate the user's transcript into \(deployment.draft.language). Return only the translation, without commentary."], ["role": "user", "content": text]], "max_tokens": 2048, "stream": false, "chat_template_kwargs": ["enable_thinking": false]]), store: store)
        guard let object = try JSONSerialization.jsonObject(with: translated) as? [String: Any], let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any], let translation = message["content"] as? String, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.message("模型未返回完整文字，请查看服务日志") }
        var result = SpeechTranslationResult(transcript: text, translation: translation)
        if speech && deployment.draft.speechOutput != false && deployment.components.contains(where: { $0.role == .tts }) {
            stage("正在生成参考音色配音…")
            let tts = try service(.tts)
            let bytes = try await transport.request(.tts, spec: tts, path: "/v1/audio/speech", body: JSONSerialization.data(withJSONObject: ["model": transport.model(.tts, spec: tts, store: store), "input": translation, "language": deployment.draft.language, "reference_audio": audio.base64EncodedString(), "reference_text": text]), store: store)
            guard bytes.count > 44, bytes.prefix(4) == Data("RIFF".utf8), bytes.subdata(in: 8..<12) == Data("WAVE".utf8) else { throw LaunchError.message("语音服务没有返回有效的 WAV 音频") }
            result.audio = bytes
        }
        return result
    }
}
