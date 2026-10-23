import AppKit
import Foundation
import CryptoKit

/// Exercises real asynchronous, cancellable transfers against an in-memory HTTP server.
enum DownloadQueueChecks {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-download-queue").appendingPathComponent(UUID().uuidString)
        let controller = DownloadController(directory: root.appendingPathComponent("state"))
        controller.transferProtocolClasses = [DownloadHTTPFixture.self]
        controller.chooseDestination(root.appendingPathComponent("library").path)
        var checks: [String] = []
        func require(_ condition: Bool, _ message: String) throws { try ConnectionChecks.require(condition, message) }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<700 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw LaunchError.message("Queue fixture timed out")
        }
        func listing(_ name: String, endpoint: String = "range") -> RemoteListing {
            .init(site: .huggingface, repository: "queue/" + name, revision: String(repeating: "b", count: 40), files: [.init(path: "model.gguf", url: URL(string: "https://download-fixture.invalid/\(endpoint)/\(name)/model.gguf")!, bytes: Int64(DownloadHTTPFixture.payload.count), sha256: DownloadTaskChecks.hash(DownloadHTTPFixture.payload))])
        }
        @discardableResult func add(_ name: String, endpoint: String = "range") -> String {
            controller.beginImport(); controller.listing = listing(name, endpoint: endpoint); controller.selected = ["model.gguf"]; controller.createJob()
            return controller.selectedTaskID!
        }
        defer { controller.pauseAll() }
        let a = add("first"), b = add("second"), c = add("third")
        try require(controller.activeIDs == Set([a, b]) && controller.jobs.first { $0.id == c }?.state == .queued, "Default concurrency or FIFO queue failed")
        controller.listing = listing("third"); controller.selected = ["model.gguf"]; controller.createJob()
        try require(controller.jobs.count == 3 && controller.selectedTaskID == c, "Queued duplicate was created")
        controller.maximumConcurrentDownloads = 3
        try require(controller.activeIDs.count == 3, "Raising concurrency did not start queued job")
        controller.maximumConcurrentDownloads = 1
        try require(controller.activeIDs.count == 3, "Lowering concurrency interrupted existing jobs")
        try await wait { controller.activeIDs.allSatisfy { (controller.speeds[$0] ?? 0) > 0 } }
        try require(controller.activeIDs.count == 3 && controller.jobs.filter { controller.isActive($0.id) }.allSatisfy { $0.received > 0 }, "Parallel jobs did not have independent progress and speed")
        try require(controller.remainingTimeLabel(controller.jobs.first { $0.id == a }!).contains("剩余") || L10n.current != .chinese, "ETA not available while receiving bytes")
        let savedDestination = controller.destination
        controller.address = "old"; controller.token = "do-not-persist"; controller.notice = "old"; controller.message = "old"
        controller.beginImport()
        try require(controller.address.isEmpty && controller.token.isEmpty && controller.listing == nil && controller.selected.isEmpty && controller.message == nil && controller.notice == nil && controller.selectedTaskID == nil && controller.destination == savedDestination && controller.activeIDs.count == 3, "New import retained old state or interrupted downloads")
        controller.showTask(a)
        try require(controller.address.isEmpty && controller.listing == nil && controller.destination == savedDestination, "Selecting a task contaminated the import form")
        controller.pause(a)
        try await wait { !controller.isActive(a) }
        try require(controller.isActive(b) && controller.isActive(c) && controller.jobs.first { $0.id == a }?.state == .paused, "Per-task pause stopped other downloads")
        try await controller.removeTask(a)
        try require(controller.isActive(b) && controller.isActive(c) && !controller.jobs.contains { $0.id == a }, "Removing paused task affected active tasks")
        try await wait { !controller.hasPendingWork }
        try require(controller.jobs.allSatisfy { $0.state == .complete }, "Concurrent models did not complete")
        checks.append("Parallel independent progress/rates; FIFO limit; limit changes; duplicate reuse; pause/delete isolation; fresh import")

        controller.maximumConcurrentDownloads = 1
        let d = add("fourth"), e = add("fifth")
        controller.pause(e)
        try require(controller.jobs.first { $0.id == e }?.state == .paused && controller.queuedCount == 0 && controller.isActive(d), "Queued pause affected active download")
        controller.resume(e)
        try require(controller.jobs.first { $0.id == e }?.state == .queued, "Resume did not enqueue")
        let restored = DownloadController(directory: controller.directory)
        try require(restored.maximumConcurrentDownloads == 1 && restored.destination == savedDestination && restored.jobs.allSatisfy { $0.state != .downloading && $0.state != .queued }, "Preferences or safe paused restoration failed")
        controller.maximumConcurrentDownloads = 2
        try await wait { !controller.hasPendingWork }
        checks.append("Queued pause/resume, persisted concurrency/library, reopening pauses pending work")

        let f = add("shared")
        var shared = controller.jobs.first { $0.id == f }!; shared.id = UUID().uuidString
        shared.files[0].path = "other.gguf"; shared.finished = []; shared.fileReceived = [:]; shared.received = 0; shared.state = .paused
        controller.jobs.append(shared); controller.resume(shared.id)
        let g = add("independent")
        try require(controller.isActive(f) && controller.isActive(g) && !controller.isActive(shared.id) && controller.jobs.first { $0.id == shared.id }?.state == .queued, "Shared folder was not serialized or blocked unrelated work")
        var cleanupBlocked = false; do { try controller.cleanPartials(shared.id) } catch { cleanupBlocked = true }
        try require(cleanupBlocked && controller.hasWriter(affecting: shared.displayLocation), "Queued/shared directory cleanup protection failed")
        try await wait { !controller.hasPendingWork }
        try require(controller.jobs.first { $0.id == shared.id }?.state == .complete, "Shared folder job did not start after writer completed")
        let receipt = URL(fileURLWithPath: shared.displayLocation).appendingPathComponent("model-manager-source.json")
        let origin = try JSONDecoder().decode(ModelOrigin.self, from: Data(contentsOf: receipt))
        try require(Set(origin.files) == ["model.gguf", "other.gguf"], "Concurrent subset imports lost origin metadata")
        checks.append("Same destination serialized, other folders proceed, cleanup blocked, origin file sets merged")

        let failed = add("unauthorized", endpoint: "auth"), good = add("survivor")
        try await wait { !controller.hasPendingWork }
        try require(controller.jobs.first { $0.id == failed }?.state == .failed && controller.jobs.first { $0.id == good }?.state == .complete, "Failure stopped unrelated download")
        checks.append("One task failing does not interrupt other models")

        controller.catalogLoader = { _, _ in
            try? await Task.sleep(nanoseconds: 250_000_000)
            throw LaunchError.message("stale-resolution-error")
        }
        controller.address = "https://github.com/fixture/model"; controller.resolve(); controller.beginImport()
        try await Task.sleep(nanoseconds: 400_000_000)
        try require(controller.message == nil && controller.listing == nil && !controller.resolving && controller.address.isEmpty, "Canceled catalog request contaminated fresh import")
        try require(DownloadEstimate.seconds(remaining: 100, speed: 10) == 10 && DownloadEstimate.seconds(remaining: 1, speed: 0) == nil && DownloadEstimate.seconds(remaining: 10, speed: .nan) == nil, "ETA edge cases failed")
        checks.append("Stale resolution cancellation; ETA zero/unknown throughput and finite bounds")
        try controller.reserveCleanupPaths([controller.destination])
        let reserved = add("cleanup-reserved")
        try require(controller.jobs.first { $0.id == reserved }?.state == .queued && !controller.isActive(reserved), "Cleanup reservation allowed a new writer")
        controller.releaseCleanupPaths()
        try await wait { !controller.hasPendingWork }
        try require(controller.jobs.first { $0.id == reserved }?.state == .complete, "Releasing cleanup reservation did not resume queued work")
        checks.append("Cleanup reservations prevent concurrent writers and release queued downloads")
        try await credentialChecks(root: root)
        try await DownloadAuthorizationChecks.run(root: root)
        try await DownloadRetryChecks.run(root: root)
        try await DownloadGlobalTokenChecks.run(root: root)
        checks.append("Global HF token scopes to HF HTTPS only; metadata and downloads use fallback; overrides, reopening, 401 resume and token removal verified")
        checks.append("Transient disconnect retries preserve Range/token; retry limit and pause respected; auth/TLS errors require user action")
        checks.append("Queued credentials remain isolated and are never persisted; new import clears token field")
        try await githubChecks()
        checks.append("GitHub pinned repository/file/branch, LFS objects, Release assets/digest, truncated tree and non-model defaults")
        let report: [String: Any] = ["result": "passed", "checks": checks, "fixtures": root.path]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"))
        print("DOWNLOAD QUEUE CHECKS PASSED: \(root.path)")
    }

    @MainActor static func credentialChecks(root: URL) async throws {
        let controller = DownloadController(directory: root.appendingPathComponent("credential-state"))
        controller.maximumConcurrentDownloads = 1; controller.transferProtocolClasses = [DownloadCredentialFixture.self]
        controller.chooseDestination(root.appendingPathComponent("credential-library").path)
        for (name, token) in [("first", "fixture-token-A"), ("second", "fixture-token-B")] {
            controller.beginImport(); controller.token = token
            controller.listing = .init(site: .github, repository: "queue/" + name, revision: String(repeating: "e", count: 40), files: [.init(path: "config.json", url: URL(string: "https://raw.githubusercontent.com/queue/\(name)/config.json")!, bytes: Int64(DownloadCredentialFixture.payload.count))])
            controller.selected = ["config.json"]; controller.createJob()
        }
        controller.beginImport()
        for _ in 0..<300 { if !controller.hasPendingWork { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        defer { controller.pauseAll() }
        let captures = DownloadCredentialFixture.requests()
        try ConnectionChecks.require(controller.jobs.allSatisfy { $0.state == .complete } && captures["/queue/first/config.json"] == "Bearer fixture-token-A" && captures["/queue/second/config.json"] == "Bearer fixture-token-B", "Fresh import changed queued credentials")
        let state = try String(contentsOf: controller.directory.appendingPathComponent("downloads.json"), encoding: .utf8)
        try ConnectionChecks.require(!state.contains("fixture-token-"), "Credentials were persisted in task state")
    }

    static func githubChecks() async throws {
        let sha = String(repeating: "a", count: 40), hash = String(repeating: "c", count: 64)
        let reader: GitHubModels.Reader = { url, _ in
            let path = url.path.removingPercentEncoding ?? url.path
            var payload: [String: Any] = [:], status = 200
            if url.host == "raw.githubusercontent.com" {
                let data = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(hash)\nsize 123456789\n".utf8)
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/git/trees/tree") {
                payload = ["truncated": url.path.contains("truncated"), "tree": [
                    ["type": "blob", "mode": "100644", "path": "weights/model.safetensors", "size": 132],
                    ["type": "blob", "mode": "100644", "path": "weights/config.json", "size": 20],
                    ["type": "blob", "mode": "100644", "path": "setup.py", "size": 200],
                    ["type": "blob", "mode": "120000", "path": "link.gguf", "size": 10],
                    ["type": "blob", "mode": "100644", "path": "../escape.gguf", "size": 10]]]
            } else if path.contains("/commits/") {
                if path.hasSuffix("/commits/main") || path.hasSuffix("/commits/feature/vision") {
                    payload = ["sha": sha, "commit": ["tree": ["sha": "tree"]]]
                } else { status = 404 }
            } else if path.contains("/releases/") {
                payload = ["id": 42, "tag_name": "v1", "assets": [["id": 99, "name": "model.gguf", "size": 888, "digest": "sha256:" + hash]]]
            } else { payload = ["default_branch": "main"] }
            return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let listing = try await GitHubModels.listing(URL(string: "https://github.com/fixture/model")!, token: "", read: reader)
        try ConnectionChecks.require(listing.revision == sha && listing.files.count == 3 && !ModelCatalog.suggested(listing).contains("setup.py"), "GitHub regular model selection failed")
        let file = listing.files.first { $0.path.hasSuffix("safetensors") }!
        try ConnectionChecks.require(file.bytes == 123456789 && file.sha256 == hash && file.url.host == "media.githubusercontent.com" && file.url.path.contains(sha), "Git LFS pointer was not resolved")
        let branch = try await GitHubModels.listing(URL(string: "https://github.com/fixture/model/tree/feature/vision/weights")!, token: "", read: reader)
        try ConnectionChecks.require(branch.files.count == 2 && branch.revision == sha, "Slash branch or subdirectory filter failed")
        let blob = try await GitHubModels.listing(URL(string: "https://raw.githubusercontent.com/fixture/model/main/weights/model.safetensors")!, token: "", read: reader)
        try ConnectionChecks.require(blob.files.count == 1 && blob.preferred == "weights/model.safetensors" && blob.sourceURL?.contains("blob") == true, "Raw/single file selection failed")
        let release = try await GitHubModels.listing(URL(string: "https://github.com/fixture/model/releases/download/v1/model.gguf")!, token: "", read: reader)
        try ConnectionChecks.require(release.files.first?.url.path == "/repos/fixture/model/releases/assets/99" && release.files.first?.sha256 == hash && release.files.first?.accept == "application/octet-stream" && release.revision.hasPrefix("release-42-") && release.sourceURL?.hasSuffix("/releases/tag/v1") == true, "Release stable identity, asset header or digest failed")
        let latestAsset = try await GitHubModels.listing(URL(string: "https://github.com/fixture/model/releases/latest/download/model.gguf")!, token: "", read: reader)
        let slashTag = try await GitHubModels.listing(URL(string: "https://github.com/fixture/model/releases/download/models/v1/model.gguf")!, token: "", read: reader)
        try ConnectionChecks.require(latestAsset.preferred == "model.gguf" && slashTag.preferred == "model.gguf", "Latest asset or slash-tag URL failed")
        var truncated = false
        do { _ = try await GitHubModels.listing(URL(string: "https://github.com/fixture/truncated")!, token: "", read: reader) } catch { truncated = true }
        try ConnectionChecks.require(truncated, "Truncated Git tree accepted")
        try ConnectionChecks.require(ModelCatalog.normalizedAddress("owner/model") == "https://huggingface.co/owner/model", "GitHub support changed bare Hugging Face IDs")
    }
}

extension DownloadQueueChecks {
    static func network() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-github-live").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = ProcessInfo.processInfo.environment["MM_GITHUB_TEST_TOKEN"] ?? ""
        let listing = try await ModelCatalog.listing("https://github.com/etongle/ModelDock/blob/main/Resources/python-runtime.json", token: token)
        guard let config = listing.files.first, config.path == "Resources/python-runtime.json", listing.preferred == config.path, listing.revision.count == 40 else { throw LaunchError.message("Live pinned GitHub file listing failed") }
        let transfer = try DownloadTransfer(file: config, root: root, folder: "repository", token: token) { _, _ in }
        try await transfer.run()
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: transfer.destination))
        let release = try await ModelCatalog.listing("https://github.com/etongle/ModelDock/releases/latest", token: token)
        guard let asset = release.files.first(where: { $0.bytes > 0 && $0.bytes < 1_000_000 && $0.path.hasSuffix(".json") }) else { throw LaunchError.message("No small live Release fixture available") }
        let releaseTransfer = try DownloadTransfer(file: asset, root: root, folder: "release", token: token) { _, _ in }
        try await releaseTransfer.run()
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: releaseTransfer.destination))
        try ConnectionFiles.json(["result": "passed", "repository": listing.repository, "pinnedRevision": listing.revision, "fileBytes": config.bytes, "releaseAsset": asset.path, "releaseSHA256": asset.sha256 ?? "", "heavyModelDownloaded": false]).write(to: root.appendingPathComponent("report.json"))
        print("GITHUB LIVE DOWNLOAD CHECKS PASSED: \(root.path)")
    }
}

