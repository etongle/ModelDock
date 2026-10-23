import Foundation
import Combine

enum SolutionSection: String, CaseIterable { case overview = "概览", configuration = "配置", instances = "实例", maintenance = "维护" }
enum SolutionQuality: String, Codable, CaseIterable { case light = "轻量", balanced = "均衡", quality = "高质量" }
enum SolutionRole: String, Codable { case asr = "语音识别", text = "文字翻译", chat = "对话模型", vision = "视觉模型", tts = "语音合成", image = "图片生成" }
struct SolutionModel: Hashable {
    var repository: String; var revision: String
    var address: String { "https://huggingface.co/" + repository + "/tree/" + revision }
}
struct SolutionDefinition: Identifiable {
    var id: String; var title: String; var subtitle: String; var symbol: String; var roles: [SolutionRole]
    func roles(for draft: SolutionDraft) -> [SolutionRole] { roles.filter { $0 != .tts || draft.speechOutput != false } }
}
enum SolutionCatalog {
    static let all: [SolutionDefinition] = [
        .init(id: "voice-translation", title: "多语言实时翻译", subtitle: "麦克风字幕 · 音频翻译 · 可选配音", symbol: "waveform", roles: [.asr, .text, .tts]),
        .init(id: "transcription", title: "语音转写", subtitle: "音频文件转文字", symbol: "doc.text", roles: [.asr]),
        .init(id: "coding", title: "本地编程助手", subtitle: "模型服务与编程客户端接入", symbol: "chevron.left.forwardslash.chevron.right", roles: [.chat]),
        .init(id: "image-generation", title: "本地生图", subtitle: "Qwen Image 2.1 · Turbo 8 步 · 可替换模型", symbol: "photo.badge.plus", roles: [.image]),
        .init(id: "vision", title: "图片与文档问答", subtitle: "视觉模型与配套组件", symbol: "photo", roles: [.vision])
    ]
    static var visible: [SolutionDefinition] { all.filter { ["voice-translation", "image-generation"].contains($0.id) } }
    static func model(_ role: SolutionRole, quality: SolutionQuality) -> SolutionModel {
        switch role {
        case .asr:
            return quality == .light ? .init(repository: "mlx-community/Qwen3-ASR-0.6B-8bit", revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f") : .init(repository: "mlx-community/Qwen3-ASR-1.7B-8bit", revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55")
        case .tts:
            return quality == .quality ? .init(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48") : .init(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16", revision: "1eccf1cb2519b5a4e8a95b5f0544f3303568164f")
        case .image: return .init(repository: ImageModelPolicy.repository, revision: ImageModelPolicy.revision)
        case .text, .chat, .vision: return SolutionRecommendations.baseline
        }
    }
    static func engine(_ role: SolutionRole) -> String { role == .image ? "mflux" : [.asr, .tts].contains(role) ? "audio" : "mlx" }
}
struct SolutionDraft: Codable, Equatable {
    var quality: SolutionQuality = .balanced
    var language = "English"
    /// Values pin an inventory model or an explicit service + API model; never a display-name match.
    var localChoices: [String: String] = [:]
    var destination: String?
    var sourceLanguage: String?
    var speechOutput: Bool?
}
struct SolutionComponent: Codable, Identifiable {
    var id: String { role.rawValue }
    var role: SolutionRole
    var engineID: String
    var modelID: String?
    var modelPath: String?
    var repository: String
    var revision: String
    var downloadID: String?
    var ownsDownload = false
    var serviceID: String?
    var ownsConfiguration = false
    var serviceBinding: SolutionServiceBinding? = nil
}
struct SolutionProcess: Codable { var serviceID: String; var pid: Int32; var birth: UInt64 }
enum SolutionInstallState: String, Codable { case preparing, installing, downloading, paused, configured, failed }
struct SolutionDeployment: Codable, Identifiable {
    var id = UUID().uuidString
    var solutionID: String
    var draft: SolutionDraft
    var created = Date()
    var components: [SolutionComponent] = []
    var state: SolutionInstallState = .preparing
    var stage = "正在检查方案…"
    var error: String?
    var log = ""
    var processes: [SolutionProcess] = []
    var progress: SolutionPreparationProgress?
}
private struct SolutionState: Codable { var drafts: [String: SolutionDraft] = [:]; var deployments: [SolutionDeployment] = [] }
struct SolutionLocalChoice: Identifiable {
    var engine: Engine; var model: LocalModel
    var id: String { engine.id + "\n" + model.id }
}

