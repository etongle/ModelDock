import SwiftUI

enum LocalModelVersions {
    static func key(_ model: LocalModel) -> String? { ModelOrigin.replacement(model) ?? ModelOrigin.read(model)?.repository }
    static func related(_ model: LocalModel, models: [LocalModel]) -> [LocalModel] {
        guard let key = key(model) else { return [model] }
        return models.filter { $0.kind == .language && self.key($0) == key }.sorted {
            if ($0.id == model.id) != ($1.id == model.id) { return $0.id == model.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

@MainActor
struct ModelLocalVersions: View {
    @ObservedObject var store: AppStore
    var model: LocalModel
    var versions: [LocalModel] { LocalModelVersions.related(model, models: store.models) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: L10n.text(versions.count > 1 ? "新旧版本并存" : "本地版本")).font(.system(size: TypeScale.body, weight: .semibold))
            Text(verbatim: L10n.text(versions.count > 1 ? "更新会保留旧模型。选择版本后配置服务，运行中的服务继续使用已启动版本；不用的版本可以移至废纸篓。" : "当前只有一个本地版本。引擎的准备登记和配套组件归属于此版本，不单独计作模型版本。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            if versions.count > 1 {
                ForEach(versions) { version in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: L10n.text(version.name)).font(.system(size: TypeScale.body, weight: .medium)).lineLimit(2)
                            Text(verbatim: L10n.text(version.format + " · " + sizeLabel(version.bytes) + (ModelOrigin.read(version).map { " · " + String($0.revision.prefix(12)) } ?? ""))).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if version.id == model.id { Text(verbatim: L10n.text("当前查看")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.linkColor) }
                        else { Button(L10n.text("选择版本")) { store.showModelFile(version) }.buttonStyle(.bordered) }
                        Button(role: .destructive) { store.deleteModel(version) } label: { Image(systemName: "trash") }.buttonStyle(.bordered).help(L10n.text("移至废纸篓；使用中的模型会被拦截")).disabled(store.modelFiles.deletingID != nil)
                    }.padding(12).background(Theme.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }.accessibilityIdentifier("local-model-versions")
    }
}

@MainActor
extension AppStore {
    func showModelFile(_ model: LocalModel) {
        search = ""; modelEngineFilter = ""; modelFilter = "全部"
        selectedFileID = model.id; tab = .models
    }
    func downloadedModels(_ job: ModelDownload) -> [LocalModel] {
        let folder = URL(fileURLWithPath: job.root).appendingPathComponent(job.folder).standardizedFileURL.path
        return models.filter { $0.kind == .language && $0.complete && ($0.path == folder || $0.path.hasPrefix(folder + "/")) }
    }
    func showDownloadedModel(_ job: ModelDownload) {
        if let model = downloadedModels(job).first { showModelFile(model); return }
        scan()
        Task {
            for _ in 0..<100 {
                if let model = downloadedModels(job).first { showModelFile(model); return }
                if !scanning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            downloads.message = "文件已下载，但尚未识别为完整主模型。请检查所选文件与模型配置。"
        }
    }
}
