import Foundation
import Darwin

enum WebSearchConnection {
    static let name = "model_manager_web"
    static let endpoint = "https://mcp.exa.ai/mcp?tools=web_search_exa"
    static let opencode: [String: Any] = ["type": "remote", "url": endpoint, "enabled": true]
    static let pi: [String: Any] = ["url": endpoint, "enabled": true, "exposure": "direct", "description": "Search the web for current information and source URLs"]
}

enum NativeClientConfig {
    struct Result { var configuration: URL; var backups: URL; var files: [URL] }

    // Accept OpenCode JSONC without interpreting strings as comments. The
    // original bytes are backed up before serializing the merged settings.
    static func object(_ data: Data) throws -> [String: Any] {
        let chars = Array(String(decoding: data, as: UTF8.self))
        var clean: [Character] = [], index = 0, quoted = false, escaped = false
        while index < chars.count {
            let c = chars[index]
            if quoted {
                clean.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
                index += 1; continue
            }
            if c == "\"" { quoted = true; clean.append(c); index += 1; continue }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { clean.append(" "); index += 1 }; continue
            }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                clean += [" ", " "]; index += 2
                var closed = false
                while index < chars.count {
                    if index + 1 < chars.count && chars[index] == "*" && chars[index + 1] == "/" { clean += [" ", " "]; index += 2; closed = true; break }
                    clean.append(chars[index] == "\n" ? "\n" : " "); index += 1
                }
                guard closed else { throw LaunchError.message("客户端配置的注释未闭合，原文件保留") }
                continue
            }
            clean.append(c); index += 1
        }
        quoted = false; escaped = false
        for i in clean.indices {
            let c = clean[i]
            if quoted { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }; continue }
            if c == "\"" { quoted = true; continue }
            if c == "," {
                var next = i + 1; while next < clean.count && clean[next].isWhitespace { next += 1 }
                if next < clean.count && (clean[next] == "}" || clean[next] == "]") { clean[i] = " " }
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(String(clean).utf8)) as? [String: Any] else { throw LaunchError.message("客户端配置需要是 JSON 对象，原文件保留") }
        return object
    }
    static func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard object[key] != nil else { return [:] }
        guard let value = object[key] as? [String: Any] else { throw LaunchError.message("客户端配置的 \(key) 格式不兼容，原文件保留") }
        return value
    }
    static func merge(_ old: [String: Any], profile: [String: Any], client: CodingClient, provider: String, webSearch: Bool) throws -> [String: Any] {
        var result = old
        switch client {
        case .opencode:
            var providers = try dictionary(result, "provider")
            var own = try dictionary(providers, provider)
            let supplied = try dictionary(try dictionary(profile, "provider"), provider)
            var models = try dictionary(own, "models")
            for (key, value) in try dictionary(supplied, "models") { models[key] = value }
            var options = try dictionary(own, "options")
            for (key, value) in try dictionary(supplied, "options") { options[key] = value }
            own["models"] = models; own["options"] = options; own["npm"] = supplied["npm"]; own["name"] = supplied["name"]
            providers[provider] = own; result["provider"] = providers
            if let enabled = result["enabled_providers"] as? [String], !enabled.contains(provider) { result["enabled_providers"] = enabled + [provider] }
            if let disabled = result["disabled_providers"] as? [String] { result["disabled_providers"] = disabled.filter { $0 != provider } }
            if webSearch {
                var servers = try dictionary(result, "mcp"); servers[WebSearchConnection.name] = WebSearchConnection.opencode; result["mcp"] = servers
                // Enabling search does not change permissions for files or shell.
                if result["permission"] == nil || result["permission"] is [String: Any] {
                    var permissions = try dictionary(result, "permission"); permissions[WebSearchConnection.name + "_*"] = "allow"; result["permission"] = permissions
                }
            }
        case .pi:
            var providers = try dictionary(result, "providers")
            var own = try dictionary(providers, provider)
            let supplied = try dictionary(try dictionary(profile, "providers"), provider)
            let fresh = supplied["models"] as? [[String: Any]] ?? []
            if own["models"] != nil && !(own["models"] is [[String: Any]]) { throw LaunchError.message("pi 模型列表格式不兼容，原文件保留") }
            var models = own["models"] as? [[String: Any]] ?? []
            for entry in fresh {
                if let index = models.firstIndex(where: { ($0["id"] as? String) == (entry["id"] as? String) }) { models[index] = entry }
                else { models.append(entry) }
            }
            var compat = try dictionary(own, "compat")
            for (key, value) in try dictionary(supplied, "compat") { compat[key] = value }
            for key in ["baseUrl", "api", "apiKey"] { own[key] = supplied[key] }
            own["compat"] = compat; own["models"] = models; providers[provider] = own; result["providers"] = providers
        case .hermes: throw LaunchError.message("Hermes 当前使用独立连接配置；用户配置登记暂支持 pi 和 OpenCode。")
        }
        return result
    }
    static func register(_ connection: ClientConnection, root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, webSearch: Bool = false) throws -> Result {
        guard connection.client != .hermes else { throw LaunchError.message("此客户端暂使用独立配置") }
        let configRoot = home.appendingPathComponent(connection.client == .pi ? ".pi/agent" : ".config/opencode")
        try ConnectionFiles.privateDirectory(configRoot)
        let json = configRoot.appendingPathComponent(connection.client == .pi ? "models.json" : "opencode.json")
        let jsonc = configRoot.appendingPathComponent("opencode.jsonc")
        let target = connection.client == .opencode && FileManager.default.fileExists(atPath: jsonc.path) ? jsonc : json
        var result: Result?
        try transaction(configRoot: configRoot, client: connection.client, root: root) { read in
            var updates: [URL: Data] = [:]
            let profile = try object(Data(contentsOf: URL(fileURLWithPath: connection.configuration)))
            updates[target] = try ConnectionFiles.json(merge(read(target), profile: profile, client: connection.client, provider: connection.providerID, webSearch: webSearch))
            if connection.client == .pi {
                let settings = configRoot.appendingPathComponent("settings.json")
                updates[settings] = try ConnectionFiles.json(PiConnectionPolicy.settings(read(settings), provider: connection.providerID, model: connection.model, context: connection.context))
            }
            if connection.client == .pi && webSearch {
                let file = configRoot.appendingPathComponent("mcp.json")
                var mcp = try read(file), servers = try dictionary(mcp, "mcpServers")
                servers[WebSearchConnection.name] = WebSearchConnection.pi; mcp["mcpServers"] = servers
                updates[file] = try ConnectionFiles.json(mcp)
            }
            return updates
        } done: { backup, files in result = .init(configuration: target, backups: backup ?? root, files: files) }
        return result!
    }
    /// Shared write path for registering and unregistering: lock the client's config directory, read the
    /// originals, back them up, then write only if each file is still unchanged; roll back on failure.
    static func transaction(configRoot: URL, client: CodingClient, root: URL, build: (_ read: (URL) throws -> [String: Any]) throws -> [URL: Data], done: (_ backup: URL?, _ files: [URL]) -> Void) throws {
        let lockURL = configRoot.appendingPathComponent(".model-manager-config.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw LaunchError.message("无法锁定客户端配置，原文件保留") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LaunchError.message("客户端配置正在被写入，请稍后重试") }
        defer { flock(descriptor, LOCK_UN) }
        var originals: [URL: Data?] = [:]
        func read(_ url: URL) throws -> [String: Any] {
            guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw LaunchError.message("客户端配置包含符号链接，原文件保留") }
            if !FileManager.default.fileExists(atPath: url.path) { originals[url] = .some(nil); return [:] }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000 else { throw LaunchError.message("客户端配置过大，原文件保留") }
            let data = try Data(contentsOf: url); originals[url] = .some(data); return try object(data)
        }
        let updates = try build(read)
        guard !updates.isEmpty else { done(nil, []); return }
        let backup = root.appendingPathComponent("client-config-backups/" + client.rawValue + "/" + UUID().uuidString)
        try ConnectionFiles.privateDirectory(backup)
        for (file, data) in originals { if let data { try ConnectionFiles.write(data, to: backup.appendingPathComponent(file.lastPathComponent + ".backup")) } }
        try ConnectionFiles.write(try ConnectionFiles.json(["client": client.rawValue, "files": updates.keys.map(\.path), "createdAt": Date().ISO8601Format()]), to: backup.appendingPathComponent("record.json"))
        var written: [URL] = []
        do {
            for (file, data) in updates.sorted(by: { $0.key.path < $1.key.path }) {
                let prior = originals[file] ?? nil
                let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
                guard current == prior else { throw LaunchError.message("客户端配置在写入前已改变，请重试；原文件保留") }
                try ConnectionFiles.write(data, to: file); written.append(file)
            }
        } catch {
            for file in written {
                guard (try? Data(contentsOf: file)) == updates[file] else { continue }
                if let prior = originals[file] ?? nil { try? ConnectionFiles.write(prior, to: file) }
                else { try? FileManager.default.removeItem(at: file) }
            }
            throw error
        }
        done(backup, Array(updates.keys))
    }
}