@MainActor final class SolutionController: ObservableObject {
    @Published var selectedID = "voice-translation"
    @Published var search = ""
    @Published var section: SolutionSection = .configuration
    @Published var drafts: [String: SolutionDraft] = [:]
    @Published var deployments: [SolutionDeployment] = []
    @Published var preparingID: String?
    @Published var message: String?
    @Published var editingID: String?
    @Published var selectedDeploymentID: String?
    @Published var startingIDs = Set<String>()
    @Published var removingIDs = Set<String>()
    @Published var audioVersions: [String: Int] = [:]
    var audioProcessStarts: [String: UInt64] = [:]
    var cleanupEnginePlanner: ((Engine, Inventory) async -> MaintenancePlan)?
    var cleanupTrash: ((URL) async throws -> Void)?
    var startOperations: [String: Task<Void, Never>] = [:]
    var autoStartRequests = Set<String>()
    let directory: URL
    var operation: Task<Void, Never>?
    var catalogLoader: ((String, String) async throws -> RemoteListing)?
    var installEngine: ((Engine, EngineRelease) async throws -> Void)?
    var releaseLoader: ((EngineKind) async throws -> EngineRelease)?
    private var completing = Set<String>()
    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("solutions.json")), let state = try? JSONDecoder().decode(SolutionState.self, from: data) {
            drafts = state.drafts; deployments = state.deployments
            for index in deployments.indices where [.preparing, .installing, .downloading].contains(deployments[index].state) { deployments[index].state = .paused; deployments[index].stage = "已暂停，可继续安装" }
        }
    }
    var definition: SolutionDefinition { SolutionCatalog.all.first { $0.id == selectedID } ?? SolutionCatalog.all[0] }
    var draft: SolutionDraft { drafts[selectedID] ?? .init() }
    var latest: SolutionDeployment? {
        deployments.first { $0.id == selectedDeploymentID && $0.solutionID == selectedID } ?? deployments.last { $0.solutionID == selectedID }
    }
    var roles: [SolutionRole] { definition.roles(for: draft) }
    func usesCurrentRecommendations(_ deployment: SolutionDeployment) -> Bool {
        deployment.components.allSatisfy { SolutionRecommendations.isCurrent($0, draft: deployment.draft) }
    }
    func setDraft(_ value: SolutionDraft) { drafts[selectedID] = value; save() }
    @discardableResult func save() -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try JSONEncoder().encode(SolutionState(drafts: drafts, deployments: deployments)).write(to: directory.appendingPathComponent("solutions.json"), options: .atomic); return true }
        catch { message = "方案配置保存失败：" + error.localizedDescription; return false }
    }
    func choices(_ role: SolutionRole, store: AppStore) -> [SolutionLocalChoice] {
        store.models.filter { model in
            guard model.complete else { return false }
            switch role {
            case .image: return model.kind == .image && ImageModelPolicy.recognizes(URL(fileURLWithPath: model.path))
            case .asr: return AudioModelPolicy.task(model) == "asr"
            case .tts: return AudioModelPolicy.supportsReference(model)
            case .text: return model.kind == .language && TranslationLanguages.modelIssue(model) == nil
            case .chat: return model.kind == .language
            case .vision: return model.kind == .language && store.modelCapabilities(model).inputs.contains("image")
            }
        }.flatMap { model in
            store.enabledEngines.filter { engine in
                guard engine.independentModels else { return false }
                guard model.compatibility(with: engine).level == .direct else { return false }
                if role == .vision { return ModalityPolicy.nativeMultimodalReason(engine: engine, model: model, projector: model.companion) == nil }
                return true
            }.map { SolutionLocalChoice(engine: $0, model: model) }
        }.sorted { left, right in
            let recommendedLeft = SolutionRecommendations.matches(left.model, role: role, draft: draft)
            let recommendedRight = SolutionRecommendations.matches(right.model, role: role, draft: draft)
            if recommendedLeft != recommendedRight { return recommendedLeft }
            let l = store.modelInstanceCounts(left.model, engineID: left.engine.id).running > 0
            let r = store.modelInstanceCounts(right.model, engineID: right.engine.id).running > 0
            if l != r { return l }
            if left.engine.canServe != right.engine.canServe { return left.engine.canServe }
            return left.id < right.id
        }
    }
    func selection(_ role: SolutionRole, draft: SolutionDraft, store: AppStore) throws -> SolutionComponent {
        if let chosen = draft.localChoices[role.rawValue], chosen.hasPrefix(SolutionServiceChoice.prefix) {
            guard let service = serviceChoices(role, store: store).first(where: { $0.id == chosen }) else { throw LaunchError.message("所选服务已删除或模型配置已变化，请重新选择替代服务。") }
            return serviceComponent(service, role: role, store: store)
        }
        let candidates = choices(role, store: store)
        if role == .image, draft.localChoices[role.rawValue] == nil, let service = serviceChoices(role, store: store).first {
            return serviceComponent(service, role: role, store: store)
        }
        if let chosen = draft.localChoices[role.rawValue], !chosen.isEmpty, chosen != "download", chosen != SolutionRecommendations.lightweightChoice, chosen != "heretic" {
            guard let local = candidates.first(where: { $0.id == chosen }) else { throw LaunchError.message("所选模型已移动、不完整或基座已禁用，请重新选择") }
            return .init(role: role, engineID: local.engine.id, modelID: local.model.id, modelPath: local.model.path, repository: local.model.repository ?? local.model.name, revision: local.model.origin?.revision ?? "")
        }
        let source = SolutionRecommendations.source(role, draft: draft)
        let local = candidates.first { SolutionRecommendations.matches($0.model, role: role, draft: draft) }
        if draft.localChoices[role.rawValue] != "download", let local {
            return .init(role: role, engineID: local.engine.id, modelID: local.model.id, modelPath: local.model.path, repository: local.model.repository ?? local.model.name, revision: local.model.origin?.revision ?? "")
        }
        return .init(role: role, engineID: SolutionCatalog.engine(role), repository: source.repository, revision: source.revision)
    }
    func install(store: AppStore, launchWhenReady: Bool = false) {
        guard store.inventory != nil, !store.scanning else { message = "正在扫描模型文件…"; return }
        guard preparingID == nil, removingIDs.isEmpty, !store.installation.running, !store.maintaining else { message = "请等待当前引擎操作完成"; return }
        let definition = definition, draft = draft
        if editingID == nil, let existing = deployments.last(where: { $0.solutionID == definition.id && $0.draft == draft && $0.state != .configured && usesCurrentRecommendations($0) }) {
            if launchWhenReady { autoStartRequests.insert(existing.id) }
            retry(existing.id, store: store); return
        }
        do {
            guard TranslationLanguages.targets.contains(draft.language) else { throw LaunchError.message("请选择支持的目标语言") }
            let components = try definition.roles(for: draft).map { try selection($0, draft: draft, store: store) }
            guard components.allSatisfy({ store.engineEnabled($0.engineID) }) else { throw LaunchError.message("方案需要的基座已禁用，请在全局引擎设置中启用") }
            if let editingID { try replaceConfiguration(editingID, components: components, draft: draft, store: store, launchWhenReady: launchWhenReady); return }
            var deployment = SolutionDeployment(solutionID: definition.id, draft: draft); deployment.components = components
            deployments.append(deployment); guard save() else { deployments.removeLast(); return }
            selectedDeploymentID = deployment.id
            if launchWhenReady { autoStartRequests.insert(deployment.id) }
            perform(deployment.id, store: store)
        } catch { message = error.localizedDescription }
    }
    func retry(_ id: String, store: AppStore) {
        guard preparingID == nil, removingIDs.isEmpty, !store.installation.running, !store.maintaining, let index = deployments.firstIndex(where: { $0.id == id }), deployments[index].state != .configured else { return }
        deployments[index].state = .preparing; deployments[index].error = nil
        perform(id, store: store)
    }
    func update(_ id: String, _ body: (inout SolutionDeployment) -> Void) {
        guard let index = deployments.firstIndex(where: { $0.id == id }) else { return }; body(&deployments[index]); save()
    }
    func perform(_ id: String, store: AppStore) {
        preparingID = id
        operation = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { preparingID = nil; operation = nil }
            do {
                guard let current = deployments.first(where: { $0.id == id }) else { return }
                var listings: [String: RemoteListing] = [:]
                let unresolved = current.components.filter { component in component.serviceBinding == nil && component.modelPath == nil && (component.downloadID == nil || !store.downloads.jobs.contains(where: { $0.id == component.downloadID })) }
                update(id) { $0.state = .preparing; $0.stage = "正在解析并固定模型版本…"; $0.progress = .init(phase: .checking, total: unresolved.count) }
                for component in unresolved {
                    update(id) { $0.progress?.detail = component.repository }
                    let source = SolutionModel(repository: component.repository, revision: component.revision)
                    let listing = try await (catalogLoader ?? ModelCatalog.listing)(source.address, store.downloads.accessTokens.credential(for: source.address))
                    guard listing.repository == component.repository && listing.revision == component.revision else { throw LaunchError.message("方案仓库版本与固定清单不一致") }
                    listings[component.id] = listing; try Task.checkCancellation()
                    update(id) { $0.progress?.completed += 1 }
                }
                let root = URL(fileURLWithPath: current.draft.destination ?? store.downloads.destination).standardizedFileURL.resolvingSymlinksInPath()
                var volume = root
                while !FileManager.default.fileExists(atPath: volume.path) && volume.path != "/" { volume.deleteLastPathComponent() }
                let required = listings.values.reduce(Int64(0)) { $0 + $1.files.reduce(Int64(0)) { $0 + max(0, $1.bytes) } }
                if let free = (try? FileManager.default.attributesOfFileSystem(forPath: volume.path)[.systemFreeSize]) as? NSNumber, free.int64Value < required { throw LaunchError.message("模型库所在磁盘空间不足，请更换目录或释放空间后重试") }
                let engineIDs = Set(current.components.filter { $0.serviceBinding == nil }.map(\.engineID)).sorted()
                update(id) { $0.progress = .init(phase: .engines, total: engineIDs.count) }
                for engineID in engineIDs {
                    guard store.engineEnabled(engineID), let engine = store.engines.first(where: { $0.id == engineID }) else { throw LaunchError.message("方案所需基座已禁用或无法识别") }
                    let needsVision = engineID == "mlx" && current.components.contains { $0.role == .vision }
                    let imageSupported = engineID != "mflux" || [.current, .newer].contains(EngineVersionPolicy.state(installed: engine.version, available: "0.23.0"))
                    if engine.canServe && imageSupported && (!needsVision || engine.visionPath != nil) { update(id) { $0.progress?.completed += 1 }; continue }
                    guard !store.installation.running, !store.maintaining else { throw LaunchError.message("请等待当前引擎操作完成后重试") }
                    update(id) { $0.state = .installing; $0.stage = "正在安装 " + engine.name; $0.progress?.engineID = engine.id; $0.progress?.detail = "正在检查引擎版本…"; $0.progress?.engineStep = nil }
                    store.installation.running = true; store.installation.activeEngineID = engine.id
                    defer { store.installation.running = false; store.installation.activeEngineID = nil }
                    let release = try await (releaseLoader ?? EngineCatalog.release)(engine.kind)
                    let plan = EngineCatalog.plan(engine: engine, release: release)
                    if let installEngine { try await installEngine(engine, release) }
                    else {
                        try await InstallExecutor.install(plan, root: store.installation.root, progress: { [weak self] value in
                            Task { @MainActor in
                                self?.update(id) { record in
                                    guard record.state == .installing, record.progress?.engineID == engine.id,
                                          value.sequence >= (record.progress?.engineStep?.sequence ?? 0) else { return }
                                    record.progress?.engineStep = value
                                    record.progress?.detail = value.title
                                }
                            }
                        }) { [weak self] text in
                            Task { @MainActor in self?.update(id) { $0.log = String(($0.log + text).suffix(30000)) } }
                        }
                        let refreshed = Scanner.engines()
                        if store.inventory != nil { store.inventory?.engines = refreshed }
                    }
                    try Task.checkCancellation()
                    update(id) { $0.progress?.completed += 1 }
                }
                update(id) { $0.progress = .init(phase: .models) }
                for component in current.components {
                    if component.serviceBinding != nil {
                        if let issue = boundServiceIssue(component, store: store) { throw LaunchError.message(issue) }
                        continue
                    }
                    if let path = component.modelPath {
                        guard FileManager.default.fileExists(atPath: path) else { throw LaunchError.message("复用的模型文件已移动，请重新选择") }; continue
                    }
                    if let taskID = component.downloadID, let job = store.downloads.jobs.first(where: { $0.id == taskID }) {
                        let listing = RemoteListing(site: job.site, repository: job.repository, revision: job.revision, files: job.files, sourceURL: job.sourceURL)
                        let result = try store.downloads.enqueueSolution(listing, root: URL(fileURLWithPath: job.root))
                        update(id) { record in
                            guard let index = record.components.firstIndex(where: { $0.id == component.id }) else { return }
                            record.components[index].downloadID = result.job.id
                            record.components[index].ownsDownload = component.ownsDownload || result.created
                        }
                        continue
                    }
                    guard let listing = listings[component.id] else { throw LaunchError.message("下载任务已删除，请重新创建方案") }
                    let result = try store.downloads.enqueueSolution(listing, root: root)
                    update(id) { record in
                        guard let index = record.components.firstIndex(where: { $0.id == component.id }) else { return }
                        record.components[index].downloadID = result.job.id; record.components[index].ownsDownload = result.created
                    }
                }
                update(id) { $0.state = .downloading; $0.stage = "正在下载并校验配套文件" }
                reconcile(store: store)
                showDownloads(id, store: store, automatically: true)
            } catch is CancellationError { update(id) { $0.state = .paused; $0.stage = "已暂停，可继续安装" } }
            catch { update(id) { $0.state = .failed; $0.error = error.localizedDescription; $0.stage = "安装未完成，可重试" } }
        }
    }
    func reconcile(store: AppStore) {
        for deployment in deployments where deployment.state == .downloading && !completing.contains(deployment.id) {
            let jobs = deployment.components.compactMap { item in item.downloadID.flatMap { id in store.downloads.jobs.first { $0.id == id } } }
            if let failed = jobs.first(where: { $0.state == .failed }) { update(deployment.id) { $0.state = .failed; $0.error = failed.error; $0.stage = "模型下载失败，可继续重试" }; continue }
            if jobs.contains(where: { $0.state == .paused && !store.downloads.isScheduled($0.id) }) { update(deployment.id) { $0.state = .paused; $0.stage = "已暂停，可继续安装" }; continue }
            if jobs.contains(where: { $0.state != .complete }) { continue }
            if deployment.components.contains(where: { component in component.modelPath == nil && (component.downloadID == nil || !jobs.contains { $0.id == component.downloadID }) }) {
                update(deployment.id) { $0.state = .failed; $0.error = "方案下载任务已删除，请继续安装以重新创建" }; continue
            }
            completing.insert(deployment.id)
            Task { [weak self, weak store] in
                guard let self, let store else { return }
                defer { completing.remove(deployment.id) }
                do {
                    update(deployment.id) { $0.stage = "正在配置方案服务…"; $0.progress = .init(phase: .configuration, total: $0.components.count) }
                    try configure(deployment.id, store: store)
                    update(deployment.id) { $0.state = .configured; $0.stage = "安装完成，服务尚未启动"; $0.error = nil; $0.progress?.completed = $0.components.count }
                    if autoStartRequests.remove(deployment.id) != nil { start(deployment.id, store: store) }
                } catch { update(deployment.id) { $0.state = .failed; $0.error = error.localizedDescription; $0.stage = "文件或服务配置需要处理" } }
            }
        }
    }
    func configure(_ id: String, store: AppStore) throws {
        guard let deployment = deployments.first(where: { $0.id == id }) else { return }
        for (offset, component) in deployment.components.enumerated() {
            update(id) { $0.progress?.completed = offset; $0.progress?.detail = component.role.rawValue }
            if component.serviceBinding != nil {
                if let issue = boundServiceIssue(component, store: store) { throw LaunchError.message(issue) }
                continue
            }
            if let existing = component.serviceID, store.services.records.contains(where: { $0.id == existing && $0.engineID == component.engineID && $0.modelID == component.modelID }) { continue }
            guard let engine = store.engines.first(where: { $0.id == component.engineID }), engine.canServe, store.engineEnabled(engine.id) else { throw LaunchError.message("基座尚未安装完成或已禁用") }
            let model: LocalModel
            if let path = component.modelPath, let local = store.models.first(where: { $0.id == component.modelID && ModelInstancePolicy.samePath($0.path, path) }), local.complete { model = local }
            else {
                guard let taskID = component.downloadID, let job = store.downloads.jobs.first(where: { $0.id == taskID && $0.state == .complete }) else { throw LaunchError.message("模型任务尚未完成或已删除") }
                let inventory = Scanner.scan(extraRoots: [job.displayLocation])
                guard let local = inventory.models.first(where: { ModelInstancePolicy.samePath($0.path, job.displayLocation) && $0.complete }) else { throw LaunchError.message("模型配套文件不齐全，请在模型文件页修复") }
                model = local
                if !store.models.contains(where: { $0.id == local.id }) { store.inventory?.models.append(local) }
            }
            guard model.compatibility(with: engine).level == .direct else { throw LaunchError.message("模型与方案选择的基座不匹配") }
            let existing = store.modelServices(model, engineID: engine.id).sorted { (store.services.status($0) == .running ? 0 : 1) < (store.services.status($1) == .running ? 0 : 1) }.first
            if let existing {
                update(id) { record in if let index = record.components.firstIndex(where: { $0.id == component.id }) { record.components[index].serviceID = existing.id; record.components[index].modelID = model.id; record.components[index].modelPath = model.path } }; continue
            }
            let port = try EnginePortPolicy.available(engine: engine, base: engine.defaultPort, count: 1, occupied: { candidate in store.services.records.contains { $0.port == candidate } || NetworkProbe.portOccupied(candidate) })[0]
            let mode: InputMode = component.role == .vision ? .multimodal : [.asr, .tts].contains(component.role) ? .automatic : .text
            let launch = try LaunchBuilder.plan(engine: engine, model: model, port: port, context: 8192, inputMode: mode)
            let spec = ServiceSpec(engineID: engine.id, modelID: model.id, modelName: model.name, modelPath: model.path, port: port, engineVersion: launch.engineVersion, engineExecutable: launch.executable, inputMode: mode, projectorPath: model.companion, solutionCreated: true)
            try store.services.registerConfiguration(spec)
            update(id) { record in if let index = record.components.firstIndex(where: { $0.id == component.id }) { record.components[index].serviceID = spec.id; record.components[index].modelID = model.id; record.components[index].modelPath = model.path; record.components[index].ownsConfiguration = true } }
        }
    }
    func pause(_ id: String, store: AppStore) {
        guard let deployment = deployments.first(where: { $0.id == id }), deployment.state != .installing else { return }
        if preparingID == id { operation?.cancel() }
        autoStartRequests.remove(id)
        for component in deployment.components where component.ownsDownload {
            guard let task = component.downloadID, !deployments.contains(where: { $0.id != id && $0.state == .downloading && $0.components.contains { $0.downloadID == task } }) else { continue }
            store.downloads.pause(task)
        }
        update(id) { $0.state = .paused; $0.stage = "已暂停，可继续安装" }
    }
    func services(_ deployment: SolutionDeployment, store: AppStore) -> [ServiceSpec] {
        let ids = Set(deployment.components.compactMap(\.serviceID)); return store.services.records.filter { ids.contains($0.id) }
    }
    func showDownloads(_ id: String, store: AppStore, automatically: Bool = false) {
        guard let record = deployments.first(where: { $0.id == id }) else { return }
        // Background preparation must not pull the user away from another workspace.
        if automatically && (store.tab != .solutions || selectedID != record.solutionID || draft != record.draft) { return }
        let identifiers = Set(record.components.compactMap(\.downloadID))
        let tasks = store.downloads.jobs.filter { identifiers.contains($0.id) }
        if automatically && !tasks.contains(where: { $0.state != .complete }) { return }
        guard let task = tasks.first(where: { store.downloads.isActive($0.id) }) ?? tasks.first(where: { $0.state != .complete }) ?? tasks.first else { return }
        store.downloads.showTask(task.id); store.tab = .downloads
    }
    func stop(_ id: String, store: AppStore) {
        startOperations[id]?.cancel(); startOperations[id] = nil; startingIDs.remove(id); autoStartRequests.remove(id)
        guard let deployment = deployments.first(where: { $0.id == id }) else { return }
        for owned in deployment.processes {
            guard let spec = store.services.records.first(where: { $0.id == owned.serviceID && $0.pid == owned.pid && $0.processStart == owned.birth }) else { continue }
            if deployments.contains(where: { $0.id != id && $0.components.contains { $0.serviceID == spec.id } }) { continue }
            do { try store.services.stop(spec) } catch { message = error.localizedDescription }
        }
    }
    func remove(_ id: String, store: AppStore, serviceIDs: Set<String> = []) {
        guard let deployment = deployments.first(where: { $0.id == id }), preparingID != id, !startingIDs.contains(id) else { return }
        let before = deployments
        let ownedConfigurations = Set(deployment.components.filter(\.ownsConfiguration).compactMap(\.serviceID))
        let eligible = Set(removalItems(deployment, store: store).filter { $0.action == .remove }.map(\.id))
        guard serviceIDs.isSubset(of: eligible), services(deployment, store: store).filter({ serviceIDs.contains($0.id) }).allSatisfy({ store.services.canRemoveConfiguration($0) }) else { message = "清理范围已变化，所选服务仍在使用或被共享，请重新确认"; return }
        do { try store.services.preserveSolutionOrigins(ownedConfigurations) }
        catch { message = error.localizedDescription; return }
        // Ownership follows shared references so an orphaned runtime/task never becomes unmanageable.
        for process in deployment.processes {
            if let other = deployments.firstIndex(where: { $0.id != id && $0.components.contains { $0.serviceID == process.serviceID } }), !deployments[other].processes.contains(where: { $0.serviceID == process.serviceID }) { deployments[other].processes.append(process) }
        }
        for component in deployment.components {
            if component.ownsConfiguration, let serviceID = component.serviceID,
               let other = deployments.firstIndex(where: { $0.id != id && $0.components.contains { $0.serviceID == serviceID } }),
               let index = deployments[other].components.firstIndex(where: { $0.serviceID == serviceID }) {
                deployments[other].components[index].ownsConfiguration = true
                if let process = deployment.processes.first(where: { $0.serviceID == serviceID }) { deployments[other].processes.removeAll { $0.serviceID == serviceID }; deployments[other].processes.append(process) }
            }
            if component.ownsDownload, let downloadID = component.downloadID,
               let other = deployments.firstIndex(where: { $0.id != id && $0.components.contains { $0.downloadID == downloadID } }),
               let index = deployments[other].components.firstIndex(where: { $0.downloadID == downloadID }) { deployments[other].components[index].ownsDownload = true }
        }
        for component in deployment.components where component.ownsConfiguration && component.serviceID.map(serviceIDs.contains) == true {
            guard let serviceID = component.serviceID, !deployments.contains(where: { $0.id != id && $0.components.contains { $0.serviceID == serviceID } }), let spec = store.services.records.first(where: { $0.id == serviceID }) else { continue }
            let failures = store.applyRemovalCleanup(store.removalCleanup(service: spec))
            if !failures.isEmpty { deployments = before; message = failures.joined(separator: "\n"); return }
        }
        deployments.removeAll { $0.id == id }
        guard save() else { deployments = before; return }
        store.solutionExperiences.removeValue(forKey: id)?.stop()
        if store.solutionExperience?.id == id { store.solutionExperience = nil }
        if selectedDeploymentID == id { selectedDeploymentID = deployments.last(where: { $0.solutionID == deployment.solutionID })?.id }
        if editingID == id { editingID = nil }
        store.synchronizeGateway()
    }
}
