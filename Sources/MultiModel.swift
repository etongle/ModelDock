import Foundation
import Combine

enum ModelLaunchMode { case independent, ollama, studio }
struct ModelLaunchChoice: Identifiable {
    var id: String; var name: String; var bytes: Int64; var model: LocalModel?
}
struct ModelLaunchItem: Identifiable { var id: String { model.id }; var model: LocalModel; var port: Int }
enum MultiModelPlanner {
    static func availablePorts(base: Int, count: Int, occupied: (Int) -> Bool = NetworkProbe.portOccupied) throws -> [Int] {
        guard (1024...65535).contains(base), (1...16).contains(count) else { throw LaunchError.message("请选择 1–16 个模型，并输入有效的起始端口") }
        var ports: [Int] = []
        for port in base...min(65535, base + 512) where !occupied(port) {
            ports.append(port); if ports.count == count { return ports }
        }
        throw LaunchError.message("没有足够的空闲端口，请换一个起始端口")
    }
    static func plan(engine: Engine, models: [LocalModel], base: Int, context: Int, inputMode: InputMode = .automatic, projectorPaths: [String: String] = [:], occupied: (Int) -> Bool = NetworkProbe.portOccupied) throws -> [ModelLaunchItem] {
        guard engine.independentModels, !models.isEmpty, Set(models.map(\.id)).count == models.count else { throw LaunchError.message("此引擎不能使用独立服务模式，或模型选择重复") }
        let ports = try EnginePortPolicy.available(engine: engine, base: base, count: models.count, occupied: occupied)
        return try zip(models, ports).map { model, port in _ = try LaunchBuilder.plan(engine: engine, model: model, port: port, context: context, inputMode: inputMode, projectorPath: projectorPaths[model.id]); return .init(model: model, port: port) }
    }
}
extension Engine {
    var independentModels: Bool { [.splash, .llama, .prism, .mlx, .strata, .audio].contains(kind) }
    var multiModelDescription: String {
        switch kind {
        case .ollama: return "一个服务管理多个模型；实际常驻数量由内存和加载设置决定。"
        case .lmstudio: return "通过 LM Studio 运行组件加载多个模型，共用本地服务。"
        default: return "每个模型使用独立服务和端口；可分别停止并查看资源。"
        }
    }
}
struct LoadedModel: Codable, Identifiable {
    var name: String; var size: Int64?; var size_vram: Int64?; var context_length: Int?
    var id: String { name }
}
enum NativeModelAPI {
    static func loaded(port: Int) async -> [LoadedModel]? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/ps")!); request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            struct Envelope: Decodable { var models: [LoadedModel] }
            return try JSONDecoder().decode(Envelope.self, from: data).models
        } catch { return nil }
    }
    static func loadBody(name: String, context: Int, unload: Bool = false) throws -> Data {
        guard !name.isEmpty, name.utf8.count < 500, (1024...262144).contains(context) else { throw LaunchError.message("模型或上下文设置无效") }
        return try JSONSerialization.data(withJSONObject: ["model": name, "prompt": "", "stream": false, "keep_alive": unload ? 0 : 600, "options": ["num_ctx": context]])
    }
    static func load(name: String, port: Int, context: Int, unload: Bool = false) async throws {
        guard (1024...65535).contains(port) else { throw LaunchError.message("服务端口无效") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/generate")!)
        request.httpMethod = "POST"; request.timeoutInterval = 180; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try loadBody(name: name, context: context, unload: unload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil, object["done"] as? Bool == true else { throw LaunchError.message("Ollama 未完成模型加载，请查看服务日志") }
    }
}
enum StudioModelCatalog {
    static func choices(_ text: String, models: [LocalModel], engine: Engine) throws -> [ModelLaunchChoice] {
        guard let data = text.data(using: .utf8), let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw LaunchError.message("无法读取 LM Studio 已登记的模型列表") }
        var result: [ModelLaunchChoice] = []; var seen = Set<String>()
        for entry in entries {
            let variants = entry["variants"] as? [[String: Any]] ?? []
            for item in variants.isEmpty ? [entry] : variants {
                guard let key = (item["path"] as? String) ?? (item["modelKey"] as? String) ?? (entry["modelKey"] as? String),
                      DownloadPaths.safeRelative(key), !key.hasPrefix("-"), seen.insert(key).inserted else { continue }
                let model = models.first { $0.path.hasSuffix("/" + key) || URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path.hasSuffix("/" + key) }
                if let model, !model.compatible(with: engine) { continue }
                let registered = Scanner.home.appendingPathComponent(".lmstudio/models").appendingPathComponent(key)
                if registered.pathExtension == "gguf", GGUFMetadata.read(registered).prism == true { continue }
                result.append(.init(id: key, name: (item["displayName"] as? String) ?? (entry["displayName"] as? String) ?? key, bytes: (item["sizeBytes"] as? NSNumber)?.int64Value ?? model?.bytes ?? 0, model: model))
            }
        }
        return result
    }
}
@MainActor
final class MultiModelDraft: ObservableObject, Identifiable {
    let id = UUID(); let engine: Engine; let mode: ModelLaunchMode; let choices: [ModelLaunchChoice]
    @Published var selected: Set<String>
    @Published var basePort: String
    @Published var context: Int
    @Published var inputMode: InputMode = .automatic
    @Published var projectorPaths: [String: String] = [:]
    @Published var running = false
    @Published var progress = ""
    @Published var errors: [String] = []
    @Published var done = false
    var occupied: (Int) -> Bool = NetworkProbe.portOccupied
    var selectedChoices: [ModelLaunchChoice] { choices.filter { selected.contains($0.id) } }
    var weightBytes: Int64 { selectedChoices.reduce(0) { $0 + $1.bytes } }
    var ports: [Int]? { guard let base = Int(basePort) else { return nil }; return try? EnginePortPolicy.available(engine: engine, base: base, count: selectedChoices.count, occupied: occupied) }
    init(engine: Engine, mode: ModelLaunchMode, choices: [ModelLaunchChoice], selected: Set<String>, port: Int, context: Int) {
        self.engine = engine; self.mode = mode; self.choices = choices; self.selected = selected; self.basePort = String(port); self.context = context
    }
}

