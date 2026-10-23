import Foundation
import AppKit
import Darwin

private struct PlaygroundProcess: Codable {
    var pid: Int32
    var birth: UInt64
    var port: Int
    var imagePort: Int
}

@MainActor final class ImagePlaygroundController {
    private let root: URL
    private var processes: [String: PlaygroundProcess]
    private var children: [String: Process] = [:]
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    init(directory: URL) {
        root = directory.appendingPathComponent("playground")
        processes = (try? Data(contentsOf: root.appendingPathComponent("processes.json"))).flatMap { try? JSONDecoder().decode([String: PlaygroundProcess].self, from: $0) } ?? [:]
    }
    private func owns(_ process: PlaygroundProcess, config: URL) -> Bool {
        guard process.pid > 1, process.birth > 0, processStartTime(process.pid) == process.birth, getpgid(process.pid) == process.pid else { return false }
        let arguments = PortIdentity.arguments(process.pid)
        return arguments.contains(config.path) && arguments.contains { URL(fileURLWithPath: $0).lastPathComponent == "playground.py" }
    }
    func open(_ deployment: SolutionDeployment, store: AppStore) async throws {
        guard deployment.solutionID == "image-generation",
              store.solutions.runtime(deployment, store: store).allReady,
              let component = deployment.components.first(where: { $0.role == .image }),
              let service = store.services.records.first(where: { $0.id == component.serviceID }), store.services.status(service) == .running,
              let python = EnginePaths.gatewayPython, let resources = Bundle.main.resourceURL else { throw LaunchError.message("请先启动生图服务并等待就绪。") }
        let config = root.appendingPathComponent(deployment.id + ".json")
        let template = resources.appendingPathComponent("PlaygroundClient/config-template.json")
        guard var value = try JSONSerialization.jsonObject(with: Data(contentsOf: template)) as? [String: Any] else { throw LaunchError.message("未找到 GPT Image Playground 客户端。") }
        let chat = store.gateway.routes.filter { $0.available && $0.enabled && $0.inputs.contains("text") && $0.inputs.contains("image") && $0.outputs.contains("text") && TranslationLanguages.identityIssue($0.model) == nil }.sorted { ($0.engineID == "splash" ? 0 : 1) < ($1.engineID == "splash" ? 0 : 1) }.first
        value["image_model"] = component.serviceBinding?.model ?? store.services.reportedModels[service.port]?.first ?? ImageModelPolicy.repository
        value["chat_route"] = chat?.alias ?? ""
        if var profiles = value["profiles"] as? [[String: Any]] {
            for index in profiles.indices {
                if profiles[index]["id"] as? String == "modeldock-local-image" {
                    profiles[index]["name"] = "本地生图 · 实例 " + String(deployment.id.prefix(8))
                } else if profiles[index]["id"] as? String == "modeldock-local-chat", let chat {
                    profiles[index]["name"] = "本地对话 · " + chat.model
                }
            }
            value["profiles"] = profiles
        }
        if chat == nil {
            value["profiles"] = (value["profiles"] as? [[String: Any]])?.filter { $0["id"] as? String == "modeldock-local-image" }
            value.removeValue(forKey: "agent")
        }
        value["solution_id"] = deployment.id
        try ConnectionFiles.privateDirectory(root)
        try ConnectionFiles.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: config)
        var selected = processes[deployment.id]
        if let prior = selected, owns(prior, config: config), prior.imagePort != service.port {
            _ = kill(prior.pid, SIGTERM); selected = nil
        }
        if selected.map({ owns($0, config: config) }) != true {
            guard let port = (18791...18830).first(where: { !NetworkProbe.portOccupied($0) && !store.services.portReserved($0) }) else { throw LaunchError.message("本地 Playground 端口已被占用，请稍后重试。") }
            let log = root.appendingPathComponent(deployment.id + ".log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
            let child = Process(); child.executableURL = Bundle.main.executableURL
            child.arguments = ["--child-exec", python, "-I", "-B", "-u", resources.appendingPathComponent("playground.py").path, "--port", String(port), "--image-port", String(service.port), "--config", config.path, "--dist", resources.appendingPathComponent("PlaygroundClient").path, "--state-dir", root.deletingLastPathComponent().path]
            child.standardOutput = handle; child.standardError = handle; child.standardInput = FileHandle.nullDevice
            try child.run(); children[deployment.id] = child
            let birth = processStartTime(child.processIdentifier)
            guard birth > 0 else { child.terminate(); throw LaunchError.message("无法核对 Playground 进程身份。") }
            selected = .init(pid: child.processIdentifier, birth: birth, port: port, imagePort: service.port)
            processes[deployment.id] = selected
            try ConnectionFiles.write(try JSONEncoder().encode(processes), to: root.appendingPathComponent("processes.json"))
        }
        guard let selected else { return }
        let base = URL(string: "http://127.0.0.1:\(selected.port)")!
        for _ in 0..<50 {
            var request = URLRequest(url: base.appendingPathComponent("modeldock/health")); request.timeoutInterval = 1
            if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
               let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any], health["service"] as? String == "modeldock-playground", health["solutionID"] as? String == deployment.id {
                openURL(base); return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LaunchError.message("Playground 未能启动，请检查本地生图服务。")
    }
}
