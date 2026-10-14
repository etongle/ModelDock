import Foundation
import Darwin

@MainActor
enum SplashChecks {
    static func run() throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-splash-checks").appendingPathComponent(UUID().uuidString)
        func makeKeg(_ version: String, packed: Bool) throws -> URL {
            let keg = root.appendingPathComponent("Cellar/splash/" + version)
            for name in ["bin", "libexec/python/bin", "libexec/engine", "libexec/install"] { try FileManager.default.createDirectory(at: keg.appendingPathComponent(name), withIntermediateDirectories: true) }
            for name in ["bin/splash", "libexec/python/bin/python3", "libexec/engine/splash"] { let file = keg.appendingPathComponent(name); try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file); chmod(file.path, 0o755) }
            try Data().write(to: keg.appendingPathComponent("libexec/engine/splash.metallib"))
            try Data().write(to: keg.appendingPathComponent("libexec/install/launcher.py"))
            try Data((packed ? "formats = ['splash-packed-q4']" : "PACKAGE_REPLACEMENTS = {'splash-packed-q4': 'upstream'}").utf8).write(to: keg.appendingPathComponent("libexec/install/models.py"))
            try JSONSerialization.data(withJSONObject: ["version": version]).write(to: keg.appendingPathComponent("libexec/release.json"))
            return keg
        }
        let old = try makeKeg("1.0.2", packed: true); let new = try makeKeg("1.3.1", packed: false)
        let folder = root.appendingPathComponent("hub/models--fixture--packed/snapshots/revision")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = LocalModel(id: "packed-fixture", name: "Packed fixture", format: "Splash 4-bit", path: folder.path, kind: .language, bytes: 0, complete: true, verification: "fixture", repository: "fixture/packed", missingFiles: [], removalPath: folder.path)
        var engine = Scanner.engines().first { $0.kind == .splash }!
        engine.path = new.appendingPathComponent("bin/splash").path; engine.version = "1.3.1"; engine.canServe = true
        try FeatureChecks.require(SplashRuntime.current(engine)?.supportsPacked == false, "Modern Splash incorrectly accepts packed")
        let plan = try LaunchBuilder.plan(engine: engine, model: model, port: 29900)
        try FeatureChecks.require(plan.executable == old.appendingPathComponent("libexec/python/bin/python3").path && plan.arguments.prefix(2) == ["-u", old.appendingPathComponent("libexec/install/launcher.py").path] && plan.engineVersion == "1.0.2", "Packed startup follows opt/splash instead of pinned old runtime")
        try FeatureChecks.require(model.compatibility(with: engine).reason.contains("1.0.2"), "Legacy runtime not labeled before start")
        try FileManager.default.removeItem(at: old.appendingPathComponent("libexec/engine/splash"))
        try FeatureChecks.require(!model.compatible(with: engine) && model.compatibility(with: engine).reason.contains("没有可用旧组件"), "Missing legacy components did not block incompatible startup")
        let actual = Scanner.scan()
        guard let installed = actual.engines.first(where: { $0.kind == .splash }), let realModel = actual.models.first(where: { $0.format.hasPrefix("Splash") && $0.complete }) else { throw LaunchError.message("Existing Splash model missing") }
        let realPlan = try LaunchBuilder.plan(engine: installed, model: realModel, port: 8000)
        try FeatureChecks.require(realPlan.engineVersion == "1.0.2" && realPlan.arguments.contains("/opt/homebrew/Cellar/splash/1.0.2/libexec/install/launcher.py") && realPlan.environment["HF_HUB_OFFLINE"] == "1", "Real packed model does not use retained offline runtime")
        let report: [String: Any] = ["result": "passed", "checks": ["version capabilities from installed program files", "fixed interpreter/launcher/native component selection", "legacy format label", "missing old runtime blocks incompatible launch", "existing model plans offline with retained runtime"], "installed_splash": installed.version, "running_version": realPlan.engineVersion ?? "", "executable": realPlan.executable, "models_changed": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self)); print("Evidence: \(root.path)")
    }
}