extension AppStore {
    func prepareMultiModel() {
        guard !(engineID == "strata" && strata.busy), !appUpdates.applying else { message = "请等待当前模型准备或应用更新完成"; return }
        guard installation.activeEngineID != engineID && !(maintaining && maintenanceEngineID == engineID) && !preparingMulti else { return }
        preparingMulti = true
        let engine = engine; let models = compatibleModels; let port = parsedPort ?? engine.defaultPort; let context = context
        Task {
            defer { preparingMulti = false }
            let mode: ModelLaunchMode = engine.kind == .ollama ? .ollama : engine.kind == .lmstudio ? .studio : .independent
            var choices = models.map { ModelLaunchChoice(id: $0.id, name: $0.name, bytes: $0.bytes, model: $0) }
            if mode == .ollama {
                await services.refresh()
                guard services.identifies(engineID: engine.id, port: port) else { message = "端口 \(port) 的监听进程不是已确认的 Ollama 服务，请检查模型服务。"; return }
                let probe = await NetworkProbe.models(port: port, ollama: true)
                guard probe.ready else { message = "请先启动 Ollama 服务，再选择要加载的模型。"; return }
                choices = probe.models.map { name in let model = models.first { $0.repository == name }; return .init(id: name, name: name, bytes: model?.bytes ?? 0, model: model) }
            } else if mode == .studio {
                await services.refresh()
                guard let app = engine.appPath, NSRunningApplicationCheck.isRunning(app),
                      services.identifies(engineID: engine.id, port: port),
                      FileManager.default.isExecutableFile(atPath: Scanner.home.appendingPathComponent(".lmstudio/bin/lms").path),
                      await NetworkProbe.models(port: port).ready else { message = "请先打开 LM Studio 并开启本地服务，再加载多个模型。"; return }
                do {
                    let listing = try await InstallExecutor.run(.init(executable: Scanner.home.appendingPathComponent(".lmstudio/bin/lms").path, arguments: ["ls", "--json", "--variants"], title: "读取已登记模型"), log: { _ in })
                    choices = try StudioModelCatalog.choices(listing, models: models, engine: engine)
                } catch { message = error.localizedDescription; return }
            }
            let preferred = mode == .independent ? selectedModel?.id : nil
            multiModel = MultiModelDraft(engine: engine, mode: mode, choices: choices, selected: preferred.map { [$0] } ?? [], port: port, context: context)
            multiModel?.inputMode = self.inputMode
            if let model = self.selectedModel, !self.projectorPath.isEmpty { multiModel?.projectorPaths[model.id] = self.projectorPath }
            multiModel?.occupied = { [weak owner = self] in owner?.services.portReserved($0) == true || NetworkProbe.portOccupied($0) }
        }
    }
    func runMultiModel(_ draft: MultiModelDraft) {
        guard !draft.running && installation.activeEngineID != draft.engine.id && !(maintaining && maintenanceEngineID == draft.engine.id) else { return }
        guard !(draft.engine.kind == .strata && strata.busy), !appUpdates.applying else { draft.errors = ["请等待当前模型准备或应用更新完成"]; return }
        draft.errors = []; draft.done = false
        let choices = draft.selectedChoices
        guard !choices.isEmpty, choices.count <= 16, let base = Int(draft.basePort), (1024...65535).contains(base) else { draft.errors = ["请选择 1–16 个模型和有效端口"]; return }
        if draft.mode == .independent {
            do {
                let items = try MultiModelPlanner.plan(engine: draft.engine, models: choices.compactMap(\.model), base: base, context: draft.context, inputMode: draft.inputMode, projectorPaths: draft.projectorPaths, occupied: { self.services.portReserved($0) || NetworkProbe.portOccupied($0) })
                var created: [ServiceSpec] = []
                do { for item in items { created.append(try services.start(engine: draft.engine, model: item.model, port: item.port, context: draft.context, inputMode: draft.inputMode, projectorPath: draft.projectorPaths[item.model.id])) } }
                catch { for spec in created { try? services.stop(spec) }; throw error }
                draft.progress = "已提交 \(created.count) 个独立模型服务；加载状态和日志可在“模型服务”中查看。"
                selectedServiceID = created.first?.id; selectedExternal = nil; draft.done = true
            } catch { draft.errors = [error.localizedDescription] }
            return
        }
        draft.running = true
        Task {
            for (index, choice) in choices.enumerated() {
                draft.progress = "正在加载 \(index + 1)/\(choices.count)：\(choice.name)"
                do {
                    await services.refresh()
                    guard services.identifies(engineID: draft.engine.id, port: base) else { throw LaunchError.message("端口 \(base) 的引擎归属已经变化，请重新检查模型服务") }
                    if draft.mode == .ollama { try await NativeModelAPI.load(name: choice.name, port: base, context: draft.context) }
                    else {
                        let lms = Scanner.home.appendingPathComponent(".lmstudio/bin/lms").path
                        _ = try await InstallExecutor.run(.init(executable: lms, arguments: ["load", choice.id, "--context-length", String(draft.context), "--ttl", "600", "-y"], title: "加载模型"), log: { _ in })
                    }
                } catch { draft.errors.append("\(choice.name)：\(error.localizedDescription)") }
            }
            await services.refresh()
            if draft.mode == .ollama {
                let names = Set(services.loadedModels[base]?.map(\.name) ?? [])
                let count = choices.filter { names.contains($0.name) }.count
                draft.progress = "本次选择 \(choices.count) 个模型；当前实际常驻 \(count) 个。引擎可能因内存或常驻上限卸载模型，闲置保留 10 分钟。"
            } else { draft.progress = "模型加载操作完成。当前接口公布 \(services.reportedModels[base]?.count ?? 0) 个模型；闲置保留 10 分钟。" }
            draft.running = false; draft.done = true; selectedExternal = services.external.first { $0.port == base }?.port
        }
    }
}
