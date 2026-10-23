import Foundation

enum ServiceDisplayChecks {
    static func run(root: URL) throws {
        let file = root.appendingPathComponent("canonical.gguf"), alias = root.appendingPathComponent("alias.gguf")
        try Data("GGUFfixture".utf8).write(to: file); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let model = LocalModel(id: "canonical", name: "SuperQwen3.8-27b-MLX-4bit", format: "MLX", path: file.path, kind: .language, bytes: 12, complete: true, verification: "fixture", repository: "owner/SuperQwen3.8-27b-MLX-4bit", missingFiles: [], removalPath: file.path)
        let a = ServiceSpec(engineID: "splash", modelID: model.id, modelName: model.repository!, modelPath: model.path, port: 8001)
        let b = ServiceSpec(engineID: "splash", modelID: "legacy-alias", modelName: model.name, modelPath: alias.path, port: 8000)
        try ConnectionChecks.require(ModelInstancePolicy.displayName(a, models: [model]) == model.name && ModelInstancePolicy.displayName(b, models: [model]) == model.name, "One file produced different service display names")
        try ConnectionChecks.require(a.modelName == model.repository && b.modelName == model.name, "Display normalization changed saved API aliases")
        var command = a; command.modelID = "command:splash:" + a.modelName; command.modelPath = ""
        try ConnectionChecks.require(ModelInstancePolicy.displayName(command, models: [model]) == model.name, "Repository-only command instance kept a different label")
        var revision = model; revision.id = "second-revision"; revision.path = root.appendingPathComponent("second").path
        try ConnectionChecks.require(ModelInstancePolicy.displayName(command, models: [model, revision]) == command.modelName, "Ambiguous repository versions were guessed")
        var pinned = model; pinned.origin = .init(site: .huggingface, repository: model.repository!, revision: String(repeating: "a", count: 40), files: [])
        revision.origin = .init(site: .huggingface, repository: model.repository!, revision: String(repeating: "b", count: 40), files: [])
        command.launchArguments = ["--revision", String(repeating: "a", count: 40)]
        try ConnectionChecks.require(ModelInstancePolicy.displayName(command, models: [pinned, revision]) == model.name, "Pinned command revision did not resolve its display name")
        command.launchArguments = ["--revision", String(repeating: "c", count: 40)]
        try ConnectionChecks.require(ModelInstancePolicy.displayName(command, models: [pinned]) == command.modelName, "Missing pinned revision used a different version's label")
        var different = model; different.id = "different-revision"; different.name = "Another revision"; different.path = root.appendingPathComponent("different.gguf").path
        var known = b; known.modelID = different.id
        try ConnectionChecks.require(ModelInstancePolicy.displayName(known, models: [model, different]) == different.name, "Known different revision was merged by path")
        var unknown = b; unknown.modelPath = "/missing/unknown"; unknown.modelName = "Unverified API alias"
        try ConnectionChecks.require(ModelInstancePolicy.displayName(unknown, models: [model]) == unknown.modelName, "Unknown alias was guessed from the display name")
        var multi = a; multi.engineID = "ollama"; multi.modelID = ""; multi.modelName = "Ollama 多模型服务"
        try ConnectionChecks.require(ModelInstancePolicy.displayName(multi, models: [model]) == multi.modelName, "Multi-model server renamed to one model")
    }
}
