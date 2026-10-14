import Foundation
import CryptoKit

final class DownloadHTTPFixture: URLProtocol {
    static let payload = ModalityChecks.gguf([:]) + Data(repeating: 7, count: 512 * 1024)
    static let config = Data("{\"fixture\":true}".utf8)
    private static let requestLock = NSLock()
    private static var captured: [(String, String?)] = []
    private let cancellation = NSLock()
    private var stopped = false
    static func requests() -> [(String, String?)] { requestLock.lock(); defer { requestLock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "download-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        let range = request.value(forHTTPHeaderField: "Range")
        Self.requestLock.lock(); Self.captured.append((path, range)); Self.requestLock.unlock()
        let data = path.hasSuffix("config.json") ? Self.config : Self.payload
        let offset = path.contains("/ignore") ? 0 : Int((range ?? "bytes=0-").dropFirst(6).split(separator: "-").first ?? "0") ?? 0
        var headers = ["Content-Type": "application/octet-stream", "ETag": "\"fixture-v1\""]
        if !path.contains("/unknown") { headers["Content-Length"] = String(data.count - offset) }
        let status = path.contains("/auth") ? 401 : (offset > 0 ? 206 : 200)
        if offset > 0 { headers["Content-Range"] = "bytes \(offset)-\(data.count - 1)/\(data.count)" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 401 { client?.urlProtocolDidFinishLoading(self); return }
        DispatchQueue.global().async { [self] in
            for start in stride(from: offset, to: data.count, by: 8192) {
                cancellation.lock(); let stop = stopped; cancellation.unlock(); if stop { return }
                client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + 8192, data.count)))
                if !path.hasSuffix("config.json") { Thread.sleep(forTimeInterval: 0.05) }
            }
            cancellation.lock(); let stop = stopped; cancellation.unlock()
            if !stop { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { cancellation.lock(); stopped = true; cancellation.unlock() }
}

enum DownloadTaskChecks {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        let fm = FileManager.default, controller = store.downloads
        try ConnectionFiles.privateDirectory(root)
        controller.transferProtocolClasses = [DownloadHTTPFixture.self]
        let library = root.appendingPathComponent("library")
        controller.destination = library.path
        let config = RemoteFile(path: "config.json", url: URL(string: "https://download-fixture.invalid/range/config.json")!, bytes: Int64(DownloadHTTPFixture.config.count), sha256: hash(DownloadHTTPFixture.config))
        func weight(_ endpoint: String, unknown: Bool = false) -> RemoteFile {
            .init(path: "model.gguf", url: URL(string: "https://download-fixture.invalid/\(endpoint)/model.gguf")!, bytes: unknown ? 0 : Int64(DownloadHTTPFixture.payload.count), sha256: hash(DownloadHTTPFixture.payload))
        }
        func listing(_ endpoint: String) -> RemoteListing {
            var files = [config, weight(endpoint)]
            if endpoint == "range" { var later = weight(endpoint); later.path = "next-model.gguf"; later.url = URL(string: "https://download-fixture.invalid/range/next-model.gguf")!; files.append(later) }
            return .init(site: .huggingface, repository: "fixture/\(endpoint)", revision: String(repeating: "a", count: 40), files: files)
        }
        func seed(_ endpoint: String) throws -> ModelDownload {
            let remote = listing(endpoint)
            var job = ModelDownload(site: remote.site, repository: remote.repository, revision: remote.revision, root: library.path, folder: DownloadRecovery.folder(listing: remote, recovery: false), files: remote.files)
            let folder = library.appendingPathComponent(job.folder); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try DownloadHTTPFixture.config.write(to: folder.appendingPathComponent(config.path))
            let partial = folder.appendingPathComponent("model.gguf.incomplete")
            try DownloadHTTPFixture.payload.prefix(8192).write(to: partial)
            try JSONEncoder().encode(TransferReceipt(url: weight(endpoint).url, etag: "\"fixture-v1\"", total: Int64(DownloadHTTPFixture.payload.count))).write(to: partial.appendingPathExtension("metadata.json"))
            job.finished = [config.path, "missing-legacy-file"]; job.received = 1; job.currentFile = "model.gguf"
            return job
        }
        func wait(_ predicate: () -> Bool, iterations: Int = 500) async throws {
            for _ in 0..<iterations { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw LaunchError.message("Download fixture timed out")
        }
        defer { controller.pause() }

        var old = try seed("range"); old.received = 8000
        var duplicate = old; duplicate.id = UUID().uuidString; duplicate.received = 1
        controller.jobs = [duplicate, old]; controller.listing = listing("range"); controller.selected = Set(old.files.map(\.path))
        controller.save()
        let restored = DownloadController(directory: controllerState(controller))
        try ConnectionChecks.require(restored.jobs.allSatisfy { $0.received == 8192 + config.bytes && !$0.finished.contains("missing-legacy-file") }, "Reopened tasks did not recover disk progress")
        var sharedBlocked = false; do { try controller.cleanPartials(duplicate.id) } catch { sharedBlocked = true }
        try ConnectionChecks.require(sharedBlocked, "Shared incomplete file could be deleted")
        controller.createJob()
        try ConnectionChecks.require(controller.activeID == old.id && controller.jobs.count == 2, "Paused task was not reused")
        controller.createJob(); try ConnectionChecks.require(controller.jobs.count == 2, "Active task created a duplicate")
        store.tab = .downloads
        try await wait { (controller.speeds[old.id] ?? 0) > 0 }
        try ConnectionChecks.require(controller.jobs.first(where: { $0.id == duplicate.id })?.received == controller.jobs.first(where: { $0.id == old.id })?.received, "Shared tasks showed stale file progress")
        let current = controller.jobs.first { $0.id == old.id }!
        let progress = controller.fileProgress(in: current)
        try ConnectionChecks.require(progress.first { $0.id == config.path }?.state == .complete &&
                                     progress.first { $0.id == "model.gguf" }?.state == .downloading &&
                                     progress.first { $0.id == "next-model.gguf" }?.state == .notStarted, "Files did not distinguish complete/downloading/not started")
        try ConnectionChecks.require((progress.first { $0.id == "model.gguf" }?.speed ?? 0) > 0 &&
                                     progress.first { $0.id == "model.gguf" }?.received == current.fileReceived?["model.gguf"], "File speed or byte count was incorrect")
        controller.transferPhases[old.id] = .verifying
        let checking = controller.fileProgress(weight("range"), in: current)
        try ConnectionChecks.require(checking.state == .checking && checking.speed == nil, "Verification was misreported as download/completion")
        controller.transferPhases[old.id] = .downloading
        try await capture?("downloads-progress-speed")
        try await capture?("statusbar-download-progress")

        let competitorState = root.appendingPathComponent("competitor"); try ConnectionFiles.privateDirectory(competitorState)
        let competitor = DownloadController(directory: competitorState); competitor.transferProtocolClasses = [DownloadHTTPFixture.self]
        var competing = old; competing.id = UUID().uuidString
        competitor.jobs = [competing]; competitor.resume(competing.id)
        try await wait { competitor.activeID == nil }
        try ConnectionChecks.require(competitor.jobs.count == 1 && competitor.jobs[0].error?.contains("另一个任务") == true, "Same-location writer was not blocked")
        try await controller.removeTask(duplicate.id)
        try ConnectionChecks.require(controller.activeID == old.id && controller.jobs.count == 1, "Deleting a different task disturbed the active one")
        controller.pause(); try await wait { controller.activeID == nil }
        let paused = controller.jobs.first { $0.id == old.id }!
        let pausedRow = controller.fileProgress(weight("range"), in: paused)
        try ConnectionChecks.require(pausedRow.state == .paused && pausedRow.received > 0 && pausedRow.speed == nil, "Paused file lost its progress or kept an old speed")
        try await capture?("downloads-files-paused")
        controller.resume(old.id)
        try await wait { controller.activeID == nil }
        guard let complete = controller.jobs.first else { throw LaunchError.message("Completed task disappeared") }
        try ConnectionChecks.require(complete.id == old.id && complete.state == .complete && complete.percentage == 100 && controller.speeds[old.id] == nil, "Completion/percentage/speed reset incorrect")
        try ConnectionChecks.require(controller.fileProgress(in: complete).allSatisfy { $0.state == .complete && $0.percentage == 100 && $0.received == $0.file.bytes }, "Completed file list was inaccurate")
        try await capture?("downloads-files-complete")
        let target = library.appendingPathComponent(complete.folder).appendingPathComponent("model.gguf")
        let downloaded = try Data(contentsOf: target)
        try ConnectionChecks.require(downloaded == DownloadHTTPFixture.payload && DownloadHTTPFixture.requests().contains { $0.0 == "/range/model.gguf" && $0.1 == "bytes=8192-" }, "Range continuation did not preserve the model")
        try await controller.removeTask(old.id)
        try ConnectionChecks.require(fm.fileExists(atPath: target.path), "Deleting completed task removed the model")

        let original = try seed("ignore"); controller.jobs = [original]; controller.listing = listing("ignore"); controller.selected = Set(original.files.map(\.path))
        controller.createJob(); try await wait { controller.activeID == nil }
        guard let replacement = controller.jobs.first(where: { $0.replacementOf == original.id }) else { throw LaunchError.message("Cannot-resume task did not get an isolated replacement") }
        let preserved = try Data(contentsOf: library.appendingPathComponent(original.folder).appendingPathComponent("model.gguf.incomplete"))
        try ConnectionChecks.require(replacement.state == .complete && replacement.folder != original.folder && preserved == DownloadHTTPFixture.payload.prefix(8192), "Restart overwrote original fragments or failed")

        let authorization = try seed("auth"); controller.jobs = [authorization]; controller.listing = listing("auth"); controller.selected = Set(authorization.files.map(\.path))
        controller.createJob(); try await wait { controller.activeID == nil }
        try ConnectionChecks.require(controller.jobs.count == 1 && controller.jobs[0].state == .failed && controller.jobs[0].resumeBlockedReason == nil, "Authentication failure discarded a resumable task")
        try ConnectionChecks.require(controller.fileProgress(weight("auth"), in: controller.jobs[0]).state == .failed, "Failed file was not marked for retry")
        try await capture?("downloads-files-failed")

        let separate = try seed("range"); controller.jobs = [separate]; controller.listing = listing("range"); controller.selected = Set(separate.files.map(\.path))
        let differentRoot = root.appendingPathComponent("other-library"); controller.destination = differentRoot.path
        controller.createJob(); guard let running = controller.activeID else { throw LaunchError.message("Different-location job not created") }
        try ConnectionChecks.require(running != separate.id && controller.jobs.first { $0.id == running }?.root == differentRoot.path, "Different download position reused wrong task")
        try await wait { (controller.jobs.first { $0.id == running }?.received ?? 0) > 8192 }
        try await controller.removeTask(running)
        try ConnectionChecks.require(controller.activeID == nil && !controller.jobs.contains { $0.id == running } && controller.speedLabel(running) == "—", "Active task deletion did not stop and remove it")
        let partial = differentRoot.appendingPathComponent(DownloadRecovery.folder(listing: listing("range"), recovery: false)).appendingPathComponent("model.gguf.incomplete")
        try ConnectionChecks.require(fm.fileExists(atPath: partial.path), "Active task deletion erased its progress")

        let unknown = RemoteListing(site: .direct, repository: "download-fixture.invalid", revision: "direct", files: [weight("unknown", unknown: true)])
        controller.destination = root.appendingPathComponent("unknown").path; controller.listing = unknown; controller.selected = ["model.gguf"]; controller.createJob()
        guard let unknownID = controller.activeID else { throw LaunchError.message("Unknown-size task not started") }
        try await wait { (controller.jobs.first { $0.id == unknownID }?.received ?? 0) > 8192 }
        try ConnectionChecks.require(controller.jobs.first { $0.id == unknownID }?.percentage == nil, "Unknown total fabricated a percentage")
        try await capture?("downloads-unknown-total")
        try await wait { controller.activeID == nil }
        try ConnectionChecks.require(controller.jobs.first { $0.id == unknownID }?.percentage == 100, "Unknown-size completion did not learn total")
        var rate = DownloadRate()
        _ = rate.record(bytes: 0, at: 0); let speed = rate.record(bytes: 12000, at: 1)
        _ = rate.record(bytes: 12000, at: 4); let idle = rate.record(bytes: 12000, at: 5)
        try ConnectionChecks.require(speed == 12000 && idle == 0, "Rolling speed did not decay after no traffic")
        try await fileControls(controller: controller, root: root, files: listing("range").files, capture: capture)
        let report: [String: Any] = ["result": "passed", "checks": ["paused task priority and duplicate prevention", "disk progress and finished-file reconciliation", "real Range request and SHA-verified output", "visible speed and task percentage", "per-file bytes, speed, completion and pending state", "per-file verification, pause and retry states", "active and queued file pause", "other files continue with paused prefix preserved", "paused file preferences survive reopening", "priority switches files then resumes original Range", "partial model not imported until all files finish", "isolated fallback preserves original partial", "auth failures keep original task", "same-location exclusive writer", "different destination creates independent task", "shared partial cleanup blocked", "deleting another task preserves active transfer", "active deletion stops and keeps fragments", "completed deletion keeps model", "unknown total and idle speed handled", "status bar download management"], "realModelDownloads": false]
        try ConnectionFiles.json(report).write(to: root.appendingPathComponent("result.json")); print(String(decoding: try ConnectionFiles.json(report), as: UTF8.self))
    }
    @MainActor static func fileControls(controller: DownloadController, root: URL, files: [RemoteFile], capture: ((String) async throws -> Void)?) async throws {
        let previousImport = controller.onImported
        var imported: [String] = []
        controller.onImported = { imported.append($0) }
        defer { controller.onImported = previousImport }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<500 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw LaunchError.message("File controls timed out")
        }
        func seeded(_ name: String) throws -> ModelDownload {
            let library = root.appendingPathComponent(name)
            let listing = RemoteListing(site: .huggingface, repository: "fixture/controls", revision: String(repeating: "d", count: 40), files: files)
            var job = ModelDownload(site: listing.site, repository: listing.repository, revision: listing.revision, root: library.path, folder: DownloadRecovery.folder(listing: listing, recovery: false), files: files)
            let folder = library.appendingPathComponent(job.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DownloadHTTPFixture.config.write(to: folder.appendingPathComponent("config.json"))
            job.finished = ["config.json"]
            try DownloadHTTPFixture.payload.prefix(8192).write(to: folder.appendingPathComponent("model.gguf.incomplete"))
            let receipt = TransferReceipt(url: files.first { $0.path == "model.gguf" }!.url, etag: "\"fixture-v1\"", total: Int64(DownloadHTTPFixture.payload.count))
            try JSONEncoder().encode(receipt).write(to: folder.appendingPathComponent("model.gguf.incomplete.metadata.json"))
            return job
        }
        let job = try seeded("per-file-library")
        controller.jobs = [job]; controller.pauseFile(job.id, path: "next-model.gguf"); controller.resume(job.id)
        try await wait { (controller.jobs.first?.fileReceived?["model.gguf"] ?? 0) > 49152 }
        controller.pauseFile(job.id, path: "model.gguf")
        try await wait { controller.activeID == nil }
        let paused = controller.jobs[0]
        let partial = URL(fileURLWithPath: job.root).appendingPathComponent(job.folder).appendingPathComponent("model.gguf.incomplete")
        let pausedBytes = try Data(contentsOf: partial)
        try ConnectionChecks.require(paused.state == .paused && paused.finished == ["config.json"] && imported.isEmpty &&
                                     controller.fileProgress(in: paused).filter { $0.state == .paused }.count == 2, "Individual file pause completed/imported the model")
        let reopened = DownloadController(directory: controller.directory)
        try ConnectionChecks.require(reopened.jobs.first?.pausedFiles == ["model.gguf", "next-model.gguf"] &&
                                     reopened.jobs.first?.fileReceived?["model.gguf"] == Int64(pausedBytes.count), "File pause settings did not survive reopening")
        try await capture?("downloads-files-individually-paused")
        controller.resumeFile(job.id, path: "next-model.gguf", first: true)
        try await wait { controller.jobs.first?.currentFile == "next-model.gguf" && (controller.jobs.first?.fileReceived?["next-model.gguf"] ?? 0) > 8192 }
        let preservedBeforeOther = try Data(contentsOf: partial)
        try ConnectionChecks.require(controller.fileProgress(files.first { $0.path == "model.gguf" }!, in: controller.jobs[0]).state == .paused &&
                                     preservedBeforeOther == pausedBytes && imported.isEmpty, "Downloading another file changed paused data")
        try await capture?("downloads-file-other-first")
        try await wait { controller.activeID == nil }
        let afterOther = try Data(contentsOf: partial)
        try ConnectionChecks.require(controller.jobs[0].state == .paused && controller.jobs[0].finished.contains("next-model.gguf") &&
                                     !controller.jobs[0].finished.contains("model.gguf") && afterOther == pausedBytes && imported.isEmpty, "Other file did not complete independently")
        controller.resumeFile(job.id, path: "model.gguf")
        try await wait { controller.activeID == nil }
        let final = partial.deletingPathExtension()
        let finalBytes = try Data(contentsOf: final)
        try ConnectionChecks.require(controller.jobs.count == 1 && controller.jobs[0].state == .complete && imported.count == 1 &&
                                     finalBytes == DownloadHTTPFixture.payload, "Paused file did not resume and import the complete model")

        let priority = try seeded("priority-file-library")
        controller.jobs = [priority]; let requestStart = DownloadHTTPFixture.requests().count
        controller.resume(priority.id)
        try await wait { (controller.jobs.first?.fileReceived?["model.gguf"] ?? 0) > 49152 }
        controller.resumeFile(priority.id, path: "next-model.gguf", first: true)
        try await wait { controller.jobs.first?.currentFile == "next-model.gguf" && (controller.jobs.first?.fileReceived?["next-model.gguf"] ?? 0) > 8192 }
        try ConnectionChecks.require(controller.jobs.count == 1 && (controller.jobs[0].fileReceived?["model.gguf"] ?? 0) > 0 &&
                                     !controller.jobs[0].finished.contains("model.gguf") && (controller.jobs[0].pausedFiles ?? []).isEmpty, "Priority switching lost the original file or paused it permanently")
        try await capture?("downloads-file-priority-switch")
        try await wait { controller.activeID == nil }
        let requests = Array(DownloadHTTPFixture.requests().dropFirst(requestStart))
        try ConnectionChecks.require(controller.jobs[0].state == .complete && imported.count == 2 &&
                                     requests.filter { $0.0 == "/range/model.gguf" }.count == 2 &&
                                     requests.last?.0 == "/range/model.gguf" && requests.last?.1 != nil, "Prioritized file did not finish before original continuation")
    }
    // State directory is intentionally supplied by the test caller.
    @MainActor static func controllerState(_ controller: DownloadController) -> URL { controller.directory }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/download-task-checks").appendingPathComponent(UUID().uuidString)
        let state = root.appendingPathComponent("state"); try ConnectionFiles.privateDirectory(state)
        try await exercise(store: AppStore(stateDirectory: state), root: root)
        print("Evidence: \(root.path)")
    }
}
