import Foundation
import SwiftUI

struct ModelInstanceFilter { var engineID: String; var model: LocalModel }

/// Bind an instance to a local revision, never just to a display name shared by versions.
enum ModelInstancePolicy {
    static func samePath(_ left: String, _ right: String) -> Bool {
        guard left.hasPrefix("/"), right.hasPrefix("/") else { return false }
        let l = URL(fileURLWithPath: left).standardizedFileURL.resolvingSymlinksInPath()
        let r = URL(fileURLWithPath: right).standardizedFileURL.resolvingSymlinksInPath()
        if l == r { return true }
        guard let a = FileIdentity.read(l.path), let b = FileIdentity.read(r.path) else { return false }
        return a.device == b.device && a.inode == b.inode
    }
    static func paths(_ model: LocalModel) -> [String] {
        [model.path] + model.preparedSplashModels.map(\.path) + (model.strataAssemblies ?? [])
    }
    static func ollamaName(_ name: String) -> String {
        let value = name.hasPrefix("library/") ? String(name.dropFirst(8)) : name
        return value.split(separator: "/").last?.contains(":") == true ? value : value + ":latest"
    }
    static func matches(_ spec: ServiceSpec, model: LocalModel, models: [LocalModel], loaded: [LoadedModel]) -> Bool {
        if model.matchesID(spec.modelID) { return true }
        if !spec.modelID.isEmpty, let known = models.first(where: { $0.matchesID(spec.modelID) }) { return known.id == model.id }
        if spec.engineID == "ollama", model.format == "Ollama", spec.modelID.isEmpty {
            return loaded.contains { ollamaName($0.name) == ollamaName(model.repository ?? model.name) }
        }
        return paths(model).contains { samePath(spec.modelPath, $0) }
    }
    static func matches(_ external: ObservedService, model: LocalModel, loaded: [LoadedModel]) -> Bool {
        guard external.engineID != nil else { return false }
        if external.engineID == "ollama", model.format == "Ollama" {
            return loaded.contains { ollamaName($0.name) == ollamaName(model.repository ?? model.name) }
        }
        return external.models.contains { name in model.matchesID(name) || paths(model).contains { samePath(name, $0) } }
    }
}

struct ModelInstanceCounts {
    var running = 0, stopped = 0, starting = 0, stopping = 0, failed = 0, conflicted = 0
    var total: Int { running + stopped + starting + stopping + failed + conflicted }
    var title: String { L10n.text("\(total) 个服务实例") }
    var details: String {
        [(running, "运行中"), (stopped, "已停止"), (starting, "正在加载"), (stopping, "正在停止"), (failed, "启动失败"), (conflicted, "端口冲突")]
            .filter { $0.0 > 0 }.map { String($0.0) + " " + L10n.text($0.1) }.joined(separator: " · ")
    }
}

@MainActor
extension AppStore {
    func modelServices(_ model: LocalModel, engineID: String? = nil) -> [ServiceSpec] {
        services.records.filter { spec in
            (engineID == nil || spec.engineID == engineID) && ModelInstancePolicy.matches(spec, model: model, models: models, loaded: services.loadedModels[spec.port] ?? [])
        }
    }
    func modelExternalServices(_ model: LocalModel, engineID: String? = nil) -> [ObservedService] {
        let ownedPorts = Set(modelServices(model, engineID: engineID).filter { [.running, .starting, .stopping].contains(services.status($0)) }.map(\.port))
        return services.external.filter { item in
            !ownedPorts.contains(item.port) && (engineID == nil || item.engineID == engineID) && ModelInstancePolicy.matches(item, model: model, loaded: services.loadedModels[item.port] ?? [])
        }
    }
    func modelInstanceCounts(_ model: LocalModel, engineID: String? = nil) -> ModelInstanceCounts {
        var counts = ModelInstanceCounts()
        for spec in modelServices(model, engineID: engineID) {
            switch services.status(spec) {
            case .running: counts.running += 1
            case .stopped: counts.stopped += 1
            case .starting: counts.starting += 1
            case .stopping: counts.stopping += 1
            case .failed: counts.failed += 1
            case .conflicted: counts.conflicted += 1
            }
        }
        for item in modelExternalServices(model, engineID: engineID) { if item.ready { counts.running += 1 } else { counts.conflicted += 1 } }
        return counts
    }
    func modelInstanceEngines(_ model: LocalModel) -> [String] {
        Set(modelServices(model).map(\.engineID) + modelExternalServices(model).compactMap(\.engineID)).sorted()
    }
    func showModelInstances(_ model: LocalModel, engineID: String) {
        guard engines.contains(where: { $0.id == engineID }) else { return }
        selectedModels[engineID] = model.id; chooseEngine(engineID)
        engineInstanceFilter = .init(engineID: engineID, model: model)
        engineSection = .services; tab = .engines
    }
    func visibleEngineServices(_ id: String) -> [ServiceSpec] {
        let all = engineServices(id)
        guard let filter = engineInstanceFilter, filter.engineID == id else { return all }
        let matches = Set(modelServices(filter.model, engineID: id).map(\.id))
        return all.filter { matches.contains($0.id) }
    }
    func visibleExternalEngineServices(_ id: String) -> [ObservedService] {
        guard let filter = engineInstanceFilter, filter.engineID == id else { return externalEngineServices(id) }
        return modelExternalServices(filter.model, engineID: id).sorted { $0.port < $1.port }
    }
}

