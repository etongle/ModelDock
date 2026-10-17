import Foundation
import CryptoKit

/// Catalog and transfer requests only send credentials to the selected provider.
final class CatalogHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static var testProtocolClasses: [AnyClass]?
    static let credentialHosts: Set<String> = ["huggingface.co", "modelscope.cn", "www.modelscope.cn", "modelscope.ai", "www.modelscope.ai", "api.github.com", "github.com", "raw.githubusercontent.com", "media.githubusercontent.com"]
    static func fetch(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        try DownloadPaths.validateURL(url)
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("ModelDock", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        if !token.isEmpty, credentialHosts.contains(url.host?.lowercased() ?? "") { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        if let protocols = testProtocolClasses { configuration.protocolClasses = protocols }
        let session = URLSession(configuration: configuration, delegate: CatalogHTTP(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LaunchError.message("模型网站未返回有效响应") }
        guard data.count <= 16_000_000 else { throw LaunchError.message("仓库文件清单过大，请使用具体模型文件的下载地址") }
        return (data, response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? DownloadPaths.validateURL(url)) != nil else { completionHandler(nil); return }
        var next = request
        if response.url?.host != url.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}

enum GitHubModels {
    typealias Reader = (URL, String) async throws -> (Data, HTTPURLResponse)
    static func isModelFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["gguf", "safetensors", "bin", "onnx", "model", "json", "txt", "tiktoken", "jinja", "vocab", "merges", "npz", "pt", "pth"].contains(ext)
    }
    static func endpoint(_ parts: [String], host: String = "api.github.com") -> URL {
        var components = URLComponents(); components.scheme = "https"; components.host = host
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        components.percentEncodedPath = "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        return components.url!
    }
    static func json(_ url: URL, token: String, read: Reader) async throws -> [String: Any] {
        let (data, response) = try await read(url, token)
        guard response.statusCode == 200 else {
            if response.statusCode == 403, response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" { throw LaunchError.message("GitHub 请求次数已达上限，请稍后重试或填写访问令牌。") }
            throw LaunchError.message([401, 403].contains(response.statusCode) ? "仓库需要访问授权，请填写已获许可的访问令牌。" : "读取模型仓库失败（HTTP \(response.statusCode)）")
        }
        guard data.count <= 16_000_000, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LaunchError.message("模型仓库清单格式无法识别") }
        return result
    }
    static func listing(_ url: URL, token: String, read: Reader = CatalogHTTP.fetch) async throws -> RemoteListing {
        let host = url.host?.lowercased() ?? ""
        var parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { throw LaunchError.message("请输入完整的 GitHub 仓库、文件或 Release 地址") }
        let repository = parts[0] + "/" + (parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1])
        guard ModelOrigin.validRepository(repository) else { throw LaunchError.message("请输入完整的 GitHub 仓库、文件或 Release 地址") }
        let repo = repository.components(separatedBy: "/"), base = ["repos"] + repo
        if host == "media.githubusercontent.com", parts.count > 2, parts[0] == "media" { throw LaunchError.message("请使用 GitHub 仓库或单文件地址") }
        if host == "github.com" || host == "www.github.com", parts.count > 2, parts[2] == "releases" {
            return try await release(parts, repository: repository, token: token, read: read)
        }
        if host == "raw.githubusercontent.com" { parts.insert("blob", at: 2); if parts.count > 4, parts[3] == "refs", ["heads", "tags"].contains(parts[4]) { parts.removeSubrange(3...4) } }
        if host == "media.githubusercontent.com" { throw LaunchError.message("请使用 GitHub 仓库或单文件地址") }
        if parts.count > 2, parts[2] == "raw" { parts[2] = "blob"; if parts.count > 4, parts[3] == "refs", ["heads", "tags"].contains(parts[4]) { parts.removeSubrange(3...4) } }
        guard parts.count == 2 || (parts.count >= 4 && ["tree", "blob"].contains(parts[2])) else { throw LaunchError.message("请输入完整的 GitHub 仓库、文件或 Release 地址") }
        let metadata = try await json(endpoint(base), token: token, read: read)
        let defaultBranch = metadata["default_branch"] as? String ?? "main"
        var ref = defaultBranch, scope = "", commit: [String: Any]?
        if parts.count >= 4 {
            let suffix = Array(parts.dropFirst(3))
            // Branch names may contain slashes. Resolve the longest existing ref.
            guard suffix.count <= 32 else { throw LaunchError.message("GitHub 文件路径过长") }
            for length in stride(from: suffix.count, through: 1, by: -1) {
                let candidate = suffix.prefix(length).joined(separator: "/")
                let address = endpoint(base + ["commits", candidate])
                let (data, response) = try await read(address, token)
                if response.statusCode == 404 || response.statusCode == 422 { continue }
                guard response.statusCode == 200 else { _ = try await json(address, token: token, read: read); continue }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LaunchError.message("模型仓库清单格式无法识别") }
                ref = candidate; scope = suffix.dropFirst(length).joined(separator: "/"); commit = object; break
            }
            guard commit != nil else { throw LaunchError.message("GitHub 分支、标签或文件不存在，请检查地址") }
        }
        if commit == nil { commit = try await json(endpoint(base + ["commits", ref]), token: token, read: read) }
        guard let sha = commit?["sha"] as? String, sha.count == 40, sha.allSatisfy(\.isHexDigit), let detail = commit?["commit"] as? [String: Any], let tree = detail["tree"] as? [String: Any], let treeSHA = tree["sha"] as? String else { throw LaunchError.message("模型仓库清单格式无法识别") }
        var components = URLComponents(url: endpoint(base + ["git", "trees", treeSHA]), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "recursive", value: "1")]
        let object = try await json(components.url!, token: token, read: read)
        guard object["truncated"] as? Bool != true else { throw LaunchError.message("GitHub 仓库清单不完整，请使用 Release 或具体文件地址") }
        guard let entries = object["tree"] as? [[String: Any]] else { throw LaunchError.message("模型仓库清单格式无法识别") }
        let single = parts.count > 2 && parts[2] == "blob"
        var files: [RemoteFile] = []
        for entry in entries {
            guard entry["type"] as? String == "blob", ["100644", "100755"].contains(entry["mode"] as? String ?? ""), let path = entry["path"] as? String, DownloadPaths.safeRelative(path), scope.isEmpty || (single ? path == scope : path.hasPrefix(scope + "/")) else { continue }
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            var file = RemoteFile(path: path, url: endpoint(repo + [sha] + path.components(separatedBy: "/"), host: "raw.githubusercontent.com"), bytes: size)
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if size > 0 && size <= 1024 && ["gguf", "safetensors", "bin", "onnx", "model", "npz", "pt", "pth"].contains(ext) {
                let (data, response) = try await read(file.url, token)
                guard response.statusCode == 200 else { throw LaunchError.message("无法读取 GitHub 模型文件，请检查访问权限") }
                if String(data: data, encoding: .utf8)?.hasPrefix("version https://git-lfs.github.com/spec/v1") == true && lfsPointer(data) == nil { throw LaunchError.message("模型仓库清单格式无法识别") }
                if let pointer = lfsPointer(data) {
                    file.url = endpoint(["media"] + repo + [sha] + path.components(separatedBy: "/"), host: "media.githubusercontent.com")
                    file.bytes = pointer.bytes; file.sha256 = pointer.sha256
                }
            }
            files.append(file)
        }
        guard !files.isEmpty else { throw LaunchError.message("仓库中没有可下载的文件") }
        let source = endpoint(repo + [single ? "blob" : "tree", ref] + (scope.isEmpty ? [] : scope.components(separatedBy: "/")), host: "github.com")
        return .init(site: .github, repository: repository, revision: sha, files: files.sorted { $0.path < $1.path }, preferred: single ? scope : nil, sourceURL: source.absoluteString)
    }
    static func lfsPointer(_ data: Data) -> (sha256: String, bytes: Int64)? {
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8), text.hasPrefix("version https://git-lfs.github.com/spec/v1\n") else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard let oid = lines.first(where: { $0.hasPrefix("oid sha256:") }).map({ String($0.dropFirst(11)) }), oid.count == 64, oid.allSatisfy(\.isHexDigit), let size = lines.first(where: { $0.hasPrefix("size ") }).flatMap({ Int64($0.dropFirst(5)) }), size > 0 else { return nil }
        return (oid.lowercased(), size)
    }
    static func release(_ parts: [String], repository: String, token: String, read: Reader) async throws -> RemoteListing {
        let repo = repository.components(separatedBy: "/"), base = ["repos"] + repo + ["releases"]
        var route = ["latest"], preferred: String?
        if parts.count > 3, ["tag", "download"].contains(parts[3]) {
            guard parts.count >= (parts[3] == "download" ? 6 : 5) else { throw LaunchError.message("请输入完整的 GitHub 仓库、文件或 Release 地址") }
            let tagParts = parts[3] == "download" ? Array(parts.dropFirst(4).dropLast()) : Array(parts.dropFirst(4))
            route = ["tags", tagParts.joined(separator: "/")]
            if parts[3] == "download" { preferred = parts.last }
        } else if parts.count == 6 && parts[3] == "latest" && parts[4] == "download" { preferred = parts[5] }
        else if parts.count > 3 && (parts[3] != "latest" || parts.count != 4) { throw LaunchError.message("请使用 GitHub Release 的标签或下载地址") }
        let object = try await json(endpoint(base + route), token: token, read: read)
        guard let assets = object["assets"] as? [[String: Any]], let tag = object["tag_name"] as? String, let releaseID = object["id"] as? NSNumber else { throw LaunchError.message("模型仓库清单格式无法识别") }
        let files = assets.compactMap { asset -> RemoteFile? in
            guard let name = asset["name"] as? String, DownloadPaths.safeRelative(name), !name.contains("/"), let id = asset["id"] as? NSNumber else { return nil }
            let digest = asset["digest"] as? String
            let sha = digest?.hasPrefix("sha256:") == true ? String(digest!.dropFirst(7)) : nil
            return .init(path: name, url: endpoint(base + ["assets", id.stringValue]), bytes: (asset["size"] as? NSNumber)?.int64Value ?? 0, sha256: sha, accept: "application/octet-stream")
        }
        guard !files.isEmpty, preferred == nil || files.contains(where: { $0.path == preferred }) else { throw LaunchError.message("此 Release 没有可下载的模型附件") }
        let identity = files.sorted { $0.path < $1.path }.map { "\($0.path):\($0.url):\($0.bytes):\($0.sha256 ?? "")" }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return .init(site: .github, repository: repository, revision: "release-\(releaseID)-\(hash)", files: files.sorted { $0.path < $1.path }, preferred: preferred, sourceURL: endpoint(repo + ["releases", "tag", tag], host: "github.com").absoluteString)
    }
}
