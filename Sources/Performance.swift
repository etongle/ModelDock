import Foundation
import Combine

struct BenchmarkTarget: Identifiable, Hashable, Codable {
    var id: String; var engineID: String; var engineName: String; var engineVersion: String
    var modelID: String?; var modelName: String; var apiModel: String
    var port: Int; var pid: Int32?; var birth: UInt64?; var context: Int?
    var operation: BenchmarkOperation? = nil
}
struct BenchmarkResult: Identifiable, Codable {
    var id = UUID().uuidString; var date = Date()
    var target: BenchmarkTarget; var chip: String; var requestedTokens: Int
    var promptTokens: Int?; var outputTokens: Int?; var cachedTokens: Int?
    var firstOutput: Double?; var elapsed: Double
    var generationRate: Double?; var promptRate: Double?; var endToEndRate: Double?
    var peakMemory: UInt64?; var processCount: Int?; var rateSource: String
    var audioSeconds: Double? = nil
    var outputUnits: Int? = nil
    var sampleDescription: String? = nil
}

struct StreamMetrics {
    var promptTokens: Int?; var outputTokens: Int?; var cachedTokens: Int?
    var generationRate: Double?; var promptRate: Double?; var firstOutput: Double?
    var done = false; var finishReason = false; private var dataLines: [String] = []
    mutating func line(_ line: String, elapsed: Double) throws {
        guard line.utf8.count < 1_000_000 else { throw LaunchError.message("服务返回的单条数据过大，已停止测量") }
        if line.isEmpty { try flush(elapsed: elapsed) }
        else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            let value = dataLines.joined(separator: "\n")
            guard value.utf8.count < 1_000_000 else { throw LaunchError.message("性能响应数据过大，已停止测量") }
            // AsyncBytes.lines can omit blank lines. Consume complete JSON events
            // immediately, while still allowing multi-line SSE JSON payloads.
            if value == "[DONE]" || (value.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) is [String: Any] { try flush(elapsed: elapsed) }
        }
    }
    mutating func flush(elapsed: Double) throws {
        guard !dataLines.isEmpty else { return }
        let value = dataLines.joined(separator: "\n"); dataLines = []
        if value == "[DONE]" { done = true; return }
        guard let data = value.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LaunchError.message("无法解析服务的性能响应") }
        if object["error"] != nil { throw LaunchError.message("模型服务返回错误，请查看服务日志") }
        if let usage = object["usage"] as? [String: Any] {
            promptTokens = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? promptTokens
            outputTokens = (usage["completion_tokens"] as? NSNumber)?.intValue ?? outputTokens
            cachedTokens = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? cachedTokens
        }
        if let timings = object["timings"] as? [String: Any] {
            promptTokens = (timings["prompt_n"] as? NSNumber)?.intValue ?? promptTokens
            outputTokens = (timings["predicted_n"] as? NSNumber)?.intValue ?? outputTokens
            cachedTokens = (timings["cache_n"] as? NSNumber)?.intValue ?? cachedTokens
            generationRate = Self.rate(timings["predicted_per_second"]) ?? generationRate
            promptRate = Self.rate(timings["prompt_per_second"]) ?? promptRate
        }
        for choice in object["choices"] as? [[String: Any]] ?? [] {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let output = (delta["content"] as? String ?? "") + (delta["reasoning_content"] as? String ?? "") + (choice["text"] as? String ?? "")
            if firstOutput == nil && (!output.isEmpty || delta["tool_calls"] != nil) { firstOutput = elapsed }
            if choice["finish_reason"] is String { finishReason = true }
        }
    }
    private static func rate(_ value: Any?) -> Double? { guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }; return value }
}

actor PeakSampler {
    var bytes: UInt64?; var count: Int?
    func add(_ sample: ProcessSample?) { if let sample { bytes = max(bytes ?? 0, sample.bytes); count = max(count ?? 0, sample.processes.count) } }
}

