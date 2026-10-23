import Foundation

enum SplashRecommendationChecks {
    static func run(root: URL) throws {
        func require(_ condition: Bool, _ message: String) throws { try ConnectionChecks.require(condition, message) }
        let entries = SplashRecommendations.families.flatMap(\.variants)
        try require(entries.count == 8 && Set(entries.map(\.reference)).count == 8, "Official variants missing or duplicated")
        for item in entries {
            try require(ModelOrigin.validRepository(item.reference.components(separatedBy: ":")[0]), "Invalid official model reference")
        }
        let flash = SplashRecommendations.families.first { $0.name == "Qwen3.8-Flash-Next" }!.variants[0]
        try require(flash.reference == "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0", "Flash-Next is not the official GGUF example")
        try require(SplashRecommendations.versionIssue(flash, version: "1.3.2") != nil && SplashRecommendations.versionIssue(flash, version: "1.4.0") == nil, "Flash-Next version requirement ignored")
        try require(SplashRecommendations.hardwareIssue(chip: "Apple M2 Max", os: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)) != nil, "Unsupported official GPU offered")
        try require(SplashRecommendations.hardwareIssue(chip: "Apple M4 Max", os: .init(majorVersion: 26, minorVersion: 3, patchVersion: 0)) != nil, "Unsupported OS offered")
        try require(SplashRecommendations.hardwareIssue(chip: "Apple M4 Max", os: .init(majorVersion: 27, minorVersion: 0, patchVersion: 1)) == nil, "Supported hardware blocked")
        let keg = root.appendingPathComponent("Cellar/splash/1.4.0"), libexec = keg.appendingPathComponent("libexec")
        for subdirectory in ["bin", "libexec/python/bin", "libexec/engine", "libexec/install"] { try FileManager.default.createDirectory(at: keg.appendingPathComponent(subdirectory), withIntermediateDirectories: true) }
        for path in [keg.appendingPathComponent("bin/splash"), libexec.appendingPathComponent("python/bin/python3"), libexec.appendingPathComponent("engine/splash")] { try ConnectionFiles.write(Data("#!/bin/sh\nexit 0\n".utf8), to: path, executable: true) }
        try Data().write(to: libexec.appendingPathComponent("engine/splash.metallib"))
        try ConnectionFiles.write(Data(), to: libexec.appendingPathComponent("install/launcher.py"))
        try Data("PACKAGE_REPLACEMENTS = {}".utf8).write(to: libexec.appendingPathComponent("install/models.py"))
        try ConnectionFiles.json(["version": "1.4.0"]).write(to: libexec.appendingPathComponent("release.json"))
        let engine = Engine(kind: .splash, name: "Splash", version: "1.4.0", path: keg.appendingPathComponent("bin/splash").path, installed: true, canServe: true, installation: "fixture", description: "fixture", defaultPort: 8000, symbol: "water.waves")
        for variant in entries {
            let parsed = try ServiceCommand.parse(SplashRecommendations.command(variant, engine: engine, port: 29001), engine: engine, models: [])
            try require(parsed.modelName == variant.reference && parsed.downloadsModel && parsed.port == 29001 && parsed.mode == .automatic, "Recommendation lost exact variant or disabled vision")
            try require(!parsed.plan.arguments.contains("--draft-model"), "Recommendation forced a mismatched draft")
        }
        try ConnectionFiles.json(["result": "passed", "checks": ["official repositories and quantizations", "Flash-Next requires 1.4 and stays GGUF", "M3 and macOS 26.4 requirements", "all 8 commands parse with exact model selector", "automatic matching draft and vision preserved"], "realModelDownloads": false]).write(to: root.appendingPathComponent("splash-recommendations.json"))
    }
}
