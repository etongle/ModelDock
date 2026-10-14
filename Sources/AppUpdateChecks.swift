import Foundation

enum AppUpdateChecks {
    @MainActor static func run() async throws {
        guard let output = argumentValue("--check-dir"), let executable = Bundle.main.executableURL else { throw LaunchError.message("Isolated output required") }
        let root = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let tag = "v1.2.3", name = "ModelDock-1.2.3-AppleSilicon.zip"
        let asset: [String: Any] = ["name": name, "size": Int64(30000000), "state": "uploaded", "digest": "sha256:" + String(repeating: "a", count: 64), "browser_download_url": "https://github.com/etongle/ModelDock/releases/download/" + tag + "/" + name]
        let base: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false, "published_at": "2026-10-14T00:00:00Z", "html_url": "https://github.com/etongle/ModelDock/releases/tag/" + tag, "assets": [asset]]
        let release = try AppUpdateCatalog.parse(base)
        if let metadata = argumentValue("--release-metadata"), let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: metadata))) as? [String: Any] {
            let official = try AppUpdateCatalog.parse(value)
            try ConnectionChecks.require(official.url.host == "github.com" && official.sha256.count == 64, "Actual GitHub release metadata")
        }
        try ConnectionChecks.require(release.version == "1.2.3" && release.bytes == 30000000 && AppUpdateCatalog.newer("1.2.3", than: "1.2.2") && !AppUpdateCatalog.newer("1.2.3", than: "1.2.3") && !AppUpdateCatalog.newer("0.8.1", than: "0.9.0"), "Stable versions / downgrade policy")
        func rejects(_ value: [String: Any]) throws {
            do { _ = try AppUpdateCatalog.parse(value) } catch { return }
            throw LaunchError.message("Invalid app release accepted")
        }
        for key in ["draft", "prerelease"] { var value = base; value[key] = true; try rejects(value) }
        for (key, wrong) in [("digest", "sha256:bad"), ("browser_download_url", "https://github.com/other/ModelDock/releases/download/" + tag + "/" + name), ("name", "ModelDock-1.2.3-Intel.zip")] {
            var wrongAsset = asset; wrongAsset[key] = wrong; var value = base; value["assets"] = [wrongAsset]; try rejects(value)
        }
        var duplicate = base; duplicate["assets"] = [asset, asset]; try rejects(duplicate)
        var wrongPage = base; wrongPage["html_url"] = "https://github.com/another/repo/releases/tag/" + tag; try rejects(wrongPage)

        func app(_ path: URL, _ version: String) throws {
            try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executable, to: path.appendingPathComponent("Contents/MacOS/ModelManager"))
            let info: [String: Any] = ["CFBundleIdentifier": AppUpdateWorker.bundleID, "CFBundleExecutable": "ModelManager", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path.appendingPathComponent("Contents/Info.plist"))
            try AppUpdateWorker.command("/usr/bin/codesign", ["--force", "--sign", "-", path.path])
        }
        func job(_ folder: URL) throws -> AppUpdateJob {
            try ConnectionFiles.privateDirectory(folder)
            let id = UUID().uuidString, target = folder.appendingPathComponent("ModelDock.app")
            let staged = folder.appendingPathComponent(".ModelDock-update-" + id + ".app")
            try app(target, "1.0.0"); try app(staged, "1.1.0")
            return .init(id: id, target: target.path, staged: staged.path, backup: folder.appendingPathComponent(".ModelDock-backup-" + id + ".app").path, oldVersion: "1.0.0", version: "1.1.0", parentPID: getpid(), parentBirth: processStartTime(getpid()), hidden: true, receipt: folder.appendingPathComponent("receipt.json").path)
        }
        let data = root.appendingPathComponent("personal-model.bin"); try Data("preserved model and settings".utf8).write(to: data)
        let successful = try job(root.appendingPathComponent("success"))
        var launched = false
        try AppUpdateWorker.apply(successful) { path, args in
            try ConnectionChecks.require(path.path == successful.target && args.contains("--start-hidden"), "Relaunch / background mode")
            launched = true
        }
        try AppUpdateWorker.validate(URL(fileURLWithPath: successful.target), version: "1.1.0")
        try AppUpdateWorker.validate(URL(fileURLWithPath: successful.backup), version: "1.0.0")
        let preserved = String(decoding: try Data(contentsOf: data), as: UTF8.self)
        try ConnectionChecks.require(launched && preserved == "preserved model and settings", "Retained old bundle / user files")
        let failure = try job(root.appendingPathComponent("rollback"))
        do { try AppUpdateWorker.apply(failure) { _, _ in throw LaunchError.message("Simulated relaunch failure") }; throw LaunchError.message("Expected rollback") }
        catch LaunchError.message(let text) where text == "Simulated relaunch failure" { }
        try AppUpdateWorker.validate(URL(fileURLWithPath: failure.target), version: "1.0.0")
        try ConnectionChecks.require(!FileManager.default.fileExists(atPath: failure.backup), "Rollback must restore original pathname")
        let bad = try job(root.appendingPathComponent("tampered"))
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: bad.staged).appendingPathComponent("Contents/MacOS/ModelManager"))
        var changed = false
        do { try AppUpdateWorker.apply(bad) { _, _ in changed = true }; throw LaunchError.message("Tampered app accepted") } catch { }
        try AppUpdateWorker.validate(URL(fileURLWithPath: bad.target), version: "1.0.0")
        try ConnectionChecks.require(!changed && !FileManager.default.fileExists(atPath: bad.backup), "Failed validation must preserve original")
        // Exercise the copied native executable's worker branch, without a GUI or real app replacement.
        let worker = root.appendingPathComponent("worker")
        try FileManager.default.copyItem(at: executable, to: worker)
        let invalid = root.appendingPathComponent("invalid.json"); try Data("{}".utf8).write(to: invalid)
        let process = Process(); process.executableURL = worker; process.arguments = ["--apply-app-update", invalid.path]
        process.standardError = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try ConnectionChecks.require(process.terminationStatus == 1, "Native updater must execute without application resources")
        let prefs = root.appendingPathComponent("preferences")
        let controller = AppUpdateController(directory: prefs)
        controller.automaticCheck = false; controller.automaticInstall = false
        let restored = AppUpdateController(directory: prefs)
        try ConnectionChecks.require(!restored.automaticCheck && !restored.automaticInstall, "Update settings persistence")
        if let script = argumentValue("--download-fixture"), let python = EnginePaths.bundledPython ?? EnginePaths.python {
            let port = try MultiModelPlanner.availablePorts(base: 29820, count: 1, occupied: NetworkProbe.portOccupied)[0]
            let server = Process(); server.executableURL = URL(fileURLWithPath: python); server.arguments = ["-B", script, "--port", String(port)]
            server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
            try server.run(); defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
            for _ in 0..<60 { if NetworkProbe.portOccupied(port) { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            try ConnectionChecks.require(NetworkProbe.portOccupied(port), "Download fixture not ready")
            var fixtureRelease = release; fixtureRelease.url = URL(string: "http://127.0.0.1:\(port)/update")!; fixtureRelease.bytes = 65536 * 20
            let destination = root.appendingPathComponent("transfer.zip")
            let progress = TransferProgressCheck()
            let transfer = AppUpdateTransfer(release: fixtureRelease, destination: destination) { bytes, speed in progress.record(bytes, speed) }
            try await transfer.run()
            try ConnectionChecks.require(StrataModelCatalog.fileSize(destination.path) == fixtureRelease.bytes && progress.complete(fixtureRelease.bytes), "Actual transfer progress/speed callbacks")
            let partial = root.appendingPathComponent("cancelled.zip")
            let cancelled = AppUpdateTransfer(release: fixtureRelease, destination: partial, progress: { _, _ in })
            let pending = Task { try await cancelled.run() }
            try await Task.sleep(nanoseconds: 180_000_000); cancelled.cancel()
            var didCancel = false
            do { try await pending.value } catch { didCancel = true }
            try ConnectionChecks.require(didCancel && !FileManager.default.fileExists(atPath: partial.path), "Cancelled download left an installable payload")
            fixtureRelease.url = URL(string: "http://127.0.0.1:\(port)/missing")!
            let missing = root.appendingPathComponent("missing.zip")
            var rejected = false
            do { try await AppUpdateTransfer(release: fixtureRelease, destination: missing, progress: { _, _ in }).run() } catch { rejected = true }
            try ConnectionChecks.require(rejected && !FileManager.default.fileExists(atPath: missing.path), "HTTP error accepted as installer")
        }
        let report: [String: Any] = ["result": "passed", "checks": ["official stable release", "SHA metadata", "reject wrong repository/architecture", "no downgrade", "signature before replacing", "preserved old bundle", "rollback on relaunch failure", "native worker relocation", "preferences persistence", "personal files preserved"], "downloadFixtureTested": argumentValue("--download-fixture") != nil, "realInstalledApplicationModified": false]
        let result = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try result.write(to: root.appendingPathComponent("result.json")); print(String(decoding: result, as: UTF8.self))
    }
}

private final class TransferProgressCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var amounts: [Int64] = []
    private var measuredSpeed = false
    func record(_ bytes: Int64, _ speed: Double) { lock.lock(); defer { lock.unlock() }; amounts.append(bytes); measuredSpeed = measuredSpeed || speed > 0 }
    func complete(_ total: Int64) -> Bool { lock.lock(); defer { lock.unlock() }; return amounts.count >= 2 && amounts.last == total && amounts == amounts.sorted() && measuredSpeed }
}
