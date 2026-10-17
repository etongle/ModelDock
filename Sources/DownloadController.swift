import Foundation
import Combine

private struct DownloadPreferences: Codable {
    var concurrentDownloads = 2
    var destination = Scanner.defaultRoot.path
}
@MainActor
private final class DownloadExecution {
    var transfer: DownloadTransfer?
    var pauseRequested = false
    var interruptedFile: (id: String, path: String)?
    var speedTimer: Timer?
    var rate = DownloadRate()
    var networkBytes: Int64 = 0
    var fileBaseline: Int64?
    var speedGeneration = UUID()
}
@MainActor
final class DownloadController: ObservableObject {
    @Published var address = ""
    @Published var token = ""
    @Published var destination = Scanner.defaultRoot.path
    @Published var listing: RemoteListing?
    /// 任务详情文件明细的搜索词。
    @Published var fileSearch = ""
    @Published var selected = Set<String>()
    @Published var resolving = false
    @Published var message: String?
    @Published var jobs: [ModelDownload] = []
    @Published var activeIDs = Set<String>()
    // Compatibility for capture fixtures and single-task checks; production uses isActive/hasPendingWork.
    var activeID: String? {
        get { jobs.first { activeIDs.contains($0.id) }?.id }
        set { activeIDs = newValue.map { Set([$0]) } ?? [] }
    }
    @Published var maximumConcurrentDownloads = 2 {
        didSet {
            let bounded = min(8, max(1, maximumConcurrentDownloads))
            if bounded != maximumConcurrentDownloads { maximumConcurrentDownloads = bounded }
            savePreferences(); pump()
        }
    }
    @Published var importSessionID = UUID()
    @Published var speeds: [String: Double] = [:]
    @Published var notice: String?
    @Published var deletingIDs = Set<String>()
    @Published var selectedTaskID: String?
    @Published var transferPhases: [String: DownloadTransferPhase] = [:]
    private struct Pending { var id: String; var allowReplacement: Bool; var credential: String }
    private var pending: [Pending] = []
    private var executions: [String: DownloadExecution] = [:]
    private var preferredDestination = Scanner.defaultRoot.path
    private var resolution: Task<Void, Never>?
    private var resolutionID = UUID()
    private let stateURL: URL
    var onImported: ((String) -> Void)?
    var onRepair: ((ModelDownload) throws -> Void)?
    var transferProtocolClasses: [AnyClass]?
    var catalogLoader: ((String, String) async throws -> RemoteListing)?
    var directory: URL { stateURL.deletingLastPathComponent() }
    init(directory: URL) {
        stateURL = directory.appendingPathComponent("downloads.json")
        let preferences = (try? Data(contentsOf: directory.appendingPathComponent("download-settings.json"))).flatMap { try? JSONDecoder().decode(DownloadPreferences.self, from: $0) } ?? .init()
        maximumConcurrentDownloads = min(8, max(1, preferences.concurrentDownloads))
        preferredDestination = preferences.destination; destination = preferences.destination
        jobs = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([ModelDownload].self, from: $0) } ?? []
        for index in jobs.indices {
            if jobs[index].state == .downloading || jobs[index].state == .queued { jobs[index].state = .paused }
            do { jobs[index] = try DownloadRecovery.reconcile(jobs[index]) }
            catch let error as DownloadResumeError { jobs[index].resumeBlockedReason = error.localizedDescription; jobs[index].error = error.localizedDescription }
            catch { jobs[index].error = error.localizedDescription }
        }
        selectedTaskID = jobs.first?.id
    }
    var selectedFiles: [RemoteFile] { listing?.files.filter { selected.contains($0.id) } ?? [] }
    func speedLabel(_ id: String) -> String {
        guard isActive(id) else { return "—" }
        let value = speeds[id] ?? 0
        return sizeLabel(Int64(min(Double(Int64.max / 2), max(0, value.isFinite ? value : 0)))) + "/s"
    }
    @discardableResult func save() -> Bool { do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try JSONEncoder().encode(jobs).write(to: stateURL, options: .atomic); return true } catch { message = "下载任务保存失败：\(error.localizedDescription)"; return false } }
    private func synchronizeSharedProgress(_ id: String) {
        guard let source = jobs.first(where: { $0.id == id }) else { return }
        for index in jobs.indices where jobs[index].id != id {
            guard URL(fileURLWithPath: jobs[index].root).standardizedFileURL == URL(fileURLWithPath: source.root).standardizedFileURL,
                  jobs[index].folder == source.folder, DownloadRecovery.sameFiles(jobs[index].files, source.files) else { continue }
            for fileIndex in jobs[index].files.indices {
                if let file = source.files.first(where: { $0.path == jobs[index].files[fileIndex].path }) { jobs[index].files[fileIndex].bytes = file.bytes }
            }
            jobs[index].received = source.received; jobs[index].finished = source.finished; jobs[index].currentFile = source.currentFile
            jobs[index].fileReceived = source.fileReceived
            if source.state == .complete { jobs[index].state = .complete; jobs[index].error = nil; jobs[index].resumeBlockedReason = nil }
        }
    }
    var hasPendingWork: Bool { !activeIDs.isEmpty || !pending.isEmpty }
    var queuedCount: Int { pending.count }
    func isActive(_ id: String) -> Bool { activeIDs.contains(id) }
    func isScheduled(_ id: String) -> Bool { isActive(id) || pending.contains { $0.id == id } }
    private func savePreferences() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(DownloadPreferences(concurrentDownloads: maximumConcurrentDownloads, destination: preferredDestination)).write(to: directory.appendingPathComponent("download-settings.json"), options: .atomic)
        } catch { message = "下载设置保存失败" }
    }
    func chooseDestination(_ path: String) { preferredDestination = path; destination = path; savePreferences() }
    func beginImport() {
        resolution?.cancel(); resolution = nil; resolutionID = UUID()
        resolving = false; address = ""; token = ""; listing = nil; selected = []
        message = nil; notice = nil; selectedTaskID = nil; destination = preferredDestination
        importSessionID = UUID()
    }
    func changeAddress(_ value: String) {
        address = value; resolution?.cancel(); resolutionID = UUID(); resolving = false
        listing = nil; selected = []; message = nil; notice = nil
    }
    func resolve() {
        resolution?.cancel(); let generation = UUID(); resolutionID = generation
        resolving = true; message = nil; listing = nil; selected = []; selectedTaskID = nil
        address = ModelCatalog.normalizedAddress(address)
        let input = address, credential = token
        resolution = Task {
            do {
                let result = try await (catalogLoader ?? ModelCatalog.listing)(input, credential)
                guard !Task.isCancelled, resolutionID == generation, address == input else { return }
                listing = result; selected = ModelCatalog.suggested(result)
            } catch {
                guard !Task.isCancelled, resolutionID == generation else { return }
                message = error.localizedDescription
            }
            if resolutionID == generation { resolving = false; resolution = nil }
        }
    }
    static func overlaps(_ left: String, _ right: String) -> Bool {
        let l = URL(fileURLWithPath: left).standardizedFileURL.resolvingSymlinksInPath().path
        let r = URL(fileURLWithPath: right).standardizedFileURL.resolvingSymlinksInPath().path
        return l == r || l.hasPrefix(r + "/") || r.hasPrefix(l + "/")
    }
    func hasWriter(affecting path: String) -> Bool {
        jobs.contains { isScheduled($0.id) && (Self.overlaps($0.displayLocation, path) || $0.repairTarget.map { Self.overlaps($0, path) } == true) }
    }
    func queueReason(_ id: String) -> String {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .queued else { return "" }
        return jobs.contains { isActive($0.id) && Self.overlaps($0.displayLocation, job.displayLocation) } ? "同一下载目录正在使用，完成后自动继续" : "等待下载名额，轮到后自动开始"
    }
    private func run(_ id: String, allowReplacement: Bool, credential: String? = nil) {
        guard !isScheduled(id), !deletingIDs.contains(id), let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = .queued; jobs[i].error = nil; selectedTaskID = id
        guard save() else { jobs[i].state = .paused; return }
        pending.append(.init(id: id, allowReplacement: allowReplacement, credential: credential ?? token)); pump()
    }
    private func pump() {
        pending.removeAll { entry in !jobs.contains { $0.id == entry.id && $0.state == .queued } }
        while activeIDs.count < maximumConcurrentDownloads {
            guard let offset = pending.firstIndex(where: { entry in
                guard !deletingIDs.contains(entry.id), let job = jobs.first(where: { $0.id == entry.id }) else { return false }
                return !jobs.contains { isActive($0.id) && Self.overlaps($0.displayLocation, job.displayLocation) }
            }) else { break }
            let entry = pending.remove(at: offset)
            start(entry.id, allowReplacement: entry.allowReplacement, credential: entry.credential)
        }
    }
    func createJob() {
        guard let listing, !selectedFiles.isEmpty else { return }
        message = nil; notice = nil
        let root = URL(fileURLWithPath: destination).resolvingSymlinksInPath().standardizedFileURL
        let matches = matching(listing: listing, files: selectedFiles, root: root)
        if let existing = matches.first(where: { isScheduled($0.id) }) {
            selectedTaskID = existing.id; notice = "已使用现有任务，保留已下载进度。"; return
        }
        for candidate in matches {
            guard candidate.resumeBlockedReason == nil else { continue }
            do {
                var restored = try DownloadRecovery.reconcile(candidate)
                // Use fresh size/hash information while keeping the task and file locations.
                restored.files = selectedFiles.map { fresh in var file = fresh; if file.bytes == 0 { file.bytes = candidate.files.first { $0.path == fresh.path }?.bytes ?? 0 }; return file }
                restored.pausedFiles = []
                if let i = jobs.firstIndex(where: { $0.id == candidate.id }) { jobs[i] = restored }
                notice = "已使用现有任务，保留已下载进度。"; selectedTaskID = candidate.id; run(candidate.id, allowReplacement: true); return
            } catch let error as DownloadResumeError {
                if let i = jobs.firstIndex(where: { $0.id == candidate.id }) { jobs[i].resumeBlockedReason = error.localizedDescription; jobs[i].error = error.localizedDescription }
            } catch { message = error.localizedDescription; return }
        }
        add(listing: listing, files: selectedFiles, root: root, replacing: matches.first)
    }
    private func matching(listing: RemoteListing, files: [RemoteFile], root: URL) -> [ModelDownload] {
        jobs.enumerated().filter { !deletingIDs.contains($0.element.id) && DownloadRecovery.matches($0.element, listing: listing, files: files, root: root) }.sorted { left, right in
            func order(_ state: DownloadState) -> Int { state == .paused ? 0 : state == .failed ? 1 : 2 }
            let l = left.element, r = right.element
            if order(l.state) != order(r.state) { return order(l.state) < order(r.state) }
            let lb = (try? DownloadRecovery.reconcile(l).received) ?? l.received, rb = (try? DownloadRecovery.reconcile(r).received) ?? r.received
            if lb != rb { return lb > rb }
            if l.received != r.received { return l.received > r.received }
            return left.offset > right.offset
        }.map(\.element)
    }
    /// Enqueue a bundle dependency without replacing the user's open import form or credentials.
    func enqueueSolution(_ listing: RemoteListing, root: URL) throws -> (job: ModelDownload, created: Bool) {
        let files = listing.files.filter { ModelCatalog.suggested(listing).contains($0.path) }
        guard !files.isEmpty else { throw LaunchError.message("方案仓库没有可下载的模型文件") }
        let priorSelection = selectedTaskID
        defer { selectedTaskID = priorSelection }
        let matches = matching(listing: listing, files: files, root: root)
        for candidate in matches {
            if isScheduled(candidate.id) { return (candidate, false) }
            guard candidate.resumeBlockedReason == nil, var restored = try? DownloadRecovery.reconcile(candidate) else { continue }
            if restored.state == .complete { return (restored, false) }
            restored.files = files
            if let index = jobs.firstIndex(where: { $0.id == restored.id }) { jobs[index] = restored }
            run(restored.id, allowReplacement: true, credential: "")
            return (jobs.first { $0.id == restored.id }!, false)
        }
        let before = Set(jobs.map(\.id))
        add(listing: listing, files: files, root: root, replacing: matches.first, credential: "")
        guard let job = jobs.first(where: { !before.contains($0.id) }), isScheduled(job.id) else { throw LaunchError.message(message ?? "方案下载任务创建失败") }
        return (job, true)
    }
    var preferredPausedTask: ModelDownload? {
        guard let listing, !selectedFiles.isEmpty else { return nil }
        let root = URL(fileURLWithPath: destination).resolvingSymlinksInPath().standardizedFileURL
        return matching(listing: listing, files: selectedFiles, root: root).first { $0.state == .paused && $0.resumeBlockedReason == nil && (try? DownloadRecovery.reconcile($0)) != nil }
    }
    private func add(listing: RemoteListing, files: [RemoteFile], root: URL, replacing old: ModelDownload?, credential: String? = nil) {
        let folder = DownloadRecovery.folder(listing: listing, recovery: old != nil)
        var job = ModelDownload(site: listing.site, repository: listing.repository, revision: listing.revision, root: root.path, folder: folder, files: files)
        job.sourceURL = listing.sourceURL
        job.replacementOf = old?.id
        job.pausedFiles = old?.pausedFiles; job.priorityFile = old?.priorityFile
        do {
            for file in job.files { _ = try DownloadPaths.destination(root: root, folder: folder, file: file.path); try DownloadPaths.validateURL(file.url) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let old {
                notice = "原任务无法续传，已在独立目录重新下载；原文件保留。"
                // Reuse complete files; the worker hashes these before accepting them.
                for file in files where old.finished.contains(file.path) && file.path != old.currentFile {
                    guard let source = try? DownloadPaths.destination(root: URL(fileURLWithPath: old.root), folder: old.folder, file: file.path),
                          let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, file.bytes > 0, Int64(size) == file.bytes else { continue }
                    let target = try DownloadPaths.destination(root: root, folder: folder, file: file.path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.linkItem(at: source, to: target)
                }
            }
        } catch { message = error.localizedDescription; return }
        jobs.insert(job, at: 0); guard save() else { return }; run(job.id, allowReplacement: false, credential: credential)
    }
    @discardableResult
    func createRepair(file: RemoteFile, source: ModelOrigin, target: URL, modelID: String) throws -> ModelDownload {
        if let prior = jobs.first(where: { $0.repairTarget == target.path && $0.state != .complete && $0.repairFingerprint == (try? RepairFingerprint.read(target)) }) { selectedTaskID = prior.id; return prior }
        guard target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == target.deletingLastPathComponent().standardizedFileURL.path else { throw LaunchError.message("修复目录包含链接") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = target.deletingLastPathComponent().appendingPathComponent(".model-manager-repairs").standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else { throw LaunchError.message("修复暂存目录包含链接，请检查模型位置") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var job = ModelDownload(site: source.site, repository: source.repository, revision: source.revision, root: root.path, folder: UUID().uuidString + "/snapshots/" + source.revision, files: [file])
        job.repairTarget = target.path; job.repairFingerprint = try RepairFingerprint.read(target); job.repairModelID = modelID
        _ = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path); try DownloadPaths.validateURL(file.url)
        job.sourceURL = source.sourceURL
        jobs.insert(job, at: 0); selectedTaskID = job.id
        guard save() else { throw LaunchError.message("修复任务未能保存") }
        run(job.id, allowReplacement: false)
        return job
    }
    func resume(_ id: String, includingPausedFiles: Bool = false) {
        guard !isScheduled(id), !deletingIDs.contains(id), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        message = nil; notice = nil
        if includingPausedFiles { jobs[index].pausedFiles = [] }
        let job = jobs[index]
        do {
            guard job.resumeBlockedReason == nil else { throw DownloadResumeError.unavailable(job.resumeBlockedReason!) }
            jobs[index] = try DownloadRecovery.reconcile(job); run(id, allowReplacement: job.replacementOf == nil)
        } catch let error as DownloadResumeError {
            jobs[index].resumeBlockedReason = error.localizedDescription; jobs[index].error = error.localizedDescription
            add(listing: .init(site: job.site, repository: job.repository, revision: job.revision, files: job.files, sourceURL: job.sourceURL), files: job.files, root: URL(fileURLWithPath: job.root).resolvingSymlinksInPath().standardizedFileURL, replacing: job)
        } catch { message = error.localizedDescription }
    }
    private func start(_ id: String, allowReplacement: Bool, credential: String) {
        guard !isActive(id), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let execution = DownloadExecution(); executions[id] = execution; activeIDs.insert(id); execution.pauseRequested = false; execution.interruptedFile = nil; jobs[index].state = .downloading; jobs[index].error = nil
        guard save() else { activeIDs.remove(id); executions.removeValue(forKey: id); jobs[index].state = .paused; return }
        let original = jobs[index], generation = UUID(); execution.speedGeneration = generation
        execution.rate = DownloadRate(); execution.networkBytes = 0; execution.fileBaseline = nil; speeds[id] = 0
        execution.speedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.isActive(id), !execution.pauseRequested, execution.fileBaseline != nil else { return }
            guard self.transferPhases[id] == .downloading else { self.speeds[id] = 0; return }
            self.speeds[id] = execution.rate.record(bytes: execution.networkBytes, at: ProcessInfo.processInfo.systemUptime)
        } }
        execution.speedTimer = timer; RunLoop.main.add(timer, forMode: .common)
        Task {
            var replacement: ModelDownload?
            do {
                let root = URL(fileURLWithPath: original.root)
                while true {
                    guard let current = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    if execution.pauseRequested { throw CancellationError() }
                    let pending = jobs[current].files.filter { !jobs[current].finished.contains($0.path) && !(jobs[current].pausedFiles?.contains($0.path) ?? false) }
                    guard let file = pending.first(where: { $0.path == jobs[current].priorityFile }) ?? pending.first else { break }
                    jobs[current].currentFile = file.path; execution.fileBaseline = nil
                    execution.rate = DownloadRate(); execution.networkBytes = 0; speeds[id] = 0; transferPhases[id] = .checking
                    let fileGeneration = UUID(); execution.speedGeneration = fileGeneration
                    try DownloadPaths.validateURL(file.url)
                    let eligible = CatalogHTTP.credentialHosts.contains(file.url.host?.lowercased() ?? "")
                    let worker = try DownloadTransfer(file: file, root: root, folder: original.folder, token: eligible ? credential : "", protocolClasses: transferProtocolClasses, phase: { [weak self = self] phase in
                        Task { @MainActor in
                            guard let self, self.isActive(id), execution.speedGeneration == fileGeneration else { return }
                            self.transferPhases[id] = phase
                            if phase != .downloading { self.speeds[id] = 0 }
                        }
                    }) { [weak self = self] received, total in
                        Task { @MainActor in
                            guard let self, self.isActive(id), execution.speedGeneration == fileGeneration, let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .downloading else { return }
                            if let baseline = execution.fileBaseline, received < baseline { return }
                            var counts = self.jobs[i].fileReceived ?? [:]; counts[file.path] = received; self.jobs[i].fileReceived = counts
                            self.jobs[i].received = counts.values.reduce(0, +)
                            if let baseline = execution.fileBaseline { execution.networkBytes += max(0, received - baseline) }
                            execution.fileBaseline = received
                            self.speeds[id] = execution.rate.record(bytes: execution.networkBytes, at: ProcessInfo.processInfo.systemUptime)
                            if execution.pauseRequested { self.speeds[id] = 0 }
                            if self.transferPhases[id] != .downloading { self.speeds[id] = 0 }
                            if total > 0, let f = self.jobs[i].files.firstIndex(where: { $0.path == file.path }), self.jobs[i].files[f].bytes == 0 { self.jobs[i].files[f].bytes = total }
                            self.synchronizeSharedProgress(id)
                        }
                    }
                    execution.transfer = worker
                    do { try await worker.run() }
                    catch {
                        execution.transfer = nil; execution.speedGeneration = UUID()
                        if execution.interruptedFile?.id == id && execution.interruptedFile?.path == file.path && !execution.pauseRequested {
                            execution.interruptedFile = nil
                            guard let i = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                            jobs[i] = try DownloadRecovery.reconcile(jobs[i]); jobs[i].currentFile = ""
                            synchronizeSharedProgress(id); save()
                            continue
                        }
                        throw error
                    }
                    execution.transfer = nil; execution.interruptedFile = nil
                    guard let current = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    if let f = jobs[current].files.firstIndex(where: { $0.path == file.path }), jobs[current].files[f].bytes == 0 { jobs[current].files[f].bytes = worker.completedBytes }
                    jobs[current].finished.insert(file.path)
                    jobs[current].pausedFiles?.remove(file.path)
                    if jobs[current].priorityFile == file.path { jobs[current].priorityFile = nil }
                    var counts = jobs[current].fileReceived ?? [:]; counts[file.path] = worker.completedBytes; jobs[current].fileReceived = counts
                    jobs[current].received = counts.values.reduce(0, +); synchronizeSharedProgress(id); save()
                }
                if execution.pauseRequested { throw CancellationError() }
                if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].finished.count < jobs[i].files.count {
                    jobs[i].currentFile = ""
                    throw DownloadFilesSuspended()
                }
                if original.site != .direct {
                    let receipt = try DownloadPaths.destination(root: root, folder: original.folder, file: "model-manager-source.json")
                    var origin = ModelOrigin(site: original.site, repository: original.repository, revision: original.revision, files: original.files.map(\.path), sourceURL: original.sourceURL)
                    if let data = try? Data(contentsOf: receipt), let prior = try? JSONDecoder().decode(ModelOrigin.self, from: data), prior.site == origin.site, prior.repository == origin.repository, prior.revision == origin.revision {
                        origin.files = Array(Set(prior.files + origin.files)).sorted()
                    }
                    try JSONEncoder().encode(origin).write(to: receipt, options: .atomic)
                }
                if original.site == .huggingface {
                    let parts = original.folder.components(separatedBy: "/")
                    guard let snapshot = parts.lastIndex(of: "snapshots"), snapshot > 0 else { throw LaunchError.message("模型快照目录无效") }
                    let refs = parts.prefix(snapshot).joined(separator: "/") + "/refs"
                    let ref = try DownloadPaths.destination(root: root, folder: refs, file: "main")
                    try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(original.revision.utf8).write(to: ref, options: .atomic)
                }
                if let i = jobs.firstIndex(where: { $0.id == id }) {
                    if jobs[i].repairTarget != nil { guard let onRepair else { throw LaunchError.message("修复文件已下载；请在管理界面继续任务以应用修复") }; try onRepair(jobs[i]) }
                    jobs[i].state = .complete; jobs[i].currentFile = ""; jobs[i].received = jobs[i].total
                    if jobs[i].repairTarget == nil { onImported?(jobs[i].root) }
                }
            } catch {
                if let i = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[i].state = execution.pauseRequested || error is CancellationError || error is DownloadFilesSuspended ? .paused : .failed
                    jobs[i].error = jobs[i].state == .failed ? error.localizedDescription : nil
                    if let restored = try? DownloadRecovery.reconcile(jobs[i]) { jobs[i] = restored }
                    if error is DownloadFilesSuspended { notice = "其余文件已下载，剩余文件已单独暂停。可在文件详情中继续。"; if jobs[i].finished.isEmpty { notice = "所有文件已暂停，可在文件详情中继续。"} }
                    if error is DownloadResumeError && !execution.pauseRequested {
                        jobs[i].resumeBlockedReason = error.localizedDescription
                        if allowReplacement && jobs[i].replacementOf == nil && !deletingIDs.contains(id) { replacement = jobs[i] }
                    }
                }
            }
            synchronizeSharedProgress(id)
            execution.transfer = nil; execution.interruptedFile = nil; activeIDs.remove(id); executions.removeValue(forKey: id); execution.speedGeneration = UUID(); speeds.removeValue(forKey: id); transferPhases.removeValue(forKey: id); execution.speedTimer?.invalidate(); execution.speedTimer = nil; save()
            if let job = replacement { add(listing: .init(site: job.site, repository: job.repository, revision: job.revision, files: job.files, sourceURL: job.sourceURL), files: job.files, root: URL(fileURLWithPath: job.root), replacing: job, credential: credential) }
            pump()
        }
    }
    func pause(_ id: String) {
        pending.removeAll { $0.id == id }
        if let execution = executions[id] { execution.pauseRequested = true; speeds[id] = 0; execution.transfer?.cancel() }
        else if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .queued { jobs[i].state = .paused; jobs[i].currentFile = "" }
        save(); pump()
    }
    func pause() { pauseAll() }
    func pauseAll() {
        let waiting = pending.map(\.id); pending.removeAll()
        for i in jobs.indices where waiting.contains(jobs[i].id) { jobs[i].state = .paused }
        for (id, execution) in executions { execution.pauseRequested = true; speeds[id] = 0; execution.transfer?.cancel() }
        save()
    }
    func canControlFiles(_ id: String) -> Bool { !deletingIDs.contains(id) && executions[id]?.pauseRequested != true }
    func pauseFile(_ id: String, path: String) {
        guard canControlFiles(id), let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].files.contains(where: { $0.path == path }), !jobs[i].finished.contains(path) else { return }
        var paused = jobs[i].pausedFiles ?? []; paused.insert(path); jobs[i].pausedFiles = paused
        if jobs[i].priorityFile == path { jobs[i].priorityFile = nil }
        if let execution = executions[id], jobs[i].currentFile == path { execution.interruptedFile = (id, path); speeds[id] = 0; execution.transfer?.cancel() }
        save()
    }
    func resumeFile(_ id: String, path: String, first: Bool = false) {
        guard canControlFiles(id), let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].files.contains(where: { $0.path == path }), !jobs[i].finished.contains(path) else { return }
        jobs[i].pausedFiles?.remove(path)
        if first { jobs[i].priorityFile = path }
        if let execution = executions[id], first && jobs[i].currentFile != path {
            execution.interruptedFile = (id, jobs[i].currentFile); speeds[id] = 0; execution.transfer?.cancel()
        }
        save()
        if !isScheduled(id) { resume(id) }
    }
    func resumeAllFiles(_ id: String) {
        guard canControlFiles(id), let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].pausedFiles = []; save()
        if !isScheduled(id) { resume(id) }
    }
    func showTask(_ id: String) {
        guard jobs.contains(where: { $0.id == id }) else { return }
        selectedTaskID = id
    }
    func removeTask(_ id: String) async throws {
        guard jobs.contains(where: { $0.id == id }), !deletingIDs.contains(id) else { return }
        deletingIDs.insert(id); defer { deletingIDs.remove(id) }
        if isScheduled(id) {
            pause(id)
            let deadline = Date().addingTimeInterval(10)
            while isActive(id) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            guard !isActive(id) else { throw LaunchError.message("任务仍在停止，请稍后再删除") }
        }
        jobs.removeAll { $0.id == id }; speeds.removeValue(forKey: id)
        if selectedTaskID == id { selectedTaskID = activeID ?? jobs.first?.id }
        guard save() else { throw LaunchError.message(message ?? "删除任务未能保存") }
        notice = "任务记录已删除，已下载文件和未完成文件保留。"
    }
    func cleanPartials(_ id: String) throws {
        guard !isScheduled(id), let job = jobs.first(where: { $0.id == id }) else { throw LaunchError.message("请先暂停任务，再清理未完成文件") }
        if jobs.contains(where: { $0.id != id && isScheduled($0.id) && Self.overlaps($0.displayLocation, job.displayLocation) }) { throw LaunchError.message("另一个任务正在使用此目录，请先暂停下载") }
        let root = URL(fileURLWithPath: job.root)
        var deletions: [(URL, FileIdentity)] = [], locks: [Int32] = []
        defer { for lock in locks { DownloadWriteLock.release(lock) } }
        for file in job.files {
            let partial = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path + ".incomplete")
            let metadata = try DownloadPaths.destination(root: root, folder: job.folder, file: file.path + ".incomplete.metadata.json")
            let hasPartial = FileManager.default.fileExists(atPath: partial.path), hasMetadata = FileManager.default.fileExists(atPath: metadata.path)
            guard hasPartial || hasMetadata else { continue }
            let shared = jobs.contains { other in
                guard other.id != id else { return false }
                return other.files.contains { entry in
                    (try? DownloadPaths.destination(root: URL(fileURLWithPath: other.root), folder: other.folder, file: entry.path + ".incomplete").path) == partial.path
                }
            }
            guard !shared else { throw LaunchError.message("此未完成文件还被其他任务共用。可先删除多余的任务记录，文件会保留。") }
            locks.append(try DownloadWriteLock.acquire(root: root, folder: job.folder, file: file.path))
            if hasPartial || hasMetadata {
                let receipt = (try? Data(contentsOf: metadata)).flatMap { try? JSONDecoder().decode(TransferReceipt.self, from: $0) }
                guard receipt?.url == file.url else { throw LaunchError.message("未完成文件的归属无法确认，已保留") }
            }
            for path in [partial, metadata] where FileManager.default.fileExists(atPath: path.path) {
                guard let identity = FileIdentity.read(path.path) else { throw LaunchError.message("未完成文件已变化，请重新检查") }
                deletions.append((path, identity))
            }
        }
        for (path, identity) in deletions { guard FileIdentity.read(path.path) == identity else { throw LaunchError.message("未完成文件已变化，已停止清理") } }
        for (path, _) in deletions { try FileManager.default.removeItem(at: path) }
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].error = nil; jobs[i].state = .paused
            if let restored = try? DownloadRecovery.reconcile(jobs[i]) { jobs[i] = restored }
        }
        save()
    }
}