@MainActor
struct ModelInstancesLink: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var engineID: String? = nil
    var compact = false
    private var engines: [String] { engineID.map { [$0] } ?? store.modelInstanceEngines(model) }
    private var fallback: String? { store.enabledEngines.first { model.compatible(with: $0) }?.id }
    var body: some View {
        if engines.count > 1 {
            Menu {
                ForEach(engines, id: \.self) { id in
                    Button { store.showModelInstances(model, engineID: id) } label: {
                        Text(verbatim: (store.engines.first { $0.id == id }?.name ?? id) + " · " + store.modelInstanceCounts(model, engineID: id).title)
                    }
                }
            } label: { label }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("model-instances-\(model.id)")
        } else {
            Button { if let id = engines.first ?? fallback { store.showModelInstances(model, engineID: id) } } label: { label }
                .buttonStyle(.borderless).disabled(engines.first == nil && fallback == nil)
                .help(L10n.format("查看 {0} 的模型实例", [model.name]))
                .accessibilityIdentifier("model-instances-\(engineID ?? "all")-\(model.id)")
        }
    }
    private var label: some View {
        let counts = store.modelInstanceCounts(model, engineID: engineID)
        return HStack(alignment: .center, spacing: 6) {
            Image(systemName: "rectangle.stack").font(.system(size: TypeScale.callout))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: counts.title).font(.system(size: TypeScale.callout, weight: .medium)).lineLimit(1)
                if !counts.details.isEmpty { Text(verbatim: counts.details).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).lineLimit(compact ? 2 : 3) }
            }
            Image(systemName: "arrow.up.right").font(.system(size: TypeScale.caption))
        }.foregroundStyle(counts.total > 0 ? Theme.linkColor : Theme.muted).padding(.vertical, 4)
            .contentShape(Rectangle()).accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.format("查看 {0} 的模型实例", [model.name]) + " · " + counts.title + " · " + counts.details)
    }
}

@MainActor
struct EngineModelCard: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var body: some View {
        HStack(spacing: 14) {
            Button { store.selectModel(model) } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.kind == .image ? "photo.badge.plus" : model.kind == .embedding ? "text.magnifyingglass" : "cube").font(.system(size: 20)).foregroundStyle(Theme.muted).frame(width: 40, height: 40).background(Theme.line, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.name).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1)
                        Text(verbatim: L10n.text("\(model.format) · \(sizeLabel(model.bytes)) · \(model.verification)")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(1)
                        ModelCapabilityBadge(capabilities: store.modelCapabilities(model))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: store.selectedModel?.id == model.id ? "checkmark.circle.fill" : "circle").foregroundStyle(store.selectedModel?.id == model.id ? Theme.linkColor : Color.secondary)
                }.padding(12).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text(model.path))
            ModelInstancesLink(store: store, model: model, engineID: store.engineID, compact: true).frame(width: 180, alignment: .leading).padding(.trailing, 12)
        }.background(store.selectedModel?.id == model.id ? Theme.selection : Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("engine-model-card-\(model.id)")
    }
}
