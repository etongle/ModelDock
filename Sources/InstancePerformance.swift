import Foundation
import AVFoundation

enum BenchmarkOperation: String, Codable {
    case chat, transcription, speech, image, embedding
    var title: String {
        switch self {
        case .chat: return "文本生成"
        case .transcription: return "语音识别"
        case .speech: return "语音合成"
        case .image: return "图片生成"
        case .embedding: return "文本向量"
        }
    }
    var path: String {
        switch self {
        case .chat: return "/v1/chat/completions"
        case .transcription: return "/v1/audio/transcriptions"
        case .speech: return "/v1/audio/speech"
        case .image: return "/v1/images/generations"
        case .embedding: return "/v1/embeddings"
        }
    }
    static func detect(engine: String, model: String, kind: ModelKind?, capabilities: ModelCapabilities) -> Self {
        if engine == "mflux" || kind == .image || capabilities.outputs == ["image"] { return .image }
        if kind == .embedding { return .embedding }
        if capabilities.outputs.contains("audio") { return .speech }
        if engine == "audio" || kind == .speech {
            return model.lowercased().contains("tts") ? .speech : .transcription
        }
        return .chat
    }
}

extension BenchmarkTarget {
    /// Legacy records already encode the service UUID in their target ID. Never group by model alone.
    var instanceKey: String {
        if id.hasPrefix("external:") { return "external:\(port)" }
        let first = String(id.split(separator: ":", maxSplits: 1).first ?? "")
        return UUID(uuidString: first) == nil ? id : first
    }
    func validateProcess() throws {
        if let pid, let birth, birth > 0, processStartTime(pid) != birth {
            throw LaunchError.message("服务进程已变化，请刷新后重新选择")
        }
    }
}

