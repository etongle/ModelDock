import Foundation

enum DownloadGlobalTokenChecks {
    @MainActor static func run(root: URL) async throws {
        let storage = MemoryModelTokenStorage()
        let controller = DownloadController(directory: root.appendingPathComponent("global-token-state"), tokenStorage: storage)
        controller.transferProtocolClasses = [DownloadAuthorizationFixture.self]
        controller.chooseDestination(root.appendingPathComponent("global-token-library").path)
        defer { controller.pauseAll() }
        try ConnectionChecks.require(controller.accessTokens.save("hf_fixture_download"), "Global token did not save")
        for address in ["https://github.com/fixture/model", "https://modelscope.cn/models/fixture/model", "http://huggingface.co/fixture/model", "https://huggingface.co.evil.invalid/fixture/model", "https://user@huggingface.co/fixture/model"] {
            try ConnectionChecks.require(controller.accessTokens.credential(for: address).isEmpty, "Global HF token escaped its HTTPS host scope")
        }
        try ConnectionChecks.require(controller.accessTokens.credential(for: "fixture/model") == "hf_fixture_download" && controller.accessTokens.credential(for: "fixture/model", override: "one-time") == "one-time", "Global fallback or single-task override failed")
        try ConnectionChecks.require(!controller.accessTokens.save("invalid\nvalue") && controller.accessTokens.credential(for: "fixture/model") == "hf_fixture_download", "Invalid token replaced a valid global credential")
        controller.accessTokens.error = nil
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<400 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw LaunchError.message("Global token fixture timed out")
        }
        let file = RemoteFile(path: "model.gguf", url: URL(string: "https://huggingface.co/authorization-fixture/global/resolve/main/model.gguf")!, bytes: Int64(DownloadAuthorizationFixture.payload.count), sha256: DownloadTaskChecks.hash(DownloadAuthorizationFixture.payload))
        let listing = RemoteListing(site: .huggingface, repository: "authorization-fixture/global", revision: String(repeating: "d", count: 40), files: [file])
        controller.catalogLoader = { _, token in
            try ConnectionChecks.require(token == "hf_fixture_download", "Repository resolution did not use the global token")
            return listing
        }
        controller.address = listing.repository; controller.resolve()
        try await wait { !controller.resolving }
        try ConnectionChecks.require(controller.listing != nil && controller.message == nil, "Global-token repository resolution failed")
        controller.selected = [file.path]; controller.createJob()
        let first = controller.selectedTaskID!
        controller.beginImport()
        try await wait { !controller.hasPendingWork }
        try ConnectionChecks.require(controller.jobs.first { $0.id == first }?.state == .complete && controller.token.isEmpty, "Global token was lost when a new import cleared the input")

        var old = ModelDownload(site: .huggingface, repository: listing.repository, revision: listing.revision, root: controller.destination, folder: "old/snapshots/" + listing.revision, files: [file])
        old.state = .failed; old.authorizationStatus = 401; old.error = "HTTP 401"
        controller.jobs.append(old); controller.resume(old.id)
        try ConnectionChecks.require(controller.authorization == nil, "Saved global token still forced per-task entry")
        try await wait { !controller.hasPendingWork }
        try ConnectionChecks.require(controller.jobs.first { $0.id == old.id }?.state == .complete, "Existing 401 task did not recover with the global token")

        controller.beginImport(); controller.token = "hf_one_time_invalid"
        var another = listing; another.repository += "-override"; controller.listing = another; controller.selected = [file.path]; controller.createJob()
        let overridden = controller.selectedTaskID!
        try await wait { !controller.hasPendingWork }
        try ConnectionChecks.require(controller.jobs.first { $0.id == overridden }?.authorizationStatus == 401, "Single-task override did not take precedence")
        controller.resume(overridden)
        try await wait { !controller.hasPendingWork }
        try ConnectionChecks.require(controller.jobs.first { $0.id == overridden }?.state == .complete, "Global token did not replace a rejected one-time override on retry")

        let restored = DownloadController(directory: controller.directory, tokenStorage: storage)
        try ConnectionChecks.require(restored.accessTokens.credential(for: listing.repository) == "hf_fixture_download", "Saved credential was not available to a reopened controller")
        let serialized = String(decoding: try Data(contentsOf: controller.directory.appendingPathComponent("downloads.json")), as: UTF8.self)
        try ConnectionChecks.require(!serialized.contains("hf_fixture_download") && !serialized.contains("hf_one_time_invalid"), "Global or temporary credential was written to task JSON")
        try ConnectionChecks.require(old.huggingFacePage?.absoluteString == "https://huggingface.co/authorization-fixture/global", "Download repository page did not point to the original HF model")
        old.repository = "invalid/repo/extra"; try ConnectionChecks.require(old.huggingFacePage == nil, "Invalid repository became a page URL")
        restored.accessTokens.remove()
        try ConnectionChecks.require(restored.accessTokens.credential(for: listing.repository).isEmpty && !restored.accessTokens.huggingFaceConfigured, "Removing the global token did not clear it")
        print("GLOBAL HF TOKEN CHECKS PASSED (host isolation, override, new import, existing 401 resume, reopen, no JSON secrets, source page)")
    }
}
