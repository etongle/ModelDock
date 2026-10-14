import Foundation

struct SplashRuntime {
    var root: URL
    var version: String
    var supportsPacked: Bool
    var python: String { root.appendingPathComponent("python/bin/python3").path }
    var launcher: String { root.appendingPathComponent("install/launcher.py").path }
    static func read(keg: URL) -> SplashRuntime? {
        let root = keg.appendingPathComponent("libexec")
        guard let release = jsonFile(root.appendingPathComponent("release.json")), let version = release["version"] as? String,
              FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("python/bin/python3").path),
              FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("engine/splash").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("engine/splash.metallib").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("install/launcher.py").path),
              let data = try? Data(contentsOf: root.appendingPathComponent("install/models.py")), data.count < 512_000 else { return nil }
        let code = String(decoding: data, as: UTF8.self)
        return .init(root: root, version: version, supportsPacked: code.contains("splash-packed") && !code.contains("PACKAGE_REPLACEMENTS"))
    }
    static func current(_ engine: Engine) -> SplashRuntime? {
        guard engine.kind == .splash else { return nil }
        let entry = URL(fileURLWithPath: engine.path).resolvingSymlinksInPath()
        guard entry.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
        return read(keg: entry.deletingLastPathComponent().deletingLastPathComponent())
    }
    static func packed(_ engine: Engine) -> SplashRuntime? {
        guard let active = current(engine) else { return nil }
        if active.supportsPacked { return active }
        let cellar = active.root.deletingLastPathComponent().deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: cellar, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap(read).filter(\.supportsPacked).sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }.first
    }
    static func packedReason(_ engine: Engine) -> String? {
        guard let active = current(engine), !active.supportsPacked else { return nil }
        if let legacy = packed(engine) { return "此 packed 模型使用保留的 Splash \(legacy.version)。已安装的 \(active.version) 使用新版模型格式。" }
        return "Splash \(active.version) 已不支持 packed 模型，且本机没有可用旧组件。请先导入新版匹配权重；现有文件保留。"
    }
}