struct InstanceBenchmarkInput {
    var audioURL: URL?
    var referenceText = ""
    var text = "Hello. This is a short local speech synthesis performance test."
    var imageSize = "1024x1024"
    var imagePrompt = "A red sailboat on a calm lake, natural daylight."
    // Reference recordings and generated media are deliberately never written to performance history.
    func audioData() throws -> Data {
        guard let audioURL, let size = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 20_000_000 else { throw LaunchError.message("请选择小于 20 MB 的音频文件") }
        return try Data(contentsOf: audioURL, options: .mappedIfSafe)
    }
    var duration: Double? {
        guard let audioURL, let file = try? AVAudioFile(forReading: audioURL), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

extension BenchmarkRunner {
    /// Non-streaming endpoints have a total latency, not a token generation rate or a TTFT.
    func runOperation(target: BenchmarkTarget, input: InstanceBenchmarkInput, chip: String, apiKey: String = "", progress: @escaping @Sendable (String) -> Void) async throws -> BenchmarkResult {
        guard let operation = target.operation, operation != .chat, (1024...65535).contains(target.port), !target.apiModel.isEmpty else { throw LaunchError.message("请选择有效的模型服务和输出长度") }
        try target.validateProcess()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(target.port)" + operation.path)!)
        request.httpMethod = "POST"; request.timeoutInterval = operation == .image ? 1800 : 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": target.apiModel]
        var audioSeconds: Double?
        var sample = ""
        switch operation {
        case .transcription:
            let audio = try input.audioData(); audioSeconds = input.duration
            // Standard multipart works with both the bundled audio server and OpenAI-compatible ASR services.
            let boundary = "ModelDock-" + UUID().uuidString
            var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(target.apiModel)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sample.\(input.audioURL?.pathExtension ?? "wav")\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            data.append(audio); data.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type"); request.httpBody = data
            sample = audioSeconds.map { String(format: "%.2f s", $0) } ?? L10n.text("音频样本")
        case .speech:
            guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.text.count <= 2000 else { throw LaunchError.message("请输入 1–2000 字的测试文本") }
            body["input"] = input.text; body["response_format"] = "wav"; body["language"] = "English"
            body["voice"] = "Vivian"; body["instructions"] = "A clear and natural voice."
            if input.audioURL != nil {
                guard !input.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.message("参考音频需要填写对应原文") }
                body["reference_audio"] = try input.audioData().base64EncodedString(); body["reference_text"] = input.referenceText
            } else if target.apiModel.lowercased().contains("base") {
                throw LaunchError.message("此 Base 语音模型需要参考音频及对应原文")
            }
            sample = L10n.text("固定语音测试文本")
        case .image:
            guard ["512x512", "1024x1024"].contains(input.imageSize) else { throw LaunchError.message("图片尺寸无效") }
            body["prompt"] = input.imagePrompt; body["size"] = input.imageSize; body["seed"] = 42; body["n"] = 1; body["response_format"] = "b64_json"
            sample = input.imageSize + " · seed 42"
        case .embedding:
            body["input"] = "Organize local models by task, format, memory requirements and version."
            sample = L10n.text("固定向量测试文本")
        case .chat: break
        }
        if request.httpBody == nil { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let peak = PeakSampler()
        let sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let pid = target.pid { await peak.add(ResourceSampler.process(pid, birth: target.birth)) }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
        defer { sampler.cancel() }
        progress("正在执行实例性能测试…")
        let start = DispatchTime.now().uptimeNanoseconds
        let (data, response) = try await session.data(for: request)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        try Task.checkCancellation(); try target.validateProcess()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [401, 403].contains(code) { throw LaunchError.message("此服务需要访问密钥，请填写后重试。") }
            // Do not surface arbitrary service responses, which can contain reference audio or credentials.
            throw LaunchError.message("性能测试失败（HTTP \(code)），请检查此实例的接口与运行日志")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var units: Int?
        switch operation {
        case .transcription:
            guard object?["text"] is String else { throw LaunchError.message("服务未返回有效测试结果") }
        case .speech:
            guard let seconds = Self.wavDuration(data), seconds > 0 else { throw LaunchError.message("语音服务没有返回有效的 WAV 音频") }
            audioSeconds = seconds
        case .image:
            guard let entries = object?["data"] as? [[String: Any]], let encoded = entries.first?["b64_json"] as? String,
                  let image = Data(base64Encoded: encoded), image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw LaunchError.message("服务未返回有效测试结果") }
            units = entries.count
        case .embedding:
            guard let entries = object?["data"] as? [[String: Any]], let embedding = entries.first?["embedding"] as? [NSNumber], !embedding.isEmpty, embedding.allSatisfy({ $0.doubleValue.isFinite }) else { throw LaunchError.message("服务未返回有效测试结果") }
            units = embedding.count
        case .chat: break
        }
        if let pid = target.pid { await peak.add(await Task.detached { ResourceSampler.process(pid, birth: target.birth) }.value) }
        return BenchmarkResult(target: target, chip: chip, requestedTokens: 0, elapsed: elapsed, peakMemory: await peak.bytes, processCount: await peak.count,
                               rateSource: "非流式接口仅测量总耗时；语音实时倍率为音频时长除以总耗时，越高越快。", audioSeconds: audioSeconds, outputUnits: units, sampleDescription: sample)
    }
    static func wavDuration(_ data: Data) -> Double? {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        func uint(_ p: Int, _ count: Int) -> UInt64 { (0..<count).reduce(0) { $0 | UInt64(data[p + $1]) << (8 * $1) } }
        var offset = 12; var byteRate: UInt64?; var audioBytes: UInt64?
        while offset <= data.count - 8 {
            let size = uint(offset + 4, 4)
            guard size <= UInt64(data.count - offset - 8) else { return nil }
            let tag = data.subdata(in: offset..<offset + 4)
            if tag == Data("fmt ".utf8), size >= 16 { byteRate = uint(offset + 16, 4) }
            if tag == Data("data".utf8) { audioBytes = size }
            offset += 8 + Int(size) + Int(size % 2)
        }
        guard let byteRate, byteRate > 0, let audioBytes else { return nil }
        return Double(audioBytes) / Double(byteRate)
    }
}

@MainActor extension AppStore {
    func instanceBenchmarkTargets(serviceID: String? = nil, port: Int) -> [BenchmarkTarget] {
        let spec = serviceID.flatMap { id in services.records.first { $0.id == id && $0.port == port } }
        let external = services.external.first { $0.port == port }
        guard spec != nil || external != nil else { return [] }
        let engineID = spec?.engineID ?? external?.engineID ?? "external"
        let local = spec.flatMap { spec in models.first { $0.matchesID(spec.modelID) } }
        let engine = engines.first { $0.id == engineID }
        let names = services.reportedModels[port] ?? external?.models ?? []
        let candidates = names.isEmpty ? [local?.repository ?? spec?.modelName ?? ""].filter { !$0.isEmpty } : names
        return candidates.map { name in
            let model = engineID == "ollama" ? models.first { $0.format == "Ollama" && $0.repository == name } : local
            let capabilities = services.modelCapabilities[port]?[name] ?? spec.map(serviceCapabilities) ?? ModelCapabilities()
            return BenchmarkTarget(id: "\(spec?.id ?? "external:\(port)"):\(name)", engineID: engineID, engineName: engine?.name ?? external?.engineName ?? engineID, engineVersion: spec?.engineVersion ?? engine?.version ?? "—", modelID: model?.id, modelName: model?.name ?? spec.map(serviceDisplayName) ?? name, apiModel: name, port: port, pid: spec?.pid ?? external?.pid, birth: spec?.processStart ?? external?.birth, context: spec?.context,
                                   operation: .detect(engine: engineID, model: name, kind: model?.kind, capabilities: capabilities))
        }
    }
    func openInstanceBenchmark(serviceID: String? = nil, port: Int) { instanceBenchmark = .init(serviceID: serviceID, port: port) }
}

struct InstanceBenchmarkDraft: Identifiable {
    let id = UUID()
    var serviceID: String?
    var port: Int
}
