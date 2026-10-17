import Foundation

@MainActor enum SolutionExampleChecks {
    static func run(_ deployment: SolutionDeployment, store: AppStore, root: URL) async throws {
        let folder = root.appendingPathComponent("examples"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let port = try MultiModelPlanner.availablePorts(base: 29900, count: 1, occupied: NetworkProbe.portOccupied)[0]
        var source = deployment
        source.components = [SolutionRole.asr, .text, .tts, .chat, .vision].map { .init(role: $0, engineID: "fixture", repository: "fixture", revision: "fixture") }
        let endpoint = "http://127.0.0.1:\(port)/solutions/\(source.id.lowercased())/v1"
        for example in SolutionGatewayExamples.all(source, endpoint: endpoint) {
            try ConnectionChecks.require(!example.script.contains(store.gateway.settings.apiKey), "Example embedded the gateway key")
            try Data(example.script.utf8).write(to: folder.appendingPathComponent(example.id + ".sh"))
        }
        source.draft.language = "English'; $(touch \(folder.appendingPathComponent("unexpected-execution").path))\nMODELDOCK_JSON\n"
        let quoted = SolutionGatewayExamples.all(source, endpoint: endpoint).first { $0.id == "translation" }!
        try Data(quoted.script.utf8).write(to: folder.appendingPathComponent("translation-quoted.sh"))
        try ConnectionFiles.json(["solutionID": source.id, "untrustedLanguage": source.draft.language]).write(to: folder.appendingPathComponent("manifest.json"))
        guard let python = EnginePaths.gatewayPython else { throw LaunchError.message("Missing fixture Python runtime") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", FileManager.default.currentDirectoryPath + "/Tests/solution_examples_checks.py", "--directory", folder.path, "--port", String(port)]
        let log = folder.appendingPathComponent("checks.log"); FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        for _ in 0..<600 { if !process.isRunning { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        if process.isRunning { process.terminate(); throw LaunchError.message("Example checks timed out") }
        try ConnectionChecks.require(process.terminationStatus == 0, "Example checks failed; see " + log.path)
    }
}
