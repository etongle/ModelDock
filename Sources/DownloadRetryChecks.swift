import Foundation

final class DownloadRetryFixture: URLProtocol {
    static let payload = ModalityChecks.gguf([:]) + Data(repeating: 41, count: 128 * 1024)
    private static let lock = NSLock()
    private static var captured: [(path: String, token: String?, range: String?)] = []
    private let cancellation = NSLock()
    private var stopped = false
    static func requests(_ path: String) -> [(path: String, token: String?, range: String?)] {
        lock.lock(); defer { lock.unlock() }; return captured.filter { $0.path == path }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" && request.url?.path.hasPrefix("/retry-fixture/") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path, range = request.value(forHTTPHeaderField: "Range")
        Self.lock.lock(); Self.captured.append((path, request.value(forHTTPHeaderField: "Authorization"), range)); let attempt = Self.captured.filter { $0.path == path }.count; Self.lock.unlock()
        if path.contains("/certificate/") { client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted)); return }
        let offset = Int((range ?? "bytes=0-").dropFirst(6).split(separator: "-").first ?? "0") ?? 0
        let status = path.contains("/auth/") ? 401 : offset > 0 ? 206 : 200
        var headers = ["Content-Type": "application/octet-stream", "Content-Length": String(Self.payload.count - offset), "ETag": "fixture-retry"]
        if offset > 0 { headers["Content-Range"] = "bytes \(offset)-\(Self.payload.count - 1)/\(Self.payload.count)" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if status == 401 { client?.urlProtocolDidFinishLoading(self); return }
        if path.contains("/recover/"), attempt > 1 {
            client?.urlProtocol(self, didLoad: Self.payload.subdata(in: offset..<Self.payload.count)); client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didLoad: Self.payload.subdata(in: offset..<min(offset + 8192, Self.payload.count)))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                cancellation.lock(); let stop = stopped; cancellation.unlock()
                if !stop { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
            }
        }
    }
    override func stopLoading() { cancellation.lock(); stopped = true; cancellation.unlock() }
}

enum DownloadRetryChecks {
    @MainActor static func run(root: URL) async throws {
        let controller = DownloadController(directory: root.appendingPathComponent("retry-state"))
        controller.transferProtocolClasses = [DownloadRetryFixture.self]; controller.retryDelays = [0.1, 0.1]
        controller.chooseDestination(root.appendingPathComponent("retry-library").path)
        defer { controller.pauseAll() }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw LaunchError.message("Retry fixture timed out")
        }
        func add(_ name: String) -> ModelDownload {
            controller.beginImport(); controller.token = "hf_retry_fixture"
            let file = RemoteFile(path: "model.gguf", url: URL(string: "https://huggingface.co/retry-fixture/\(name)/model.gguf")!, bytes: Int64(DownloadRetryFixture.payload.count), sha256: DownloadTaskChecks.hash(DownloadRetryFixture.payload))
            controller.listing = .init(site: .huggingface, repository: "retry-fixture/" + name, revision: String(repeating: "f", count: 40), files: [file]); controller.selected = [file.path]; controller.createJob()
            return controller.jobs.first { $0.id == controller.selectedTaskID }!
        }
        let recovered = add("recover"); controller.beginImport()
        try await wait { !controller.hasPendingWork }
        let captures = DownloadRetryFixture.requests(recovered.files[0].url.path)
        try ConnectionChecks.require(controller.jobs.first { $0.id == recovered.id }?.state == .complete && captures.count == 2 && captures[1].range == "bytes=8192-" && captures.allSatisfy { $0.token == "Bearer hf_retry_fixture" }, "Transient retry lost partial bytes, task credential, or retried unnecessarily (requests: \(captures.count), ranges: \(captures.map { $0.range ?? "none" }))")
        let downloaded = try Data(contentsOf: URL(fileURLWithPath: recovered.displayLocation).appendingPathComponent("model.gguf"))
        try ConnectionChecks.require(downloaded == DownloadRetryFixture.payload && controller.retryStatuses.isEmpty, "Retried file content changed or retry indicator remained")

        let exhausted = add("exhausted")
        try await wait { !controller.hasPendingWork }
        let failed = controller.jobs.first { $0.id == exhausted.id }!
        try ConnectionChecks.require(failed.state == .failed && failed.received == 3 * 8192 && DownloadRetryFixture.requests(exhausted.files[0].url.path).count == 3, "Retry budget was not bounded or progress was discarded")

        controller.retryDelays = [2]
        let paused = add("paused")
        try await wait { controller.retryStatuses[paused.id] != nil }
        let before = ProcessInfo.processInfo.systemUptime; controller.pause(paused.id)
        try await wait { !controller.isActive(paused.id) }
        try ConnectionChecks.require(ProcessInfo.processInfo.systemUptime - before < 1 && controller.jobs.first { $0.id == paused.id }?.state == .paused && DownloadRetryFixture.requests(paused.files[0].url.path).count == 1 && controller.retryStatuses[paused.id] == nil, "Pause did not cancel retry backoff promptly")

        let filePaused = add("file-paused")
        try await wait { controller.retryStatuses[filePaused.id] != nil }
        controller.pauseFile(filePaused.id, path: "model.gguf")
        try await wait { !controller.hasPendingWork }
        try ConnectionChecks.require(controller.jobs.first { $0.id == filePaused.id }?.pausedFiles == ["model.gguf"] && DownloadRetryFixture.requests(filePaused.files[0].url.path).count == 1, "Pausing a file during retry still reconnected")

        for name in ["auth", "certificate"] {
            let job = add(name)
            try await wait { !controller.hasPendingWork }
            try ConnectionChecks.require(controller.jobs.first { $0.id == job.id }?.state == .failed && DownloadRetryFixture.requests(job.files[0].url.path).count == 1, "Authentication or TLS failures were automatically retried")
        }
        print("DOWNLOAD RETRY CHECKS PASSED (bounded retries, retained Range/token, pause during backoff, no auth/TLS retry)")
    }
}
