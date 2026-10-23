import Foundation

enum ModelUpdateStatus {
    case unchecked, current, incomplete, available, unknown, differentRepository, unmatched
    var title: String {
        switch self {
        case .unchecked: return "尚未检查更新"
        case .current: return "已是最新版本，无需更新"
        case .incomplete: return "没有新版本，本地文件需要补齐"
        case .available: return "发现不同版本，可以下载"
        case .unknown: return "本地版本未记录，无法判断是否有更新"
        case .differentRepository: return "已选择另一个模型仓库"
        case .unmatched: return "版本相同，仓库中未找到当前模型文件"
        }
    }
    var detail: String {
        switch self {
        case .unchecked: return "检查后会显示是否有新版本，以及本地文件是否齐全。"
        case .current: return "仓库版本与本地一致，当前模型所需文件已存在（大小检查通过）。"
        case .incomplete: return "仓库版本与本地一致；仅选择缺失或大小不符的文件，已有文件不会重复下载。"
        case .available: return "仓库版本与本地不同。下载到独立目录，现有服务继续使用原版本。"
        case .unknown: return "已找到模型来源，但本地没有版本记录。下载仓库版本会保留原文件。"
        case .differentRepository: return "该地址与此模型原来的仓库不同，不能作为当前模型的版本比较。"
        case .unmatched: return "请核对仓库地址或文件名，不能据此确认当前模型已是最新。"
        }
    }
}

@MainActor
extension AppStore {
    func prepareModelUpdate(_ model: LocalModel) {
        var value = model
        value.origin = ModelOrigin.read(model) ?? modelSources[model.path] ?? ModelOrigin.fromDownloads(model, jobs: downloads.jobs)
        modelUpdate = ModelUpdateDraft(model: value)
    }
    func rememberModelSource(_ model: LocalModel, listing: RemoteListing) throws {
        guard listing.site != .direct, ModelOrigin.validRepository(listing.repository) else { return }
        // A URL association does not establish which revision the existing bytes came from.
        var updated = modelSources
        updated[model.path] = .init(site: listing.site, repository: listing.repository, revision: "", files: [], sourceURL: listing.sourceURL)
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: downloads.directory.appendingPathComponent("model-sources.json"), options: .atomic)
        modelSources = updated
    }
}