final class BenchmarkRunner: @unchecked Sendable {
    let session = URLSession(configuration: .ephemeral)
    func cancel() { session.invalidateAndCancel() }
    func run(target: BenchmarkTarget, tokens: Int, chip: String, apiKey: String = "", progress: @escaping @Sendable (String) -> Void) async throws -> BenchmarkResult {
        guard (1024...65535).contains(target.port), (8...512).contains(tokens), !target.apiModel.isEmpty else { throw LaunchError.message("请选择有效的模型服务和输出长度") }
        if let pid = target.pid, let birth = target.birth, birth > 0, processStartTime(pid) != birth { throw LaunchError.message("服务进程已变化，请刷新后重新选择") }
        var modelRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(target.port)/v1/models")!); modelRequest.timeoutInterval = 10
        if !apiKey.isEmpty { modelRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let (modelData, modelResponse) = try await session.data(for: modelRequest)
        if (modelResponse as? HTTPURLResponse)?.statusCode == 200 {
            let object = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any]
            let names = (object?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            if !names.contains(target.apiModel) {
                throw LaunchError.message("所选模型已不在此接口中，请刷新后重新选择")
            }
        }
        let peak = PeakSampler()
        var pid = target.pid; var birth = target.birth
        if pid == nil {
            let port = target.port
            pid = await Task.detached { runText("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]).components(separatedBy: "\n").compactMap(Int32.init).first }.value
            birth = pid.map(processStartTime)
        }
        let rootPID = pid; let rootBirth = birth
        let sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let rootPID { await peak.add(ResourceSampler.process(rootPID, birth: rootBirth)) }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
            }
        }
        defer { sampler.cancel(); session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(target.port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 60; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": target.apiModel, "messages": [["role": "user", "content": "This is a short inference speed test. Write a numbered list of practical tips for organizing a local model library. Keep writing until you reach twenty tips. Do not use tools."]], "max_tokens": tokens, "temperature": 0, "stream": true, "stream_options": ["include_usage": true]])
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 }
        progress("正在等待模型的首个输出…")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LaunchError.message([401, 403].contains(status) ? "此服务需要访问密钥，请填写后重试。" : "性能测量请求失败（HTTP \(status)），请确认服务支持流式聊天接口。")
        }
        guard http.mimeType == "text/event-stream" else { throw LaunchError.message("此服务未返回流式输出，暂时无法测量首个输出延迟。") }
        var metrics = StreamMetrics(); var reportedFirst = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try metrics.line(line, elapsed: elapsed())
            if !reportedFirst, let first = metrics.firstOutput { progress(String(format: "已收到首个输出（%.2f 秒），正在测量生成速度…", first)); reportedFirst = true }
            if metrics.done { break }
        }
        try metrics.flush(elapsed: elapsed())
        try Task.checkCancellation()
        guard metrics.done || metrics.finishReason else { throw LaunchError.message("服务响应提前中断，本次结果未保存") }
        try target.validateProcess()
        let duration = elapsed()
        if let rootPID { await peak.add(await Task.detached { ResourceSampler.process(rootPID, birth: rootBirth) }.value) }
        var measured = target; measured.pid = pid; measured.birth = birth
        return .init(target: measured, chip: chip, requestedTokens: tokens, promptTokens: metrics.promptTokens, outputTokens: metrics.outputTokens, cachedTokens: metrics.cachedTokens, firstOutput: metrics.firstOutput, elapsed: duration, generationRate: metrics.generationRate, promptRate: metrics.promptRate, endToEndRate: metrics.outputTokens.flatMap { $0 > 0 && duration > 0 ? Double($0) / duration : nil }, peakMemory: await peak.bytes, processCount: await peak.count, rateSource: metrics.generationRate == nil ? "引擎未返回生成计时；端到端吞吐包含等待与输入处理" : "生成速度采用引擎返回的计时")
    }
}

@MainActor
final class PerformanceController: ObservableObject {
    @Published var records: [BenchmarkResult] = []
    @Published var selection = ""
    @Published var outputLimit = 128
    @Published var apiKey = ""
    @Published var running = false
    @Published var phase = ""
    @Published var message: String?
    @Published var activeTarget: BenchmarkTarget?
    private var runner: BenchmarkRunner?
    private var task: Task<Void, Never>?
    private let file: URL
    private var measurementID: UUID?
    init(directory: URL) {
        file = directory.appendingPathComponent("performance.json")
        records = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([BenchmarkResult].self, from: $0) } ?? []
    }
    func measure(_ target: BenchmarkTarget, chip: String, input: InstanceBenchmarkInput = .init()) {
        guard !running else { return }
        running = true; activeTarget = target; selection = target.id; message = nil; phase = "正在准备测量…"
        let measurementID = UUID(); self.measurementID = measurementID
        let worker = BenchmarkRunner(); runner = worker; let limit = outputLimit; let key = apiKey
        task = Task { [weak self] in
            do {
                let progress: @Sendable (String) -> Void = { [weak self] value in Task { @MainActor in if self?.measurementID == measurementID && self?.running == true { self?.phase = value } } }
                let result: BenchmarkResult
                if target.operation == nil || target.operation == .chat {
                    result = try await worker.run(target: target, tokens: limit, chip: chip, apiKey: key, progress: progress)
                } else {
                    result = try await worker.runOperation(target: target, input: input, chip: chip, apiKey: key, progress: progress)
                }
                guard let self else { return }
                try self.add(result); self.phase = "测量完成"
            } catch { self?.message = Task.isCancelled ? "测量已取消" : error.localizedDescription; self?.phase = "" }
            self?.running = false; self?.runner = nil; self?.task = nil; self?.measurementID = nil; self?.activeTarget = nil
        }
    }
    func cancel() { task?.cancel(); runner?.cancel() }
    /// 新增一条记录（最新在前，最多保留 100 条）并保存。
    func add(_ result: BenchmarkResult) throws {
        let next = Array(([result] + records).prefix(100))
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        records = next
    }
    /// 删除符合条件的历史记录并保存，返回删除数量。
    @discardableResult
    func remove(where match: (BenchmarkResult) -> Bool) throws -> Int {
        let remaining = records.filter { !match($0) }
        let count = records.count - remaining.count
        guard count > 0 else { return 0 }
        try JSONEncoder().encode(remaining).write(to: file, options: .atomic)
        records = remaining
        return count
    }
}
