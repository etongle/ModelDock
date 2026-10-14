import Foundation
import Darwin

struct AppUpdateJob: Codable {
    var id: String
    var target: String
    var staged: String
    var backup: String
    var oldVersion: String
    var version: String
    var parentPID: Int32
    var parentBirth: UInt64
    var hidden: Bool
    var receipt: String
    var stateDirectory: String? = nil
}

enum AppUpdateWorker {
    static let bundleID = "local.null.ModelManager"
    static func command(_ executable: String, _ args: [String]) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = args
        let pipe = Pipe(); task.standardError = pipe; task.standardOutput = pipe; task.standardInput = FileHandle.nullDevice
        try task.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw LaunchError.message(String(decoding: output, as: UTF8.self)) }
    }
    static func validate(_ app: URL, version: String) throws {
        guard (try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleExecutable"] as? String == "ModelManager",
              info["CFBundleShortVersionString"] as? String == version else { throw LaunchError.message("应用更新包的名称或版本不匹配，原应用保留。") }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    static func validatePaths(_ job: AppUpdateJob) throws {
        guard UUID(uuidString: job.id) != nil, job.parentPID > 1, job.parentBirth > 0,
              AppUpdateCatalog.newer(job.version, than: job.oldVersion), job.stateDirectory == nil || job.stateDirectory?.hasPrefix("/") == true else { throw LaunchError.message("应用更新任务无效") }
        let target = URL(fileURLWithPath: job.target).standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", target.path == job.target,
              job.staged == parent.appendingPathComponent(".ModelDock-update-" + job.id + ".app").path,
              job.backup == parent.appendingPathComponent(".ModelDock-backup-" + job.id + ".app").path,
              !FileManager.default.fileExists(atPath: job.backup) else { throw LaunchError.message("应用更新路径已变化，原应用保留。") }
    }
    // The staged copy is on the destination volume, so both moves are renames.
    // A backup is retained because existing service processes may still map it.
    static func apply(_ job: AppUpdateJob, launch: (URL, [String]) throws -> Void) throws {
        try validatePaths(job)
        let target = URL(fileURLWithPath: job.target), staged = URL(fileURLWithPath: job.staged), backup = URL(fileURLWithPath: job.backup)
        try validate(target, version: job.oldVersion); try validate(staged, version: job.version)
        var moved = false, installed = false
        do {
            try FileManager.default.moveItem(at: target, to: backup); moved = true
            try FileManager.default.moveItem(at: staged, to: target); installed = true
            try validate(target, version: job.version)
            try receipt(job, result: "installed", error: nil)
            let state = job.stateDirectory.map { ["--state-dir", $0] } ?? []
            try launch(target, ["--after-app-update", job.receipt] + state + (job.hidden ? ["--start-hidden"] : []))
        } catch {
            if installed { try? FileManager.default.moveItem(at: target, to: staged) }
            if moved, !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: backup, to: target) }
            try? receipt(job, result: "failed", error: error.localizedDescription)
            if moved { try? launch(target, job.stateDirectory.map { ["--state-dir", $0] } ?? []) }
            throw error
        }
    }
    static func receipt(_ job: AppUpdateJob, result: String, error: String?) throws {
        var object: [String: Any] = ["result": result, "version": job.version, "backup": job.backup, "target": job.target, "date": Date().timeIntervalSince1970]
        if let error { object["error"] = error }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: job.receipt), options: .atomic)
    }
    static func run(_ path: String) -> Int32 {
        var job: AppUpdateJob?
        do {
            job = try JSONDecoder().decode(AppUpdateJob.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let job else { return 1 }; try validatePaths(job)
            let expected = URL(fileURLWithPath: job.target).appendingPathComponent("Contents/MacOS/ModelManager").resolvingSymlinksInPath().path
            if processStartTime(job.parentPID) == job.parentBirth {
                guard PortIdentity.executable(job.parentPID) == expected else { throw LaunchError.message("正在更新的应用进程身份已变化") }
                let deadline = Date().addingTimeInterval(35)
                while processStartTime(job.parentPID) == job.parentBirth && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                guard processStartTime(job.parentPID) != job.parentBirth else { throw LaunchError.message("应用未能退出，原版本保留；请重试更新。") }
            }
            try apply(job) { target, args in try command("/usr/bin/open", ["-n", target.path, "--args"] + args) }
            return 0
        } catch {
            if let job { try? receipt(job, result: "failed", error: error.localizedDescription) }
            fputs("APP UPDATE FAILED: \(error.localizedDescription)\n", stderr); return 1
        }
    }
}
