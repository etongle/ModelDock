import Foundation
import CryptoKit

enum FeatureChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw LaunchError.message(message) } }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-feature-checks").appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default; try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []
        let inventory = Scanner.scan()
        let engines = inventory.engines
        guard let prism = engines.first(where: { $0.kind == .prism }), let llama = engines.first(where: { $0.kind == .llama }), let studio = engines.first(where: { $0.kind == .lmstudio }), let ollama = engines.first(where: { $0.kind == .ollama }) else { throw LaunchError.message("Engine definitions missing") }
        let special = LocalModel(id: "special", name: "renamed", format: "GGUF Q2_0", path: "/renamed.gguf", kind: .language, bytes: 100, complete: true, verification: "test", missingFiles: [], removalPath: "/renamed.gguf", architecture: "qwen35", prismRequired: true)
        try require(special.compatible(with: prism) && !special.compatible(with: llama) && !special.compatible(with: studio) && !special.compatible(with: ollama), "Special model escaped Prism guard")
        var ordinary = special; ordinary.prismRequired = false
        try require(ordinary.compatible(with: llama) && ordinary.compatibility(with: ollama).level == .importRequired, "Direct / import-required distinction failed")
        do { _ = try LaunchBuilder.plan(engine: ollama, model: special, port: 11434); throw LaunchError.message("Special model accepted by Ollama launch") }
        catch LaunchError.message(let text) where text.contains("不兼容") { }
        var adapter = ordinary; adapter.kind = .adapter
        try require(!adapter.compatible(with: prism), "Adapter launched standalone")
        if let bonsai = inventory.models.first(where: { $0.format.contains("PQ2") }) { try require(bonsai.prismRequired == true && bonsai.architecture == "qwen35", "Actual GGUF metadata not detected") }
        checks.append("Prism metadata, renamed special model, incompatible engines, adapters and Ollama import requirement")

        let home = root.appendingPathComponent("home"); let models = root.appendingPathComponent("model-library")
        let brew = root.appendingPathComponent("brew"); let applications = root.appendingPathComponent("Applications")
        let locations = MaintenanceLocations(home: home, applications: applications, brew: brew)
        for url in [home, models, applications, home.appendingPathComponent(".lmstudio/extensions/backends")] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let sentinel = models.appendingPathComponent("shared.gguf"); try Data("GGUFshared".utf8).write(to: sentinel)
        let link = home.appendingPathComponent(".lmstudio/models"); try fm.createSymbolicLink(at: link, withDestinationURL: models)
        let runtime = home.appendingPathComponent(".lmstudio/extensions/backends/runtime"); try Data("runtime".utf8).write(to: runtime)
        var fakeInventory = inventory; fakeInventory.roots = [models.path]; fakeInventory.models = []
        var fakeStudio = studio; fakeStudio.installed = false; fakeStudio.appPath = nil
        let plan = EngineMaintenance.plan(engine: fakeStudio, mode: .residues, inventory: fakeInventory, locations: locations)
        try require(plan.items.contains { $0.path == home.appendingPathComponent(".lmstudio/extensions").path }, "Orphan components not removable")
        guard let linkItem = plan.items.first(where: { $0.path == link.path }) else { throw LaunchError.message("Model alias cleanup not available") }
        try EngineMaintenance.validate([linkItem], original: plan, fresh: plan)
        try fm.moveItem(at: link, to: root.appendingPathComponent("trashed-model-alias"))
        try require(fm.fileExists(atPath: sentinel.path), "Shared model removed with alias")
        checks.append("Orphan runtime removal and symbolic-link cleanup preserve actual models")
        if let runtimeItem = plan.items.first(where: { $0.path == home.appendingPathComponent(".lmstudio/extensions").path }) {
            try fm.moveItem(at: URL(fileURLWithPath: runtimeItem.path), to: root.appendingPathComponent("old-runtime"))
            try fm.createDirectory(atPath: runtimeItem.path, withIntermediateDirectories: true)
            do { try EngineMaintenance.validate([runtimeItem], original: plan, fresh: plan); throw LaunchError.message("Changed identity accepted") }
            catch LaunchError.message(let text) where text.contains("变化") { }
        }
        try Data("GGUFnew".utf8).write(to: home.appendingPathComponent(".lmstudio/extensions/untracked.gguf"))
        let safePlan = EngineMaintenance.plan(engine: fakeStudio, mode: .residues, inventory: fakeInventory, locations: locations)
        try require(!safePlan.items.contains { $0.path.hasSuffix("/.lmstudio/extensions") }, "Untracked model weights included in cleanup")
        for (name, dependencies) in [("mlx", [] as [String]), ("mlx-c", ["mlx"]), ("ollama", ["mlx", "mlx-c"])] {
            let directory = brew.appendingPathComponent("Cellar/\(name)/1.0"); try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["runtime_dependencies": dependencies.map { ["full_name": $0] }]).write(to: directory.appendingPathComponent("INSTALL_RECEIPT.json"))
        }
        let dependencies = EngineMaintenance.dependents(of: ["mlx", "mlx-c"], locations: locations)
        try require(dependencies == ["ollama"], "Shared dependency protection failed")
        checks.append("File identity changes, unknown weights and shared Homebrew dependencies blocked")
        for path in ["../escape", "/escape", "folder/../escape", "folder//escape", ".hidden", "folder\\escape"] { try require(!DownloadPaths.safeRelative(path), "Unsafe relative path accepted") }
        let escaped = root.appendingPathComponent("outside"); try fm.createDirectory(at: escaped, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: models.appendingPathComponent("linked"), withDestinationURL: escaped)
        do { _ = try DownloadPaths.destination(root: models, folder: "linked", file: "model.gguf"); throw LaunchError.message("Symlink write accepted") }
        catch LaunchError.message(let text) where text.contains("链接") { }
        checks.append("Download traversal and symlink destinations rejected")

        if let port = argumentValue("--test-port") {
            let payload = Data("GGUF".utf8) + Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
            let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let downloadRoot = root.appendingPathComponent("downloads"); try fm.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
            func remote(_ endpoint: String, hash: String? = nil) -> RemoteFile { .init(path: "model.gguf", url: URL(string: "http://127.0.0.1:\(port)/\(endpoint)")!, bytes: Int64(payload.count), sha256: hash ?? sha) }
            func seed(_ file: RemoteFile, folder: String) throws {
                let path = try DownloadPaths.destination(root: downloadRoot, folder: folder, file: file.path)
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try payload.prefix(8192).write(to: path.appendingPathExtension("incomplete"))
                try JSONEncoder().encode(TransferReceipt(url: file.url, etag: "\"fixture-v1\"", total: file.bytes)).write(to: path.appendingPathExtension("incomplete.metadata.json"))
            }
            for endpoint in ["range", "ignore"] {
                let file = remote(endpoint); try seed(file, folder: endpoint)
                let transfer = try DownloadTransfer(file: file, root: downloadRoot, folder: endpoint) { _, _ in }
                if endpoint == "ignore" {
                    do { try await transfer.run(); throw LaunchError.message("Unsupported range overwrote progress") }
                    catch is DownloadResumeError { try require(tryData(transfer.partial) == payload.prefix(8192), "Rejected range changed original partial") }
                    let fresh = try DownloadTransfer(file: file, root: downloadRoot, folder: "ignore-independent") { _, _ in }
                    try await fresh.run(); try require(tryData(fresh.destination) == payload, "Independent restart failed"); continue
                }
                try await transfer.run()
                try require(tryData(transfer.destination) == payload, "Range download corrupted: \(endpoint)")
                try require(!fm.fileExists(atPath: transfer.partial.path), "Completed download left partial")
            }
            let fullFile = remote("range")
            let fullWorker = try DownloadTransfer(file: fullFile, root: downloadRoot, folder: "full") { _, _ in }
            try fm.createDirectory(at: fullWorker.partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: fullWorker.partial)
            try JSONEncoder().encode(TransferReceipt(url: fullFile.url, etag: "\"fixture-v1\"", total: fullFile.bytes)).write(to: fullWorker.receiptURL)
            try await fullWorker.run(); try require(tryData(fullWorker.destination) == payload, "Fully received partial could not recover")
            let bad = remote("bad-range"); try seed(bad, folder: "bad")
            let badWorker = try DownloadTransfer(file: bad, root: downloadRoot, folder: "bad") { _, _ in }
            do { try await badWorker.run(); throw LaunchError.message("Bad range accepted") } catch LaunchError.message(let text) where text.contains("续传位置") { }
            let corrupt = remote("range", hash: String(repeating: "0", count: 64))
            let corruptWorker = try DownloadTransfer(file: corrupt, root: downloadRoot, folder: "corrupt") { _, _ in }
            do { try await corruptWorker.run(); throw LaunchError.message("Bad checksum accepted") } catch let error as DownloadResumeError where error.localizedDescription.contains("校验失败") { }
            let html = RemoteFile(path: "model.gguf", url: URL(string: "http://127.0.0.1:\(port)/html")!, bytes: 0)
            let htmlWorker = try DownloadTransfer(file: html, root: downloadRoot, folder: "html") { _, _ in }
            do { try await htmlWorker.run(); throw LaunchError.message("HTML imported as model") } catch LaunchError.message(let text) where text.contains("网页") { }
            let slow = remote("slow")
            let slowWorker = try DownloadTransfer(file: slow, root: downloadRoot, folder: "slow") { _, _ in }
            let running = Task { try await slowWorker.run() }
            try await Task.sleep(nanoseconds: 180_000_000); slowWorker.cancel()
            var interrupted = false
            do { try await running.value } catch { interrupted = true }
            try require(interrupted, "Paused task unexpectedly completed")
            let resumed = try DownloadTransfer(file: slow, root: downloadRoot, folder: "slow") { _, _ in }
            try await resumed.run(); try require(tryData(resumed.destination) == payload, "Pause/resume corrupted model")
            let controller = DownloadController(directory: root)
            let cleanup = ModelDownload(site: .direct, repository: "fixture", revision: "fixture", root: downloadRoot.path, folder: "bad", files: [bad])
            controller.jobs = [cleanup]; controller.activeID = cleanup.id
            do { try controller.cleanPartials(cleanup.id); throw LaunchError.message("Active download deleted") } catch LaunchError.message(let text) where text.contains("暂停") { }
            controller.activeID = nil; try controller.cleanPartials(cleanup.id)
            try require(!fm.fileExists(atPath: badWorker.partial.path) && fm.fileExists(atPath: resumed.destination.path), "Cleanup removed completed model")
            checks.append("Real HTTP 206 continuation, isolated 200 restart, pause/resume, SHA-256, HTML rejection and scoped incomplete-file cleanup")
            checks.append("Fully received partial recovered without repeating the download")
        }
        if CommandLine.arguments.contains("--network-checks") {
            for address in ["https://huggingface.co/Qwen/Qwen3-0.6B", "https://modelscope.cn/models/Qwen/Qwen3-0.6B"] {
                let listing = try await ModelCatalog.listing(address, token: "")
                guard let config = listing.files.first(where: { $0.path == "config.json" }) else { throw LaunchError.message("Public model catalog missing config.json") }
                let worker = try DownloadTransfer(file: config, root: root, folder: "public-\(listing.site == .huggingface ? "hf" : "ms")") { _, _ in }
                try await worker.run(); try require(jsonFile(worker.destination) != nil, "Public model configuration invalid")
                checks.append("\(listing.site.rawValue): live repository listing and small configuration download")
            }
        }
        let report: [String: Any] = ["result": "passed", "checks": checks, "fixtures": root.path, "real_engines_uninstalled": false, "real_models_deleted": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
    }
    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
