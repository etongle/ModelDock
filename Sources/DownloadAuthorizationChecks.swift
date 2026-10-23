import Foundation
import CryptoKit

final class DownloadAuthorizationFixture: URLProtocol {
    static let payload = ModalityChecks.gguf([:]) + Data(repeating: 79, count: 256 * 1024)
    static let lock = NSLock()
    static var captures: [(String?, String?)] = []
    static func requests() -> [(String?, String?)] { lock.lock(); defer { lock.unlock() }; return captures }
    private let cancellation = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" && request.url?.path.hasPrefix("/authorization-fixture/") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization"), range = request.value(forHTTPHeaderField: "Range")
        Self.lock.lock(); Self.captures.append((auth, range)); Self.lock.unlock()
        guard auth == "Bearer hf_fixture_download" else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocolDidFinishLoading(self); return
        }
        let offset = Int((range ?? "bytes=0-").dropFirst(6).split(separator: "-").first ?? "0") ?? 0
        var headers = ["Content-Type": "application/octet-stream", "Content-Length": String(Self.payload.count - offset), "ETag": "fixture-auth"]
        if offset > 0 { headers["Content-Range"] = "bytes \(offset)-\(Self.payload.count - 1)/\(Self.payload.count)" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: offset > 0 ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            for start in stride(from: offset, to: Self.payload.count, by: 8192) {
                cancellation.lock(); let stop = stopped; cancellation.unlock(); if stop { return }
                client?.urlProtocol(self, didLoad: Self.payload.subdata(in: start..<min(start + 8192, Self.payload.count)))
                Thread.sleep(forTimeInterval: 0.03)
            }
            cancellation.lock(); let stop = stopped; cancellation.unlock()
            if !stop { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { cancellation.lock(); stopped = true; cancellation.unlock() }
}

enum DownloadAuthorizationChecks {
    @MainActor static func run(root: URL) async throws {
        let controller = DownloadController(directory: root.appendingPathComponent("authorization-state"))
        controller.transferProtocolClasses = [DownloadAuthorizationFixture.self]
        defer { controller.pauseAll() }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw LaunchError.message("Authorization fixture timed out")
        }
        let file = RemoteFile(path: "model.gguf", url: URL(string: "https://huggingface.co/authorization-fixture/model/resolve/main/model.gguf")!, bytes: Int64(DownloadAuthorizationFixture.payload.count), sha256: DownloadTaskChecks.hash(DownloadAuthorizationFixture.payload))
        var job = ModelDownload(site: .huggingface, repository: "authorization-fixture/model", revision: String(repeating: "a", count: 40), root: root.appendingPathComponent("authorization-library").path, folder: "models--authorization-fixture--model/snapshots/" + String(repeating: "a", count: 40), files: [file])
        let folder = URL(fileURLWithPath: job.displayLocation); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("model.gguf.incomplete")
        try DownloadAuthorizationFixture.payload.prefix(8192).write(to: partial)
        try JSONEncoder().encode(TransferReceipt(url: file.url, etag: "fixture-auth", total: file.bytes)).write(to: partial.appendingPathExtension("metadata.json"))
        job.state = .failed; job.received = 8192; job.error = "下载失败（HTTP 401），未完成文件已保留"
        controller.jobs = [job]; controller.save(); controller.resume(job.id)
        try ConnectionChecks.require(controller.authorization?.job.id == job.id && !controller.hasPendingWork, "Legacy 401 did not open credential recovery")
        let draft = controller.authorization!; draft.token = "hf_fixture_download"
        controller.authorizeAndResume(draft)
        try ConnectionChecks.require(controller.authorization == nil && draft.token.isEmpty && controller.jobs.count == 1, "Credential submission created a task or retained the form secret")
        try await wait { (controller.jobs.first?.received ?? 0) > 8192 }
        controller.pause(job.id); try await wait { !controller.isActive(job.id) }
        let retained = try Data(contentsOf: partial)
        controller.beginImport(); controller.token = "unrelated-form-token"
        controller.resume(job.id); try await wait { !controller.hasPendingWork }
        let complete = controller.jobs.first!
        try ConnectionChecks.require(complete.id == job.id && complete.state == .complete && complete.received == file.bytes && complete.finished == [file.path], "Authorized resume did not finish the same task")
        let downloaded = try Data(contentsOf: folder.appendingPathComponent(file.path))
        try ConnectionChecks.require(downloaded == DownloadAuthorizationFixture.payload && downloaded.prefix(retained.count) == retained, "Authorization recovery discarded partial bytes")
        let requests = DownloadAuthorizationFixture.requests()
        try ConnectionChecks.require(requests.count >= 2 && requests.allSatisfy { $0.0 == "Bearer hf_fixture_download" && $0.1 != nil && $0.1 != "bytes=0-" }, "Resume lost the task token or restarted at zero")
        let serialized = String(decoding: try Data(contentsOf: controller.directory.appendingPathComponent("downloads.json")), as: UTF8.self)
        try ConnectionChecks.require(!serialized.contains("hf_fixture_download") && !serialized.contains("unrelated-form-token"), "A credential was persisted")
        var second = job; second.id = UUID().uuidString; second.folder += "-other"; second.error = nil; second.authorizationStatus = nil; second.state = .paused; second.received = 0
        controller.jobs.append(second); controller.resume(second.id); try await wait { !controller.hasPendingWork }
        try ConnectionChecks.require(controller.jobs.first { $0.id == second.id }?.authorizationStatus == 401, "Task authorization leaked to another job or 401 was not classified")
        let restored = DownloadController(directory: controller.directory)
        restored.resume(second.id)
        try ConnectionChecks.require(restored.authorization?.job.id == second.id, "Authorization recovery did not survive reopening")
        let cache = root.appendingPathComponent("credential-fixture")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let tokenFile = cache.appendingPathComponent("token"); try Data("hf_cached_fixture\n".utf8).write(to: tokenFile)
        try ConnectionChecks.require(HuggingFaceCredential.read(environment: ["HF_TOKEN_PATH": tokenFile.path], home: root) == "hf_cached_fixture" && HuggingFaceCredential.read(environment: ["HF_TOKEN_PATH": tokenFile.path, "HF_TOKEN": "hf_env_fixture"], home: root) == "hf_env_fixture", "Local HF token source or environment priority failed")
        print("DOWNLOAD AUTHORIZATION CHECKS PASSED (token and nonzero Range retained; no credential persistence)")
    }
}
