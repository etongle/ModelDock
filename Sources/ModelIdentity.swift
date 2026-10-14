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
        if splashSelection != nil { return [self] }
        return (splashRegistrations ?? []).map { $0.model(association: association) }
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
        var result = models.filter { $0.splashSelection == nil }
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
            } else if !standalone.contains(where: { $0.path == assembly.path }) { standalone.append(assembly) }
        }
        return result + standalone
    }
}

@MainActor struct PreparedEngineComponentsView: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var body: some View {
        if let registrations = model.splashRegistrations, !registrations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: L10n.text("引擎配套组件")).font(.system(size: 18, weight: .semibold))
                Text(verbatim: L10n.text("Splash 与 MLX 共用本版本主权重；Splash 的草稿、视觉和配置登记单独保留。")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                ForEach(registrations, id: \.path) { item in
                    HStack { StateLabel(title: item.complete ? "Splash 已准备" : "Splash 组件需修复", color: item.complete ? .green : .orange); Spacer(); Button(L10n.text("查看组件目录")) { store.reveal(item.path) }.buttonStyle(.bordered) }
                    Text(verbatim: L10n.text(item.vision == "none" ? "Splash 输入：文本" : "Splash 输入：文本 / 图片 / 文件")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }.padding(18).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
