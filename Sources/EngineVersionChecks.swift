import Foundation

enum EngineVersionChecks {
    @MainActor static func exercise(store: AppStore, root: URL, capture: ((String) async throws -> Void)? = nil) async throws {
        try ConnectionFiles.privateDirectory(root)
        let prefix = root.appendingPathComponent("brew"), binary = prefix.appendingPathComponent("Cellar/llama.cpp/0.6.0_1/bin/llama-server"), app = root.appendingPathComponent("Llama.app")
        try ConnectionFiles.privateDirectory(binary.deletingLastPathComponent()); try ConnectionFiles.privateDirectory(prefix.appendingPathComponent("bin")); try ConnectionFiles.privateDirectory(prefix.appendingPathComponent("Caskroom/llama-app")); try ConnectionFiles.privateDirectory(app.appendingPathComponent("Contents"))
        try ConnectionFiles.write(Data("#!/bin/sh\nexit 0\n".utf8), to: binary, executable: true)
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("bin/llama-server"), withDestinationURL: binary)
        func writeApp(_ version: String) throws { try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist")) }
        try writeApp("0.44.0")
        let engine = Engine(kind: .llama, name: "Llama", version: "0.6.0_1", path: binary.path, appPath: app.path, installed: true, canServe: true, installation: "应用 / 命令行服务", description: "按组件识别安装版本", defaultPort: 9931, symbol: "sparkles")
        let release = EngineRelease(kind: .llama, version: "0.44.0", source: "Homebrew · llama.cpp + llama-app", method: .brew, components: [.init(id: "llama.cpp", name: "llama.cpp 命令行", version: "0.6.0_1"), .init(id: "llama-app", name: "Llama 桌面应用", version: "0.44.0")])
        let rows = EngineVersionPolicy.rows(engine: engine, release: release)
        try ConnectionChecks.require(rows.count == 2 && rows.allSatisfy { $0.state == .current } && rows[0].installed == "0.6.0_1" && rows[1].installed == "0.44.0", "Desktop and CLI versions were mixed")
        let latest = EngineCatalog.plan(engine: engine, release: release, brew: "/usr/bin/true", prefix: prefix.path)
        try ConnectionChecks.require(latest.commands.isEmpty, "Latest components were unnecessarily upgraded")
        store.inventory = .init(engines: [engine], models: [], storageBytes: 0, memoryBytes: 0, chip: "Apple Silicon", roots: [root.path], warnings: [], scannedAt: Date())
        store.engineID = engine.id; store.tab = .engines; store.installation.plan = latest
        try await capture?("versions-all-latest-preview")
        store.installation.plan = nil; try await Task.sleep(nanoseconds: 250_000_000); try writeApp("0.42.0")
        let partial = EngineCatalog.plan(engine: engine, release: release, brew: "/usr/bin/true", prefix: prefix.path)
        try ConnectionChecks.require(partial.commands.count == 1 && partial.commands[0].arguments.contains("llama-app") && EngineVersionPolicy.rows(engine: engine, release: release).last?.state == .update, "Latest CLI was updated with older desktop")
        store.installation.plan = partial; try await capture?("versions-desktop-update-only-preview")
        try writeApp("0.44.0"); store.installation.log = "更新 Llama 桌面应用…\n安装验证完成。\n"; store.installation.message = "已重新扫描"; store.installation.succeeded = true
        try await capture?("versions-after-update-preview")
        try ConnectionChecks.require(EngineVersionPolicy.rows(engine: engine, release: release).allSatisfy { $0.state == .current }, "Installation sheet kept stale installed version")
        for (current, available, expected) in [("0.6.0", "0.6.0_1", EngineVersionState.update), ("v1.3.1", "1.3.1", .current), ("0.7.0", "0.6.0_1", .newer), ("本地编译版", "b9000", .unknown)] { try ConnectionChecks.require(EngineVersionPolicy.state(installed: current, available: available) == expected, "Version comparison failed") }
        try ConnectionChecks.require(EngineVersionPolicy.state(installed: nil, available: "0.44.0") == .missing, "Missing component falsely latest")
        store.installation.plan = nil
        try await Task.sleep(nanoseconds: 250_000_000)
        let data = try ConnectionFiles.json(["result": "passed", "checks": ["desktop and CLI versions remain independent", "Homebrew package revision compared", "latest version has no update action", "only older component receives upgrade command", "installed result rereads actual version", "newer installed versions are not downgraded", "missing and unknown versions are distinct"], "realEnginesUpdated": false])
        try data.write(to: root.appendingPathComponent("result.json")); print(root.path)
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-version-checks").appendingPathComponent(UUID().uuidString)
        try await exercise(store: AppStore(stateDirectory: root.appendingPathComponent("state")), root: root)
    }
}
