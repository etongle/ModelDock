import Foundation

enum ConnectionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw LaunchError.message(message) } }
    static func read(_ path: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any] }
    static func runShell(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Generated script failed")
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-connection-checks").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let pid = ProcessInfo.processInfo.processIdentifier, birth = processStartTime(ProcessInfo.processInfo.processIdentifier)
        let marker = root.appendingPathComponent("INJECTION")
        let model = "org/Qwen' $(touch \(marker.path)) `touch \(marker.path)`"
        let project = root.appendingPathComponent("Project ' $ (literal)")
        try ConnectionFiles.privateDirectory(project)
        var target = ConnectionTarget(id: "fixture", engineName: "Splash", engineID: "splash", model: model, port: 18099, pid: pid, birth: birth, context: 32768)
        target.supportsThinkingToggle = true
        var checks: [String] = [], fixtures: [ClientConnection] = []
        let original = root.appendingPathComponent("existing-user-config.json")
        let userConfig = Data(#"{"plugins":["user-plugin"],"defaultModel":"cloud/model","auth":{"existing":"fixture-value"}}"#.utf8)
        try userConfig.write(to: original)
        for client in CodingClient.allCases {
            var clientTarget = target
            let clientContext = client == .hermes ? 64_000 : 32768
            clientTarget.context = clientContext
            let argsFile = root.appendingPathComponent("\(client.rawValue)-args.txt")
            let stub = root.appendingPathComponent("\(client.rawValue)-fixture")
            try ConnectionFiles.write(Data("#!/bin/sh\n/usr/bin/printf '%s\\n' \"$@\" > \(ConnectionFiles.quote(argsFile.path))\n".utf8), to: stub, executable: true)
            let connection = try ConnectionFiles.prepare(client: client, target: clientTarget, context: clientContext, executable: stub.path, project: project.path, root: root.appendingPathComponent("connections"), guardExecutable: nil)
            let object = try read(connection.configuration)
            try require(connection.endpoint == "http://127.0.0.1:18099/v1", "Incorrect API endpoint")
            try require(connection.configuration.hasPrefix(root.path), "Wrote outside isolated profile")
            try require(connection.unsetEnvironment == client.inheritedSelectors && !client.inheritedSelectors.isEmpty, "Inherited config selector protection missing")
            try require(connection.arguments.contains(model) || connection.arguments.contains("\(target.providerID)/\(model)"), "Reported API model lost")
            switch client {
            case .opencode:
                try require(object["model"] as? String == "\(target.providerID)/\(model)" && object["small_model"] as? String == object["model"] as? String, "Cloud auxiliary model selected")
                try require(object["enabled_providers"] as? [String] == [target.providerID] && connection.arguments.contains("--pure"), "Local provider isolation lost")
                try require(connection.environment["XDG_CONFIG_HOME"]?.hasPrefix(root.path) == true, "OpenCode user settings modified")
                try require(connection.environment["OPENCODE_DISABLE_EXTERNAL_SKILLS"] == "1", "Global skill discovery not isolated")
            case .pi:
                let provider = (object["providers"] as? [String: Any])?[target.providerID] as? [String: Any]
                let entry = (provider?["models"] as? [[String: Any]])?.first
                try require(entry?["id"] as? String == model && entry?["contextWindow"] as? Int == clientContext && entry?["maxTokens"] as? Int == 8192, "pi model or token limits incorrect")
                let sampling = entry?["samplingParams"] as? [String: Any]
                try require((sampling?["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false, "pi thinking off did not reach the model request")
                let settings = try read(URL(fileURLWithPath: connection.configuration).deletingLastPathComponent().appendingPathComponent("settings.json").path)
                let compaction = settings["compaction"] as? [String: Any], overrides = compaction?["modelOverrides"] as? [String: [String: Int]], budget = overrides?[target.providerID + "/" + model]
                try require(budget?["reserveTokens"] == 12288 && budget?["keepRecentTokens"] == 2048, "pi compaction budget is too small or late")
                try require(connection.environment["PI_CODING_AGENT_DIR"]?.hasPrefix(root.path) == true, "pi user settings modified")
                try require(connection.arguments.contains("--no-skills") && !connection.arguments.contains("--no-tools"), "Full tools or skill isolation lost")
            case .hermes:
                try require((object["fallback_providers"] as? [String])?.isEmpty == true, "Hermes cloud fallback enabled")
                try require((object["model"] as? [String: Any])?["context_length"] as? Int == clientContext, "Hermes real context missing")
                try require(connection.environment["HERMES_HOME"]?.hasPrefix(root.path) == true, "Hermes user settings modified")
            }
            try runShell(["-n", connection.script]); try runShell([connection.script])
            let actual = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
            try require(actual == connection.arguments, "Shell changed model arguments: \(client)")
            try require(!FileManager.default.fileExists(atPath: marker.path), "Shell injection executed")
            fixtures.append(connection)
            checks.append("\(client.title): native config, isolated profile, API model ID, token limits, safely quoted executable script")
        }
        let remaining = try Data(contentsOf: original)
        try require(remaining == userConfig, "Existing user settings changed")
        try require(CodingClient.hermes.contextRequirement(8192) != nil && CodingClient.hermes.contextRequirement(64_000) == nil, "Hermes context compatibility guard missing")
        try require(CodingClient.pi.contextRequirement(8192) != nil && CodingClient.opencode.contextRequirement(32768) == nil, "Small-context coding connection guard missing")
        for bad in ["", "model\nname", "model\u{0}"] { try require(!ConnectionFiles.validModel(bad), "Unsafe model name accepted") }
        do {
            _ = try ConnectionFiles.prepare(client: .pi, target: target, context: 65536, executable: fixtures[1].executable, project: project.path, root: root)
            throw LaunchError.message("Context exceeds real service")
        } catch LaunchError.message(let text) where text.contains("无效") { }
        let linked = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: project)
        do { try ConnectionFiles.privateDirectory(linked); throw LaunchError.message("Symlink accepted") }
        catch LaunchError.message(let text) where text.contains("链接") { }
        let listener = PortListener(pid: pid, birth: birth, engineID: "splash")
        let ready = ProbeResult(alive: true, ready: true, models: [model], code: 200)
        try require(ConnectionFiles.matches(target, before: [listener], after: [listener], probe: ready, records: []), "Valid identity rejected")
        var changed = listener; changed.birth += 1
        try require(!ConnectionFiles.matches(target, before: [listener], after: [changed], probe: ready, records: []), "Replaced process accepted")
        var missing = ready; missing.models = ["another-model"]
        try require(!ConnectionFiles.matches(target, before: [listener], after: [listener], probe: missing, records: []), "Unreported model accepted")
        var stale = target; stale.birth += 1
        try require(!ConnectionFiles.matches(stale, before: [changed], after: [changed], probe: ready, records: []), "PID reuse accepted")
        var wrongEngine = listener; wrongEngine.engineID = "mlx"
        try require(!ConnectionFiles.matches(target, before: [wrongEngine], after: [wrongEngine], probe: ready, records: []), "Wrong engine accepted")
        do {
            try await ConnectionFiles.validateLaunch(URL(fileURLWithPath: fixtures[0].script).appendingPathExtension("json"))
            throw LaunchError.message("Stale copied command accepted")
        } catch LaunchError.message(let text) where text.contains("重新接入") { }
        checks.append("Existing config bytes preserved; symlink, invalid models, inflated context, stale listener, PID reuse and missing API model blocked")

        if let port = argumentValue("--live-connection-port").flatMap(Int.init) {
            // Read the real saved identity without monitoring, restarting or editing its service state.
            let services = ServiceController(stateDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModelManager"))
            let spec = services.records.first { $0.port == port && $0.pid != nil }
            let probe = await NetworkProbe.models(port: port)
            guard let model = probe.models.first, let spec, let pid = spec.pid, let birth = spec.processStart, probe.ready else { throw LaunchError.message("Live service unavailable") }
            let live = ConnectionTarget(id: spec.id, engineName: PortIdentity.name(spec.engineID), engineID: spec.engineID, model: model, port: port, pid: pid, birth: birth, context: spec.context)
            let listeners = PortIdentity.listeners(ports: [port])[port] ?? []
            try require(ConnectionFiles.matches(live, before: listeners, after: listeners, probe: probe, records: services.records), "Live listener identity mismatch")
            let installations = ClientInstallation.discover()
            var exports: [ClientConnection] = []
            for client in CodingClient.allCases {
                if client.contextRequirement(spec.context) != nil { continue }
                guard let executable = installations.first(where: { $0.id == client })?.executable else { continue }
                exports.append(try ConnectionFiles.prepare(client: client, target: live, context: spec.context, executable: executable, project: project.path, root: root.appendingPathComponent("live-connections")))
            }
            for export in exports { try await ConnectionFiles.validateLaunch(URL(fileURLWithPath: export.script).appendingPathExtension("json")) }
            try JSONEncoder().encode(exports).write(to: root.appendingPathComponent("live-exports.json"))
            checks.append("Live service API and kernel process identity verified; installed clients exported without changing the running service")
        }
        let data = try ConnectionFiles.json(["result": "passed", "checks": checks, "root": root.path])
        try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
    }
}
