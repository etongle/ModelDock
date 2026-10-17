import Foundation

private func processParent(_ pid: Int32) -> Int32 { mm_process_parent(pid) }
private func processPath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ capacity: Int32) -> Int32 { mm_process_path(pid, buffer, capacity) }
private func processArguments(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ capacity: Int32) -> Int32 { mm_process_arguments(pid, buffer, capacity) }
private func processBelongsTo(_ pid: Int32, _ birth: UInt64, _ root: Int32, _ rootBirth: UInt64) -> Int32 { mm_process_belongs_to(pid, birth, root, rootBirth) }

struct PortListener: Hashable, Sendable {
    var pid: Int32
    var birth: UInt64
    var engineID: String?
    func belongs(pid root: Int32, birth rootBirth: UInt64) -> Bool { processBelongsTo(pid, birth, root, rootBirth) == 1 }
    func belongs(to spec: ServiceSpec) -> Bool {
        guard let root = spec.pid, let rootBirth = spec.processStart else { return false }
        return processBelongsTo(pid, birth, root, rootBirth) == 1
    }
}

enum PortIdentity {
    static func snapshot(ports: Set<Int>) async -> [Int: [PortListener]] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: listeners(ports: ports))
            }
        }
    }
    static func executable(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard processPath(pid, &buffer, Int32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
    static func arguments(_ pid: Int32) -> [String] {
        var buffer = [CChar](repeating: 0, count: 65536)
        let count = processArguments(pid, &buffer, Int32(buffer.count))
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
    static func engineID(executable: String, arguments: [String]) -> String? {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if path.contains("/Cellar/splash/") { return "splash" }
        if path.contains("/engines/strata/") || name == "modeldock-strata" || (name == "strata" && path.contains("/build-metal/")) { return "strata" }
        if path.contains("/engines/audio/") { return "audio" }
        if path.contains("/engines/prism/") || path.contains("/llama.cpp-prism/") { return "prism" }
        if path.contains("/LM Studio.app/") || path.contains("/.lmstudio/") { return "lmstudio" }
        if name == "ollama" || path.contains("/Ollama.app/") { return "ollama" }
        if ["llama-server", "llama"].contains(name) { return "llama" }
        // Interpreter names and model formats do not identify a serving engine.
        let program = arguments.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }
        if program.contains("modeldock-strata") { return "strata" }
        if arguments.prefix(3).contains(where: { $0.contains("/engines/strata/") && ["server.py", "modeldock_strata.py"].contains(URL(fileURLWithPath: $0).lastPathComponent) }) { return "strata" }
        if program.contains(where: { ["mlx_lm.server", "mlx_vlm.server"].contains($0) }) || zip(arguments, arguments.dropFirst()).contains(where: { $0.0 == "-m" && ["mlx_lm.server", "mlx_vlm.server"].contains($0.1) }) { return "mlx" }
        if program.contains("audio_server.py"), arguments.prefix(3).contains(where: { $0.contains("/engines/audio/") }) { return "audio" }
        if program.contains("splash") { return "splash" }
        return nil
    }
    static func engineID(_ pid: Int32) -> String? {
        var current = pid
        for _ in 0..<16 where current > 1 {
            if let engine = engineID(executable: executable(current), arguments: arguments(current)) { return engine }
            let parent = processParent(current)
            guard parent != current else { break }; current = parent
        }
        return nil
    }
    static func listeners(ports: Set<Int>) -> [Int: [PortListener]] {
        // One process-table read covers every monitored port. Match the IPv4
        // loopback endpoint actually probed, rather than another interface.
        let text = runText("/usr/sbin/lsof", ["-nP", "-a", "-i4TCP", "-sTCP:LISTEN", "-Fpn"])
        var result: [Int: [PortListener]] = [:]; var pid: Int32?
        for line in text.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()); continue }
            guard line.first == "n", let pid, let separator = line.lastIndex(of: ":"), let port = Int(line[line.index(after: separator)...]), ports.contains(port) else { continue }
            let host = String(line[line.index(after: line.startIndex)..<separator])
            guard host == "127.0.0.1" || host == "*" else { continue }
            let birth = processStartTime(pid); guard birth > 0 else { continue }
            let listener = PortListener(pid: pid, birth: birth, engineID: engineID(pid))
            if !(result[port] ?? []).contains(listener) { result[port, default: []].append(listener) }
        }
        return result
    }
    static func name(_ id: String?) -> String {
        if id == "strata" { return "Strata" }
        switch id { case "splash": return "Splash"; case "mlx": return "MLX"; case "audio": return "MLX Audio"; case "llama": return "Llama"; case "prism": return "Prism"; case "ollama": return "Ollama"; case "lmstudio": return "LM Studio"; default: return "未识别的本地服务" }
    }
}

enum EnginePortPolicy {
    static func available(engine: Engine, base: Int, count: Int, occupied: (Int) -> Bool = NetworkProbe.portOccupied) throws -> [Int] {
        let reserved = Set(Scanner.engines().filter { $0.id != engine.id }.map(\.defaultPort))
        return try MultiModelPlanner.availablePorts(base: base, count: count) { reserved.contains($0) || occupied($0) }
    }
}
