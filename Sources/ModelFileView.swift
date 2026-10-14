import SwiftUI

@MainActor
struct ModelFileListView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var files: ModelFileController
    var model: LocalModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(verbatim: L10n.text("文件明细")).font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { Task { await files.load(model, models: store.models) }; store.scan() } label: { Label(L10n.text("重新检查"), systemImage: "arrow.clockwise") }.buttonStyle(.bordered).disabled(files.loading || store.scanning).accessibilityIdentifier("recheck-model-files")
            }
            HStack {
                Text(verbatim: L10n.text(files.loading ? "正在读取文件…" : "\(files.entries.count) 个文件 · \(files.entries.filter { !$0.valid }.count) 个需处理")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                TextField(L10n.text("搜索文件或类型"), text: $files.search).textFieldStyle(.roundedBorder).frame(maxWidth: 250).accessibilityIdentifier("model-file-search")
            }
            if files.loading && files.entries.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
            else if files.filtered.isEmpty { Text(verbatim: L10n.text(files.search.isEmpty ? "未发现模型文件，请重新检查文件位置。" : "没有匹配的文件。")).font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files.filtered) { file in
                            HStack(spacing: 12) {
                                Image(systemName: file.valid ? (file.role.contains("权重") ? "cube" : "doc") : "exclamationmark.triangle").foregroundStyle(file.valid ? Theme.linkColor : Theme.warningText).frame(width: 24)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(L10n.text(file.path))
                                    Text(verbatim: L10n.text(file.role + (file.references > 1 ? " · \(file.references) 个模型共用" : file.linked ? " · 缓存引用" : "") + (file.valid ? "" : file.exists ? " · 大小不符" : " · 缺失"))).font(.system(size: 11)).foregroundStyle(file.valid ? Theme.muted : Theme.warningText)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: L10n.text(file.exists ? sizeLabel(file.bytes) : "—")).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                                if !file.valid { Button(L10n.text("下载此文件修复")) { store.repairFile(model, entry: file) }.buttonStyle(.bordered).disabled(store.repairingFile != nil).help(L10n.text("仅下载原版本的这个文件；验证后应用修复")) }
                                Button { store.reveal(file.path) } label: { Image(systemName: "folder").frame(width: 44, height: 44) }.buttonStyle(.plain).disabled(!file.exists).help(L10n.text("在 Finder 中查看此文件"))
                            }.padding(.horizontal, 14).padding(.vertical, 4)
                                .contextMenu { Button(L10n.text("在 Finder 中查看")) { store.reveal(file.path) }.disabled(!file.exists); Button(L10n.text("复制文件路径")) { store.copy(file.path) } }
                            if file.id != files.filtered.last?.id { Divider().padding(.leading, 50) }
                        }
                    }
                }.frame(height: min(340, max(120, CGFloat(files.filtered.count) * 62)))
                    .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1) }
            }
            Text(verbatim: L10n.text(model.format == "Ollama" ? "登记清单与模型层分别显示。删除模型时交给 Ollama 处理，共享层保持由引擎管理。" : model.splashSelection != nil ? "此处显示 Splash 组件对原始权重的引用。移除登记会保留共享的原始权重文件。" : "检查文件是否齐全、清单大小和格式头部；不会将整套权重载入内存。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }.task(id: model) { await files.load(model, models: store.models) }.accessibilityIdentifier("model-file-list")
    }
}
