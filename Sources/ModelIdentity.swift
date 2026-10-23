import Foundation
import SwiftUI

struct SplashRegistration: Codable, Hashable {
    var id: String
    var aliases: [String]
    var path: String
    var selection: String
    var name: String
    var format: String
    var bytes: Int64
    var complete: Bool
    var missing: [String]
    var origin: ModelOrigin?
    var vision: String?
    init(_ model: LocalModel) {
        id = model.id; aliases = [model.id]; path = model.path; selection = model.splashSelection ?? model.path
        name = model.name; format = model.format; bytes = model.bytes; complete = model.complete
        missing = model.missingFiles; origin = model.origin; vision = model.splashVision
    }
    func model(association: ModelAssociation? = nil) -> LocalModel {
        .init(id: id, name: name, format: format, path: path, kind: .language, bytes: bytes, complete: complete, verification: complete ? "Splash 配套组件齐全" : "Splash 配套组件需修复", repository: name, missingFiles: missing, removalPath: selection, origin: origin, splashSelection: selection, splashVision: vision, association: association)
    }
}
extension LocalModel {
    var preparedSplashModels: [LocalModel] {
        if let registrations = splashRegistrations, !registrations.isEmpty { return registrations.map { $0.model(association: association) } }
        return splashSelection != nil ? [self] : []
    }
    func preparedForSplash(_ mode: InputMode = .automatic) -> LocalModel? {
        preparedSplashModels.sorted {
            if $0.complete != $1.complete { return $0.complete }
            if ($0.splashVision == "none") != ($1.splashVision == "none") { return $0.splashVision != "none" }
            return $0.path < $1.path
        }.first { mode != .multimodal || $0.splashVision != "none" }
    }
    func matchesID(_ candidate: String) -> Bool { id == candidate || (splashRegistrations ?? []).contains { $0.aliases.contains(candidate) } }
}

enum ModelIdentity {
    private static func physical(_ path: String) -> String {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        if let identity = FileIdentity.read(file.path) { return "\(identity.device):\(identity.inode)" }
        return file.path
    }
    static func weights(_ model: LocalModel) -> Set<String> {
        if let config = model.strataConfig, let record = jsonFile(URL(fileURLWithPath: config)), let main = StrataModelCatalog.argument("--native", in: record) { return [physical(main)] }
        if model.splashSelection != nil, let files = jsonFile(URL(fileURLWithPath: model.path).appendingPathComponent("model.json"))?["files"] as? [String: [String: Any]] {
            return Set(files.compactMap { name, entry in
                guard name.hasPrefix("target/"), ["safetensors", "gguf"].contains(URL(fileURLWithPath: name).pathExtension), !name.lowercased().contains("mmproj"), let path = entry["path"] as? String, path.hasPrefix("/") else { return nil }
                return physical(path)
            })
        }
        if model.format.hasPrefix("GGUF") { return [physical(model.path)] }
        let folder = URL(fileURLWithPath: model.folder)
        if let index = jsonFile(folder.appendingPathComponent("model.safetensors.index.json")), let map = index["weight_map"] as? [String: String] {
            return Set(map.values.filter(DownloadPaths.safeRelative).map { physical(folder.appendingPathComponent($0).path) })
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path) { return [physical(folder.appendingPathComponent("model.safetensors").path)] }
        return []
    }
    static func coalesce(_ models: [LocalModel]) -> [LocalModel] {
        var result = models.filter { $0.splashSelection == nil && $0.strataConfig == nil }
        let weightSets = result.map(weights)
        var standalone = [LocalModel]()
        for assembly in models where assembly.splashSelection != nil {
            let source = ModelOrigin.read(assembly), signature = weights(assembly)
            let index = result.indices.first { index in
                guard result[index].kind == .language, let origin = ModelOrigin.read(result[index]), let source,
                      !origin.revision.isEmpty, origin.site == source.site, origin.repository == source.repository, origin.revision == source.revision,
                      !signature.isEmpty else { return false }
                return weightSets[index] == signature
            }
            if let index {
                var registrations = result[index].splashRegistrations ?? []
                if let existing = registrations.firstIndex(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: assembly.path).resolvingSymlinksInPath().path }) {
                    registrations[existing].aliases = Array(Set(registrations[existing].aliases + [assembly.id])).sorted()
                } else { registrations.append(.init(assembly)) }
                result[index].splashRegistrations = registrations
            } else {
                // Text/vision selections are preparations of the same source weights, even
                // when the raw snapshot is temporarily missing. Keep every launch alias.
                let index = standalone.indices.first { i in
                    if URL(fileURLWithPath: standalone[i].path).resolvingSymlinksInPath() == URL(fileURLWithPath: assembly.path).resolvingSymlinksInPath() { return true }
                    guard standalone[i].splashSelection != nil, let origin = ModelOrigin.read(standalone[i]), let source,
                          !source.revision.isEmpty, origin.site == source.site, origin.repository == source.repository,
                          origin.revision == source.revision, standalone[i].format == assembly.format, !signature.isEmpty else { return false }
                    return weights(standalone[i]) == signature
                }
                if let index {
                    var registrations = standalone[index].splashRegistrations ?? [.init(standalone[index])]
                    if let alias = registrations.firstIndex(where: { $0.path == assembly.path }) {
                        registrations[alias].aliases = Array(Set(registrations[alias].aliases + [assembly.id])).sorted()
                    } else { registrations.append(.init(assembly)) }
                    if (assembly.complete && !standalone[index].complete) || (assembly.complete == standalone[index].complete && assembly.splashVision != "none" && standalone[index].splashVision == "none") { standalone[index] = assembly }
                    standalone[index].splashRegistrations = registrations
                } else { var item = assembly; item.splashRegistrations = [.init(assembly)]; standalone.append(item) }
            }
        }
        for assembly in models where assembly.strataConfig != nil {
            let signature = weights(assembly)
            if let index = result.indices.first(where: { !signature.isEmpty && weights(result[$0]) == signature }) {
                result[index].strataAssemblies = Array(Set((result[index].strataAssemblies ?? []) + [assembly.path])).sorted()
            } else if !standalone.contains(where: { $0.path == assembly.path }) { standalone.append(assembly) }
        }
        return result + standalone
    }
}
