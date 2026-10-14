import Foundation
import Darwin

struct RepairFingerprint: Codable, Equatable {
    var parentDevice: Int32; var parentInode: UInt64
    var exists: Bool; var device: Int32; var inode: UInt64; var bytes: Int64; var seconds: Int64; var nanos: Int64
    static func read(_ target: URL) throws -> Self {
        let parent = target.deletingLastPathComponent()
        guard parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL else { throw LaunchError.message("修复目标目录包含链接，请检查文件位置") }
        var folder = stat(); guard lstat(parent.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR else { throw LaunchError.message("修复目标目录不存在") }
        var file = stat(); let exists = lstat(target.path, &file) == 0
        guard exists || errno == ENOENT else { throw LaunchError.message("无法读取待修复文件") }
        guard !exists || [S_IFREG, S_IFLNK].contains(file.st_mode & S_IFMT) else { throw LaunchError.message("修复只支持模型文件") }
        return .init(parentDevice: folder.st_dev, parentInode: folder.st_ino, exists: exists, device: file.st_dev, inode: file.st_ino, bytes: file.st_size, seconds: Int64(file.st_mtimespec.tv_sec), nanos: Int64(file.st_mtimespec.tv_nsec))
    }
}
enum ModelFileRepair {
    static func publish(_ job: ModelDownload) throws {
        guard let path = job.repairTarget, let fingerprint = job.repairFingerprint, job.files.count == 1, let file = job.files.first, job.finished.contains(file.path) else { throw LaunchError.message("单文件修复任务信息不完整") }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard target.path.hasPrefix("/"), try RepairFingerprint.read(target) == fingerprint else { throw LaunchError.message("原文件或目录在下载期间改变，已下载的修复文件保留；请重新检查并创建修复任务") }
        let source = try DownloadPaths.destination(root: URL(fileURLWithPath: job.root), folder: job.folder, file: file.path)
        guard FileManager.default.fileExists(atPath: source.path), (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(file.bytes) else { throw LaunchError.message("修复文件未完整下载") }
        let parent = target.deletingLastPathComponent(), backup = parent.appendingPathComponent(".model-manager-repair-backups/" + job.id)
        guard UUID(uuidString: job.id) != nil, backup.resolvingSymlinksInPath().standardizedFileURL.path == backup.standardizedFileURL.path else { throw LaunchError.message("修复备份目录无效") }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        // Creating a directory can change URL's directory hint. Compare canonical
        // paths so that hint changes do not reject the newly created safe folder.
        guard backup.resolvingSymlinksInPath().standardizedFileURL.path == backup.standardizedFileURL.path else { throw LaunchError.message("修复备份目录无效") }
        if fingerprint.exists && FileIdentity.read(backup.appendingPathComponent(target.lastPathComponent).path) == nil {
            // Copy a snapshot symlink itself: never alter its shared cache blob.
            try FileManager.default.copyItem(at: target, to: backup.appendingPathComponent(target.lastPathComponent))
        }
        let prepared = parent.appendingPathComponent(".model-manager-repair-" + job.id)
        defer { try? FileManager.default.removeItem(at: prepared) }
        try FileManager.default.linkItem(at: source, to: prepared)
        guard try RepairFingerprint.read(target) == fingerprint else { throw LaunchError.message("原文件发生变化，修复文件保留") }
        guard rename(prepared.path, target.path) == 0 else { throw LaunchError.message("无法应用修复；原文件及修复下载保留") }
    }
    static func reference(model: LocalModel, entry: ModelFileEntry) throws -> (ModelOrigin, URL, String) {
        guard model.format != "Ollama" else { throw LaunchError.message("Ollama 模型层由原引擎管理，请在引擎中重新拉取该模型") }
        var target = URL(fileURLWithPath: entry.path).standardizedFileURL
        if model.splashSelection != nil {
            guard let files = jsonFile(URL(fileURLWithPath: model.folder).appendingPathComponent("model.json"))?["files"] as? [String: [String: Any]], let path = files[entry.name]?["path"] as? String else { throw LaunchError.message("此组件需要在 Splash 中重新准备；无法确定单文件来源") }
            target = URL(fileURLWithPath: path).standardizedFileURL
        }
        var sourceModel = model; sourceModel.path = target.path
        sourceModel.origin = model.splashSelection == nil && target.path.hasPrefix(ModelOrigin.sourceRoot(model).path + "/") ? model.origin : nil
        guard let source = ModelOrigin.read(sourceModel), source.site != .direct, !source.revision.isEmpty else { throw LaunchError.message("未找到此文件的模型网站和版本；请通过下载导入登记来源后修复") }
        let root = ModelOrigin.sourceRoot(sourceModel)
        guard target.path.hasPrefix(root.path + "/") else { throw LaunchError.message("文件不在模型来源目录中，无法安全修复") }
        let relative = String(target.path.dropFirst(root.path.count + 1))
        guard DownloadPaths.safeRelative(relative) else { throw LaunchError.message("文件相对位置无效") }
        return (source, target, relative)
    }
}
@MainActor extension AppStore {
    func repairFile(_ model: LocalModel, entry: ModelFileEntry) {
        guard repairingFile == nil else { return }; repairingFile = entry.id
        Task {
            defer { repairingFile = nil }
            do {
                let (source, target, relative) = try ModelFileRepair.reference(model: model, entry: entry)
                await services.refresh()
                guard !ModelFileSafety.used(model, removal: target, services: services.records, external: services.external, models: models) else { throw LaunchError.message("此文件正在被服务使用，请先停止相关服务；修复不会改动其他文件") }
                var address = source.site == .huggingface ? "https://huggingface.co/" : "https://modelscope.cn/models/"
                address += source.repository + (source.site == .huggingface ? "/tree/" : "/files?revision=") + source.revision
                let listing = try await ModelCatalog.listing(address, token: downloads.token)
                let file = listing.files.first(where: { $0.path == relative }) ?? (relative == "tokenizer 文件" ? ["tokenizer.json", "tokenizer.model", "vocab.json"].compactMap { candidate in listing.files.first { $0.path == candidate } }.first : nil)
                guard listing.revision == source.revision, let file else { throw LaunchError.message("原版本仓库没有“\(relative)”。这可能是可选组件或检查误报，请查看模型说明；不会下载整套模型。") }
                let destination = relative == "tokenizer 文件" ? target.deletingLastPathComponent().appendingPathComponent(file.path) : target
                _ = try downloads.createRepair(file: file, source: source, target: destination, modelID: model.id)
                tab = .downloads
            } catch { message = error.localizedDescription }
        }
    }
}