@MainActor
enum DownloadQueueScreens {
    static func run(_ app: AppDelegate, folder: URL) async throws {
        guard argumentValue("--state-dir") != nil, let store = app.store, store.services.records.isEmpty else { throw LaunchError.message("Download capture requires isolated state") }
        let downloads = store.downloads
        store.services.polling = true // Freeze synthetic service states; do not probe real ports.
        let files = [RemoteFile(path: "config.json", url: URL(string: "https://example.invalid/config.json")!, bytes: 4_900), RemoteFile(path: "model-00001-of-00002.safetensors", url: URL(string: "https://example.invalid/model-1")!, bytes: 5_000_000_000), RemoteFile(path: "model-00002-of-00002.safetensors", url: URL(string: "https://example.invalid/model-2")!, bytes: 5_000_000_000)]
        var first = ModelDownload(id: "download-one", site: .huggingface, repository: "mlx-community/Qwen3.8-27B-4bit", revision: String(repeating: "a", count: 40), root: "/private/tmp/ModelDock-Demo/Models", folder: "Qwen3.8-27B-4bit", files: files, state: .downloading)
        first.finished = [files[0].path]; first.currentFile = files[1].path; first.fileReceived = [files[0].path: 4900, files[1].path: 2_000_000_000]; first.received = 2_000_004_900
        var second = first; second.id = "download-two"; second.site = .github; second.repository = "example/vision-model"; second.folder = "vision-model"; second.received = 1_000_004_900; second.fileReceived?[files[1].path] = 1_000_000_000
        var queued = first; queued.id = "download-three"; queued.repository = "example/embedding-model"; queued.state = .queued; queued.finished = []; queued.currentFile = ""; queued.received = 0; queued.fileReceived = [:]; queued.folder = "embedding-model"
        downloads.chooseDestination(first.root)
        downloads.jobs = [first, second, queued]; downloads.activeIDs = [first.id, second.id]; downloads.speeds = [first.id: 20_000_000, second.id: 12_000_000]; downloads.transferPhases = [first.id: .downloading, second.id: .downloading]
        let instanceModel = LocalModel(id: "demo-instance-model", name: "Qwen3.8-27B", format: "GGUF Q8_0", path: "/private/tmp/ModelDock-Demo/Models/Qwen3.8-27B.gguf", kind: .language, bytes: 29_980_000_000, complete: true, verification: "文件存在 · GGUF 头部有效", missingFiles: [], removalPath: "/private/tmp/ModelDock-Demo/Models/Qwen3.8-27B.gguf")
        var unusedModel = instanceModel; unusedModel.id = "demo-unused-model"; unusedModel.name = "nomic-embed-text-v1.5"; unusedModel.kind = .embedding; unusedModel.bytes = 84_100_000; unusedModel.path = "/private/tmp/ModelDock-Demo/Models/nomic-embed-text-v1.5.gguf"
        let instanceEngine = Engine(kind: .llama, name: "Llama", version: "0.6.0_1", path: "/opt/modeldock/llama-server", installed: true, canServe: true, installation: "命令行服务", description: "使用 llama.cpp 运行本地 GGUF 模型", defaultPort: 8080, symbol: "bolt.fill")
        store.inventory = .init(engines: [instanceEngine], models: [instanceModel, unusedModel], storageBytes: instanceModel.bytes + unusedModel.bytes, memoryBytes: 137_438_953_472, chip: "Apple Silicon", roots: [first.root], warnings: [], scannedAt: Date())
        store.engineID = "llama"; store.selectedModels["llama"] = instanceModel.id; store.selectedFileID = instanceModel.id
        let running = ServiceSpec(id: "demo-instance-running", engineID: "llama", modelID: instanceModel.id, modelName: instanceModel.name, modelPath: instanceModel.path, port: 8080, pid: 900001)
        let stopped = ServiceSpec(id: "demo-instance-stopped", engineID: "llama", modelID: instanceModel.id, modelName: instanceModel.name, modelPath: instanceModel.path, port: 8082)
        store.services.records = [running, stopped]; store.services.statuses = [running.id: .running, stopped.id: .stopped]
        for language in [AppLanguage.english, .chinese, .french, .portuguese] {
            store.language = language; store.tab = .downloads; downloads.selectedTaskID = first.id
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-parallel-downloads", folder: folder)
            downloads.beginImport()
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-fresh-import", folder: folder)
            downloads.address = "https://github.com/example/vision-model/releases/latest"
            downloads.listing = .init(site: .github, repository: second.repository, revision: "release-demo", files: files, sourceURL: downloads.address)
            downloads.selected = Set(files.map(\.path))
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-github-import", folder: folder)
            store.settingsTab = 3; app.showSettings()
            try await Task.sleep(nanoseconds: 350_000_000)
            if let content = app.settingsWindow?.contentView { try app.captureView(content, name: language.rawValue + "-download-settings", folder: folder) }
            app.settingsWindow?.orderOut(nil)
            store.tab = .engines; store.engineSection = .configuration; store.engineInstanceFilter = nil
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-model-instances", folder: folder)
            store.showModelInstances(instanceModel, engineID: "llama")
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-model-instance-navigation", folder: folder)
            store.tab = .models
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-model-instance-files", folder: folder)
        }
        downloads.activeIDs = []; store.services.records = []; store.services.statuses = [:]; store.language = .english
        try ConnectionFiles.json(["result": "passed", "syntheticDemo": true, "realDownloadsModified": false]).write(to: folder.appendingPathComponent("result.json"))
        if CommandLine.arguments.contains("--capture-only") { NSApplication.shared.terminate(nil) }
    }
}

final class DownloadCredentialFixture: URLProtocol {
    static let payload = Data("{\"model_type\":\"fixture\"}".utf8)
    private static let lock = NSLock()
    private static var captured: [String: String] = [:]
    static func requests() -> [String: String] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "raw.githubusercontent.com" && request.url?.path.hasPrefix("/queue/") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured[request.url!.path] = request.value(forHTTPHeaderField: "Authorization"); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": String(Self.payload.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
