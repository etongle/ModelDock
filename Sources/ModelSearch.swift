import Foundation
import SwiftUI

/// Hugging Face 模型搜索结果（公开 /api/models 接口）。
struct ModelSearchResult: Identifiable, Hashable {
    var id: String
    var downloads: Int
    var likes: Int
    var tags: [String]
    var pipeline: String?
    var formats: [String] { ["gguf", "mlx", "safetensors"].filter(tags.contains).map { $0 == "gguf" ? "GGUF" : $0 == "mlx" ? "MLX" : "Safetensors" } }
}

enum ModelSearchFormat: String, CaseIterable, Identifiable {
    case all, gguf, mlx
    var id: String { rawValue }
    var title: String { switch self { case .all: return "全部格式"; case .gguf: return "GGUF"; case .mlx: return "MLX" } }
}

enum ModelSearch {
    static func url(_ query: String, format: ModelSearchFormat, limit: Int = 30) -> URL? {
        var components = URLComponents(string: "https://huggingface.co/api/models")
        var items = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: String(limit))]
        if format != .all { items.append(URLQueryItem(name: "filter", value: format.rawValue)) }
        components?.queryItems = items
        return components?.url
    }
    static func parse(_ data: Data) throws -> [ModelSearchResult] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw LaunchError.message("搜索结果格式无法识别") }
        return list.compactMap { item in
            guard let id = (item["id"] ?? item["modelId"]) as? String else { return nil }
            return .init(id: id, downloads: (item["downloads"] as? NSNumber)?.intValue ?? 0, likes: (item["likes"] as? NSNumber)?.intValue ?? 0,
                         tags: item["tags"] as? [String] ?? [], pipeline: item["pipeline_tag"] as? String)
        }
    }
    static func search(_ query: String, format: ModelSearchFormat, token: String) async throws -> [ModelSearchResult] {
        guard let url = url(query, format: format) else { throw LaunchError.message("搜索关键词无效") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LaunchError.message("Hugging Face 搜索失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）") }
        return try parse(data)
    }
    /// 下载前按文件大小粗判能否放进本机：权重 + 运行开销，对照 GPU 可用的 75% 物理内存（不含上下文缓存）。
    static func fit(bytes: Int64, memory: UInt64) -> MemoryEstimate.Level? {
        guard bytes > 0, memory > 0 else { return nil }
        let estimate = MemoryEstimate(weights: bytes, cache: nil, overhead: 512 * 1_048_576 + bytes / 20)
        return estimate.level(available: memory * 3 / 5, total: memory)
    }
}

@MainActor
final class ModelSearchController: ObservableObject {
    @Published var query = ""
    @Published var format: ModelSearchFormat = .all
    @Published var results: [ModelSearchResult] = []
    @Published var searching = false
    @Published var error: String?
    @Published var searched = false
    private var task: Task<Void, Never>?
    func search(token: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task?.cancel(); searching = true; error = nil
        let format = format
        task = Task { [weak self] in
            do {
                let found = try await ModelSearch.search(text, format: format, token: token)
                guard !Task.isCancelled else { return }
                self?.results = found; self?.searched = true
            } catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
            self?.searching = false
        }
    }
}

/// 下载页顶部的 Hugging Face 搜索。选择结果后填入地址并解析文件列表。
@MainActor struct ModelSearchView: View {
    @ObservedObject var search: ModelSearchController
    @ObservedObject var downloads: DownloadController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField(L10n.text("搜索 Hugging Face 模型，例如 qwen3 gguf"), text: $search.query).textFieldStyle(.roundedBorder).font(.system(size: TypeScale.body))
                    .onSubmit { search.search(token: downloads.token) }.accessibilityIdentifier("model-search")
                Picker(L10n.text("格式"), selection: $search.format) { ForEach(ModelSearchFormat.allCases) { Text(verbatim: L10n.text($0.title)).tag($0) } }.labelsHidden().fixedSize()
                Button { search.search(token: downloads.token) } label: { Label(L10n.text("搜索"), systemImage: "magnifyingglass") }.buttonStyle(SecondaryButton())
                    .disabled(search.searching || search.query.trimmingCharacters(in: .whitespaces).isEmpty)
                if search.searching { ProgressView().controlSize(.small) }
            }
            if let error = search.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText) }
            if search.searched && search.results.isEmpty && !search.searching { Text(verbatim: L10n.text("没有找到匹配的模型，换个关键词试试。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted) }
            if !search.results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(search.results) { result in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: result.id).font(.system(size: TypeScale.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Text(verbatim: ([result.formats.joined(separator: " / "), result.pipeline ?? ""].filter { !$0.isEmpty } + [L10n.text("下载 \(result.downloads.formatted())"), "♥ \(result.likes.formatted())"]).joined(separator: " · "))
                                        .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button(L10n.text("选择")) { downloads.address = result.id; downloads.resolve() }.buttonStyle(SecondaryButton()).disabled(downloads.resolving)
                            }.padding(.vertical, 9)
                            if result.id != search.results.last?.id { Divider() }
                        }
                    }.padding(.horizontal, 16)
                }.frame(maxHeight: 300).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// 文件选择列表中 GGUF 文件的内存适配标签。
@MainActor struct ModelFitTag: View {
    var bytes: Int64
    var memory: UInt64
    var body: some View {
        if let level = ModelSearch.fit(bytes: bytes, memory: memory) {
            let color = level == .fits ? Theme.successText : level == .tight ? Theme.warningText : Theme.errorText
            Text(verbatim: L10n.text(level == .fits ? "本机可运行" : level == .tight ? "内存偏紧" : "超出本机内存"))
                .font(.system(size: TypeScale.caption, weight: .medium)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.12), in: Capsule())
                .help(L10n.text("按文件大小估算，未计入上下文缓存"))
        }
    }
}
