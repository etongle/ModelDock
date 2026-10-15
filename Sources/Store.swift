import Foundation
import AppKit
import SwiftUI
import Combine

enum AppTab: String, CaseIterable { case engines = "运行引擎", models = "模型文件", services = "模型服务", downloads = "下载导入", monitor = "资源与性能" }

@MainActor
final class AppStore: ObservableObject {
    @Published var inventory: Inventory?
    @Published var scanning = false
    @Published var tab: AppTab = .engines
    @Published var engineID = "splash"
    @Published var engineConfigurations: [String: EngineConfiguration] = [:]
    @Published var engineConfigurationDraft: EngineConfigurationDraft?
    @Published var modelAssociations: [String: ModelAssociation] = [:]
    @Published var associationDraft: ModelAssociationDraft?
    @Published var showGlobalEngines = false
    @Published var repairingFile: String?
    @Published var selectedModels: [String: String] = [:]
    @Published var port = "8000" { didSet { services.watchPort(parsedPort) } }
    @Published var context = 8192
    @Published var inputMode: InputMode = .automatic
    @Published var projectorPath = ""
    @Published var gatewaySelected = false
    @Published var maximumLoadedModels = 3
    @Published var search = "" { didSet { selectVisibleFile() } }
    @Published var modelFilter = "全部" { didSet { selectVisibleFile() } }
    @Published var modelEngineFilter = "" { didSet { selectVisibleFile() } }
    @Published var serviceEngineFilter = ""
    @Published var preparingInstall = false
    @Published var maintenanceEngineID: String?
    @Published var unloadingModel: String?
    @Published var message: String?
    @Published var selectedFileID: String?
    @Published var selectedServiceID: String?
    @Published var selectedExternal: Int?
    @Published var advanced = false
    @Published var extraRoots: [String]
    @Published var maintenancePlan: MaintenancePlan?
    @Published var preparingMaintenance = false
    @Published var maintaining = false
    @Published var maintenanceLog = ""
    @Published var maintenanceSelection = Set<String>()
    @Published var removeMaintenanceConfigurations = true
    let services: ServiceController
    let downloads: DownloadController
    let resources = ResourceMonitor()
    let performance: PerformanceController
    let installation: EngineInstallController
    let connections: ConnectionController
    let modelFiles = ModelFileController()
    let gateway: GatewayController
    let strata = StrataController()
    let appUpdates: AppUpdateController
    @Published var multiModel: MultiModelDraft?
    @Published var commandDraft: CommandDraft?
    @Published var modelUpdate: ModelUpdateDraft?
    @Published var preparingMulti = false
    private var subscriptions = Set<AnyCancellable>()
    @Published var hiddenToStatusBar = false
    @Published var windowCloseBehavior: WindowCloseBehavior = .keepRunning { didSet { savePreferences() } }
    @Published var appearance: AppAppearance = .system { didSet { savePreferences(); onAppearanceChange?() } }
    @Published var sidebarHidden = false { didSet { savePreferences() } }
    /// 200 ms like system sidebars; instant when Reduce Motion is on.
    func toggleSidebar() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { sidebarHidden.toggle() }
        else { withAnimation(.easeInOut(duration: 0.2)) { sidebarHidden.toggle() } }
    }
    var onAppearanceChange: (() -> Void)?
    @Published var language: AppLanguage = .english { didSet { L10n.select(language); savePreferences(); onLanguageChange?() } }
    @Published var preferencesError: String?
    var showMainWindow: (() -> Void)?
    var showSettings: (() -> Void)?
    var onLanguageChange: (() -> Void)?
    private let settingsURL: URL
    private let preferencesURL: URL
    private var scanAgain = false
    private var commandReadyScanned = Set<String>()

    init(stateDirectory: URL) {
        services = ServiceController(stateDirectory: stateDirectory)
        downloads = DownloadController(directory: stateDirectory)
        performance = PerformanceController(directory: stateDirectory)
        installation = EngineInstallController(directory: stateDirectory)
        connections = ConnectionController(directory: stateDirectory)
        gateway = GatewayController(directory: stateDirectory)
        appUpdates = AppUpdateController(directory: stateDirectory)
        strata.restore(directory: stateDirectory)
        engineConfigurations = (try? Data(contentsOf: stateDirectory.appendingPathComponent("engine-configurations.json"))).flatMap { try? JSONDecoder().decode([String: EngineConfiguration].self, from: $0) } ?? [:]
        modelAssociations = (try? Data(contentsOf: stateDirectory.appendingPathComponent("model-associations.json"))).flatMap { try? JSONDecoder().decode([String: ModelAssociation].self, from: $0) } ?? [:]
        settingsURL = stateDirectory.appendingPathComponent("locations.json")
        preferencesURL = stateDirectory.appendingPathComponent("preferences.json")
        let preferences = (try? Data(contentsOf: preferencesURL)).flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? AppPreferences()
        windowCloseBehavior = preferences.windowCloseBehavior
        appearance = preferences.appearance
        sidebarHidden = preferences.sidebarHidden
        language = argumentValue("--language").flatMap(AppLanguage.init(rawValue:)) ?? preferences.language
        extraRoots = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        L10n.select(language)
        selectedServiceID = services.records.first?.id
        installation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        connections.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        services.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        modelFiles.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        gateway.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        strata.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        appUpdates.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        services.$logRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for spec in self.services.records where spec.commandText != nil && spec.engineID == "splash" && self.services.status(spec) == .running {
                    if self.commandReadyScanned.insert(spec.id + ":" + String(spec.processStart ?? 0)).inserted { self.scan() }
                }
                self.synchronizeGateway(); await self.gateway.poll()
                self.captureServiceComponents()
            }
        }.store(in: &subscriptions)
        downloads.onImported = { [weak self] root in
            guard let self else { return }
            if !(self.inventory?.roots ?? []).contains(root), !self.extraRoots.contains(root) { self.extraRoots.append(root); try? JSONEncoder().encode(self.extraRoots).write(to: self.settingsURL, options: .atomic) }
            self.scan()
        }
        downloads.onRepair = { [weak self] job in
            guard let self, let target = job.repairTarget else { throw LaunchError.message("修复目标已变化") }
            let model = self.models.first { $0.id == job.repairModelID } ?? LocalModel(id: job.repairModelID ?? target, name: job.repository, format: "", path: target, kind: .language, bytes: 0, complete: false, verification: "", repository: job.repository, missingFiles: [], removalPath: target)
            guard !ModelFileSafety.used(model, removal: URL(fileURLWithPath: target), services: self.services.records, external: self.services.external, models: self.models) else { throw LaunchError.message("修复文件已下载，但原文件正在使用。停止相关服务后继续此任务即可应用修复。") }
            guard !self.downloads.jobs.contains(where: { $0.id != job.id && $0.state == .downloading && EngineMaintenance.contains($0.root + "/" + $0.folder, target) }) else { throw LaunchError.message("原目录正在下载，修复文件保留；原任务结束后继续修复") }
            try ModelFileRepair.publish(job); self.downloads.notice = "单文件修复完成，其他模型文件保持原状。"; self.scan()
        }
    }
    private func savePreferences() {
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(AppPreferences(windowCloseBehavior: windowCloseBehavior, language: language, appearance: appearance, sidebarHidden: sidebarHidden)).write(to: preferencesURL, options: .atomic)
            preferencesError = nil
        } catch { preferencesError = "设置未能保存，请重试。" }
    }
    var engines: [Engine] { (inventory?.engines ?? Scanner.engines()).map { item in var value = item; value.launchSettings = engineConfigurations[item.id]; if let port = value.launchSettings?.port { value.defaultPort = port }; return value } }
    var engine: Engine { engines.first { $0.id == engineID } ?? engines[0] }
    var enabledEngines: [Engine] { engines.filter { engineEnabled($0.id) } }
    var models: [LocalModel] { (inventory?.models ?? []).map { model in var value = model; value.association = modelAssociations[model.id] ?? (model.splashRegistrations ?? []).flatMap(\.aliases).compactMap { modelAssociations[$0] }.first; if let path = value.association?.projectorPath { value.companion = path }; return value } }
    var compatibleModels: [LocalModel] { models.filter { $0.compatible(with: engine) } }
    var selectedModel: LocalModel? { compatibleModels.first { $0.id == selectedModels[engineID] } ?? compatibleModels.first }
    var selectedFile: LocalModel? { filteredModels.first { $0.id == selectedFileID } ?? filteredModels.first }
    var selectedService: ServiceSpec? { services.records.first { $0.id == selectedServiceID } }
    var visibleServices: [ServiceSpec] { services.records.filter { serviceEngineFilter.isEmpty || $0.engineID == serviceEngineFilter } }
    var visibleExternalServices: [ObservedService] { services.external.filter { serviceEngineFilter.isEmpty || $0.engineID == serviceEngineFilter } }
    func selectVisibleService() {
        if !visibleServices.contains(where: { $0.id == selectedServiceID }) { selectedServiceID = visibleServices.first?.id }
        if let selectedExternal, !visibleExternalServices.contains(where: { $0.port == selectedExternal }) { self.selectedExternal = nil }
        if selectedServiceID == nil && selectedExternal == nil { selectedExternal = visibleExternalServices.first?.port }
    }
    var resourceTargets: [ResourceTarget] {
        services.records.filter { $0.pid != nil }.map { spec in .init(id: spec.id, name: engines.first { $0.id == spec.engineID }?.name ?? spec.engineID, model: spec.modelName, port: spec.port, pid: spec.pid, birth: spec.processStart) } + services.external.filter(\.ready).map { external in .init(id: "external:\(external.port)", name: external.engineName, model: external.models.first ?? "模型管理服务", port: external.port, pid: external.pid, birth: external.birth) }
    }
    var benchmarkTargets: [BenchmarkTarget] {
        var targets: [BenchmarkTarget] = []
        for spec in services.records where spec.pid != nil && services.status(spec) == .running {
            let local = models.first { $0.id == spec.modelID }
            if let local, local.kind != .language { continue }
            let engine = engines.first { $0.id == spec.engineID }
            let names = services.reportedModels[spec.port] ?? []
            let candidates = names.isEmpty ? (local.map { [$0.repository ?? $0.name] } ?? []) : names
            for name in candidates {
                let model = spec.engineID == "ollama" ? models.first { $0.format == "Ollama" && $0.repository == name } : local
                targets.append(.init(id: "\(spec.id):\(name)", engineID: spec.engineID, engineName: engine?.name ?? spec.engineID, engineVersion: spec.engineVersion ?? engine?.version ?? "—", modelID: model?.id, modelName: model?.name ?? name, apiModel: name, port: spec.port, pid: spec.pid, birth: spec.processStart, context: spec.context))
            }
        }
        for external in services.external where external.ready {
            let resource = resources.services.first { $0.id == "external:\(external.port)" }
            for name in external.models {
                targets.append(.init(id: "external:\(external.port):\(name)", engineID: external.engineID ?? "external", engineName: external.engineName, engineVersion: "外部服务", modelName: name, apiModel: name, port: external.port, pid: external.pid ?? resource?.pid, birth: external.birth ?? resource?.pid.map(processStartTime)))
            }
        }
        return targets
    }
    func beginResourceMonitoring() {
        resources.begin(targets: { [weak self] in self?.resourceTargets ?? [] }, roots: { [weak self] in self?.inventory?.roots ?? [Scanner.defaultRoot.path] })
    }
    var parsedPort: Int? { Int(port).flatMap { (1024...65535).contains($0) ? $0 : nil } }
    var currentService: ServiceSpec? { parsedPort.flatMap { port in services.record(engineID: engineID, modelID: selectedModel?.id, port: port) ?? services.records.first { $0.engineID == engineID && $0.port == port && selectedModel?.matchesID($0.modelID) == true } } }
    var currentStatus: ServiceStatus { currentService.map { services.status($0) } ?? .stopped }
    var occupiedExternally: Bool { parsedPort.map { candidate in services.external.contains { $0.port == candidate } } ?? false }
    var portConflict: String? { parsedPort.flatMap { services.portConflict($0, excluding: currentService?.id) } }
    var canStart: Bool { engineEnabled(engineID) && !scanning && !(engineID == "strata" && strata.busy) && !(maintaining && maintenanceEngineID == engineID) && installation.activeEngineID != engineID && engine.canServe && parsedPort != nil && (selectedModel != nil || engine.kind == .ollama) && portConflict == nil && currentService?.pid == nil && (inputMode != .multimodal || ModalityPolicy.nativeMultimodalReason(engine: engine, model: selectedModel, projector: projectorPath) == nil) }
    var filteredModels: [LocalModel] {
        models.filter { model in
            modelMatchesEngineFilter(model) && (modelFilter == "全部" || (modelFilter == "主模型" ? model.kind == .language : model.kind != .language)) && (search.isEmpty || (model.name + model.format + model.path).localizedCaseInsensitiveContains(search))
        }
    }
    func selectVisibleFile() { if !filteredModels.contains(where: { $0.id == selectedFileID }) { selectedFileID = filteredModels.first?.id } }

    func scan() {
        guard !scanning else { scanAgain = true; return }; scanning = true
        let roots = extraRoots
        let firstScan = inventory == nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Scanner.scan(extraRoots: roots) }.value
            inventory = result; scanning = false
            for (engine, id) in selectedModels { if let main = models.first(where: { $0.matchesID(id) }) { selectedModels[engine] = main.id } }
            if let id = selectedFileID, let main = models.first(where: { $0.matchesID(id) }) { selectedFileID = main.id }
            if selectedFileID == nil || !models.contains(where: { $0.id == selectedFileID }) { selectedFileID = models.first?.id }
            if let preferred = compatibleModels.first, selectedModels[engineID] == nil { selectedModels[engineID] = preferred.id }
            if firstScan, let active = currentService, active.pid != nil {
                context = active.context
                inputMode = active.inputMode ?? .automatic; projectorPath = active.projectorPath ?? ""
                maximumLoadedModels = active.maximumLoadedModels ?? maximumLoadedModels
            }
            await services.refresh()
            captureServiceComponents()
            synchronizeGateway()
            if scanAgain { scanAgain = false; scan() }
        }
    }
    func chooseEngine(_ id: String) {
        engineID = id
        inputMode = engine.launchSettings?.inputMode ?? .automatic; projectorPath = ""
        context = engine.launchSettings?.context ?? (engine.kind == .strata ? 32768 : 8192); maximumLoadedModels = engine.launchSettings?.maximumLoadedModels ?? 3
        if selectedModels[id] == nil { selectedModels[id] = compatibleModels.first?.id }
        if let active = services.records.first(where: { $0.engineID == id && $0.pid != nil && (id == "ollama" || selectedModel == nil || selectedModel?.matchesID($0.modelID) == true) }) {
            port = String(active.port); context = active.context
            inputMode = active.inputMode ?? .automatic; projectorPath = active.projectorPath ?? ""
        } else if engine.independentModels {
            port = String((try? EnginePortPolicy.available(engine: engine, base: engine.defaultPort, count: 1, occupied: { self.services.portReserved($0) || NetworkProbe.portOccupied($0) }).first) ?? engine.defaultPort)
        } else { port = String(engine.defaultPort) }
        normalizeStartupMode()
    }
    func useFreePort() {
        guard currentService?.pid == nil else { return }
        do { port = String(try EnginePortPolicy.available(engine: engine, base: engine.defaultPort, count: 1, occupied: { self.services.portReserved($0) || NetworkProbe.portOccupied($0) })[0]) }
        catch { message = error.localizedDescription }
    }
    func showPortOwner() {
        guard let candidate = parsedPort else { return }
        gatewaySelected = false
        serviceEngineFilter = ""
        if let external = services.external.first(where: { $0.port == candidate }) { selectedExternal = external.port }
        else if let spec = services.records.first(where: { $0.port == candidate && $0.pid != nil }) { selectedServiceID = spec.id; selectedExternal = nil }
        tab = .services
    }
    func start() {
        guard !(engineID == "strata" && strata.busy), !appUpdates.applying else { message = "请等待当前模型准备或应用更新完成"; return }
        guard engineEnabled(engineID) else { message = "此基座已停用，请在引擎配置中启用"; return }
        guard let selectedPort = parsedPort else { message = "请输入 1024–65535 之间的端口"; return }
        guard installation.activeEngineID != engineID else { message = "请等待此引擎安装或更新完成"; return }
        do { let spec = try services.start(engine: engine, model: selectedModel, port: selectedPort, context: context, maximumLoadedModels: maximumLoadedModels, inputMode: inputMode, projectorPath: projectorPath); selectedServiceID = spec.id }
        catch { message = error.localizedDescription }
    }
    func stop(_ spec: ServiceSpec) { do { try services.stop(spec) } catch { message = error.localizedDescription } }
    func showService(_ spec: ServiceSpec) { gatewaySelected = false; if !serviceEngineFilter.isEmpty && serviceEngineFilter != spec.engineID { serviceEngineFilter = "" }; selectedServiceID = spec.id; selectedExternal = nil; tab = .services }
    func configureService(_ spec: ServiceSpec) {
        if let command = spec.commandText, let engine = engines.first(where: { $0.id == spec.engineID }) { prepareCommand(engine: engine, text: command); return }
        guard engines.contains(where: { $0.id == spec.engineID }) else { return }
        engineID = spec.engineID; selectedModels[engineID] = spec.modelID
        port = String(spec.port); context = spec.context
        inputMode = spec.inputMode ?? .automatic; projectorPath = spec.projectorPath ?? ""
        maximumLoadedModels = spec.maximumLoadedModels ?? maximumLoadedModels
        tab = .engines
        normalizeStartupMode()
    }
    func removeServiceConfiguration(_ spec: ServiceSpec) {
        let index = services.records.firstIndex { $0.id == spec.id } ?? 0
        do {
            try services.removeConfiguration(spec)
            if selectedServiceID == spec.id {
                selectedServiceID = services.records.isEmpty ? nil : services.records[min(index, services.records.count - 1)].id
            }
            selectVisibleService()
        } catch { message = error.localizedDescription }
    }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func openEndpoint(_ port: Int) { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)")!) }
    func addLocation() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("添加目录"); panel.message = L10n.text("选择已有模型目录；文件保留在原位置。")
        guard panel.runModal() == .OK else { return }
        let existing = Set(extraRoots + (inventory?.roots ?? []))
        extraRoots += panel.urls.map { $0.resolvingSymlinksInPath().path }.filter { !existing.contains($0) }
        do { try JSONEncoder().encode(extraRoots).write(to: settingsURL, options: .atomic); scan() } catch { message = "目录保存失败：\(error.localizedDescription)" }
    }
    func registerModelRoot(_ path: String) throws {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if root != Scanner.defaultRoot.path && !extraRoots.contains(root) {
            var next = extraRoots; next.append(root)
            try JSONEncoder().encode(next).write(to: settingsURL, options: .atomic); extraRoots = next
        }
    }
    func launch(model: LocalModel, engine: Engine) { selectedModels[engine.id] = model.id; chooseEngine(engine.id); tab = .engines }

    func maintenanceBlockers(_ plan: MaintenancePlan, selectedIDs: Set<String>? = nil, includeDownloads: Bool = true) -> [String] {
        var blockers = plan.blockers
        let chosen = plan.items.filter { selectedIDs?.contains($0.id) ?? $0.selectedByDefault }
        if plan.engine.kind == .strata && strata.busy { blockers.append("请等待 Strata 模型准备操作完成。") }
        if includeDownloads { blockers += EngineMaintenance.downloadBlockers(chosen, jobs: downloads.jobs) }
        if services.records.contains(where: { $0.engineID == plan.engine.id && $0.pid != nil }) { blockers.append("请先在“模型服务”中停止此引擎的服务。") }
        let agent = Scanner.home.appendingPathComponent("Library/LaunchAgents/homebrew.mxcl.ollama.plist").path
        let automaticOllama = plan.mode == .uninstall && plan.engine.kind == .ollama && EngineMaintenance.isBrewOllamaAgent(agent)
        if !EngineMaintenance.runningPrograms(plan.engine, allowBrewOllama: automaticOllama).isEmpty { blockers.append("此引擎还有外部进程运行，请先使用原应用停止。") }
        return blockers
    }
    func prepareMaintenance(_ mode: MaintenanceMode) {
        guard !preparingMaintenance && !maintaining && !installation.running, let inventory else { return }
        preparingMaintenance = true; maintenanceLog = ""
        let currentEngine = engine
        maintenanceEngineID = currentEngine.id
        Task {
            var plan = await Task.detached { EngineMaintenance.plan(engine: currentEngine, mode: mode, inventory: inventory) }.value
            await services.refresh(); plan.blockers = maintenanceBlockers(plan, includeDownloads: false)
            maintenanceSelection = Set(plan.items.filter(\.selectedByDefault).map(\.id)); removeMaintenanceConfigurations = true
            maintenancePlan = plan; preparingMaintenance = false
        }
    }
    func performMaintenance(_ plan: MaintenancePlan, selectedIDs: Set<String>, removeConfigurations: Bool) {
        guard !maintaining && !installation.running else { return }
        let chosen = EngineMaintenance.normalized(plan.items.filter { selectedIDs.contains($0.id) })
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "\(plan.mode.rawValue)：\(plan.engine.name)？"
        alert.informativeText = L10n.text("将处理 \(chosen.count) 项，共 \(sizeLabel(chosen.reduce(0) { $0 + $1.bytes }))。\n应用、残留和勾选的模型移至废纸篓；Homebrew 安装包由包管理器卸载，需要重装才能恢复。\n\n\(chosen.contains(where: { $0.group == .model }) ? "你已选择删除专属模型。" : "模型权重保留。")")
        alert.addButton(withTitle: L10n.text("确认\(plan.mode.rawValue)")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        maintaining = true; maintenanceLog = "正在核对文件归属与运行状态…\n"
        Task {
            do {
                await services.refresh()
                let roots = extraRoots
                let freshInventory = await Task.detached { Scanner.scan(extraRoots: roots) }.value
                var fresh = await Task.detached { EngineMaintenance.plan(engine: plan.engine, mode: plan.mode, inventory: freshInventory) }.value
                fresh.blockers = maintenanceBlockers(fresh, selectedIDs: selectedIDs)
                try EngineMaintenance.validate(chosen, original: plan, fresh: fresh)
                if chosen.contains(where: { $0.group == .model }), services.records.contains(where: { spec in spec.pid != nil && chosen.contains(where: { EngineMaintenance.contains($0.path, spec.modelPath) }) }) { throw LaunchError.message("所选模型正在被其他服务使用，请先停止服务。") }
                for item in chosen where item.group == .model {
                    let selectedFile = LocalModel(id: "removal:" + item.path, name: "所选组件", format: "", path: item.path, kind: .language, bytes: 0, complete: false, verification: "", missingFiles: [], removalPath: item.path)
                    if ModelFileSafety.used(selectedFile, removal: URL(fileURLWithPath: item.path), services: services.records, external: services.external, models: models) { throw LaunchError.message("所选组件正在被模型服务使用，请先停止相关服务：" + item.path) }
                }
                if plan.mode == .uninstall, plan.engine.kind == .ollama {
                    let agent = Scanner.home.appendingPathComponent("Library/LaunchAgents/homebrew.mxcl.ollama.plist").path
                    if EngineMaintenance.isBrewOllamaAgent(agent) {
                        maintenanceLog += "停止 Ollama 的 Homebrew 服务…\n"
                        let output = try await Task.detached { try EngineMaintenance.command("/opt/homebrew/bin/brew", ["services", "stop", "ollama"]) }.value
                        maintenanceLog += output
                        guard EngineMaintenance.runningPrograms(plan.engine, allowBrewOllama: false).isEmpty else { throw LaunchError.message("Ollama 仍在运行，已暂停卸载，请停止进程后重新扫描。") }
                    }
                }
                let packages = chosen.filter { $0.formula != nil }
                if !packages.isEmpty {
                    maintenanceLog += "卸载安装包：\(packages.compactMap(\.formula).joined(separator: "、"))…\n"
                    for item in packages {
                        let args = ["uninstall"] + (item.cask ? ["--cask"] : ["--force", "--formula"]) + [item.formula!]
                        maintenanceLog += try await Task.detached { try EngineMaintenance.command(EnginePaths.brew ?? "/opt/homebrew/bin/brew", args) }.value
                    }
                }
                for item in chosen where item.formula == nil {
                    // brew services stop may already remove its own registration.
                    if item.path.hasSuffix("/homebrew.mxcl.ollama.plist"), FileIdentity.read(item.path) == nil { continue }
                    guard FileIdentity.read(item.path) == item.identity else { throw LaunchError.message("文件已经变化，已暂停：\(item.path)") }
                    if item.group != .model, EngineMaintenance.protected(item.path, inventory: freshInventory) || EngineMaintenance.untrackedWeights(item.path) { throw LaunchError.message("此位置包含模型文件，已保留：\(item.path)") }
                    maintenanceLog += "移至废纸篓：\(item.path)\n"
                    try await Task.detached { try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil) }.value
                }
                if removeConfigurations && plan.mode == .uninstall {
                    for spec in services.records.filter({ $0.engineID == plan.engine.id }) {
                        try services.removeConfiguration(spec)
                        if UUID(uuidString: spec.id) != nil, FileManager.default.fileExists(atPath: services.logURL(spec.id).path) { try FileManager.default.trashItem(at: services.logURL(spec.id), resultingItemURL: nil) }
                    }
                }
                maintenanceLog += "\n处理完成。废纸篓中的文件可恢复；清空废纸篓后释放空间。"
            } catch { maintenanceLog += "\n已暂停：\(error.localizedDescription)\n已处理的项目列在上方，可在废纸篓中查看。" }
            maintaining = false; scan()
        }
    }

    func trash(_ model: LocalModel) {
        deleteModel(model)
    }
}
