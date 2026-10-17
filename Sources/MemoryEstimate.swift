import Foundation
import SwiftUI

/// 估算 KV 缓存所需的模型结构。attentionLayers 只计入需要 KV 缓存的全注意力层。
struct ModelShape: Hashable {
    var attentionLayers: Int
    var kvHeads: Int
    var keyLength: Int
    var valueLength: Int
}

/// 启动前的内存预估：权重 + KV 缓存（按 f16 计）+ 运行开销。结果是近似上限，滑动窗口等优化会让实际值更低。
struct MemoryEstimate: Hashable {
    enum Level { case fits, tight, exceeds }
    var weights: Int64
    /// nil：读不到模型结构，未计入上下文缓存。
    var cache: Int64?
    var overhead: Int64
    var total: Int64 { weights + (cache ?? 0) + overhead }

    static func make(model: LocalModel, context: Int) -> MemoryEstimate? {
        guard model.bytes > 0, model.kind == .language else { return nil }
        let shape = Self.shape(model)
        let cache = shape.map { Int64($0.attentionLayers) * Int64($0.kvHeads) * Int64($0.keyLength + $0.valueLength) * 2 * Int64(context) }
        // 计算缓冲区随模型规模增长；固定部分覆盖运行库本身。
        return .init(weights: model.bytes, cache: cache, overhead: 512 * 1_048_576 + model.bytes / 20)
    }

    /// available：当前空闲内存；total：物理内存。macOS 默认只允许 GPU 使用约 75% 物理内存。
    func level(available: UInt64, total: UInt64) -> Level {
        if total > 0, Double(self.total) > Double(total) * 0.75 { return .exceeds }
        return UInt64(max(0, self.total)) <= available ? .fits : .tight
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var shapes: [String: ModelShape?] = [:]

    static func shape(_ model: LocalModel) -> ModelShape? {
        cacheLock.lock(); if let cached = shapes[model.path] { cacheLock.unlock(); return cached }; cacheLock.unlock()
        let url = URL(fileURLWithPath: model.path)
        let value = model.format.uppercased().contains("GGUF") ? gguf(url) : config(url)
        cacheLock.lock(); shapes[model.path] = value; cacheLock.unlock()
        return value
    }

    static func gguf(_ url: URL) -> ModelShape? {
        var architecture = "", values: [String: [Int]] = [:]
        let suffixes = [".block_count", ".attention.head_count", ".attention.head_count_kv", ".embedding_length", ".attention.key_length", ".attention.value_length", ".full_attention_interval"]
        do {
            try GGUFMetadata.scan(url) { key, type, reader in
                if key == "general.architecture", type == 8 { architecture = try reader.string(); return true }
                guard suffixes.contains(where: key.hasSuffix), !key.hasPrefix("clip.") else { return false }
                if let numbers = try reader.integers(type) { values[key] = numbers }
                return true
            }
        } catch { return nil }
        func value(_ suffix: String) -> [Int]? { values[architecture + suffix] }
        guard let layers = value(".block_count")?.first, layers > 0, let heads = value(".attention.head_count")?.max(), heads > 0 else { return nil }
        let embedding = value(".embedding_length")?.first ?? 0
        let key = value(".attention.key_length")?.first ?? (embedding / heads)
        let length = value(".attention.value_length")?.first ?? key
        // head_count_kv 可能按层给出（混合架构中线性注意力层为 0）。
        let kv = value(".attention.head_count_kv") ?? [heads]
        var attention = kv.count == layers ? kv.filter { $0 > 0 }.count : layers
        if let interval = value(".full_attention_interval")?.first, interval > 1, kv.count != layers { attention = max(1, layers / interval) }
        let kvHeads = kv.filter { $0 > 0 }.max() ?? heads
        guard key > 0 else { return nil }
        return .init(attentionLayers: attention, kvHeads: kvHeads, keyLength: key, valueLength: length)
    }

    static func config(_ url: URL) -> ModelShape? {
        guard let root = jsonFile(url.appendingPathComponent("config.json")) else { return nil }
        let text = root["text_config"] as? [String: Any] ?? root
        func int(_ key: String) -> Int? { (text[key] as? NSNumber)?.intValue ?? (root[key] as? NSNumber)?.intValue }
        guard let layers = int("num_hidden_layers"), layers > 0, let heads = int("num_attention_heads"), heads > 0 else { return nil }
        let kv = int("num_key_value_heads") ?? heads
        let dimension = int("head_dim") ?? ((int("hidden_size") ?? 0) / heads)
        guard dimension > 0 else { return nil }
        var attention = layers
        if let types = (text["layer_types"] ?? root["layer_types"]) as? [String], !types.isEmpty { attention = max(1, types.filter { $0.contains("full") }.count) }
        else if let interval = int("full_attention_interval"), interval > 1 { attention = max(1, layers / interval) }
        return .init(attentionLayers: attention, kvHeads: kv, keyLength: dimension, valueLength: dimension)
    }
}

/// 启动面板和参数卡中的一行内存预估提示。
@MainActor struct MemoryEstimateView: View {
    @ObservedObject var store: AppStore
    var model: LocalModel?
    var context: Int
    /// 编辑运行中服务时，其当前占用会在重启后释放，可计入可用内存。
    var reclaimable: Int64 = 0
    var body: some View {
        if let model, let estimate = MemoryEstimate.make(model: model, context: context) {
            let total = store.resources.system?.memoryTotal ?? store.inventory?.memoryBytes ?? 0
            let used = store.resources.system?.memoryUsed ?? 0
            let available = total > used ? total - used + UInt64(max(0, reclaimable)) : UInt64(max(0, reclaimable))
            let level = estimate.level(available: available, total: total)
            let color = level == .fits ? Theme.successText : level == .tight ? Theme.warningText : Theme.errorText
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(verbatim: L10n.text("预计占用约 \(memoryLabel(UInt64(estimate.total)))") + " · " + L10n.text(level == .fits ? "内存充足" : level == .tight ? "需要先释放其他应用的内存" : "超出 GPU 可用内存，可能无法加载"))
                        .font(.system(size: TypeScale.callout, weight: .medium)).foregroundStyle(color)
                } icon: { Image(systemName: level == .fits ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(color) }
                Text(verbatim: estimate.cache.map { L10n.text("权重 \(memoryLabel(UInt64(estimate.weights))) + 上下文缓存 \(memoryLabel(UInt64($0))) + 运行开销 \(memoryLabel(UInt64(estimate.overhead)))；当前可用 \(memoryLabel(available)) / \(memoryLabel(total))") }
                    ?? L10n.text("权重 \(memoryLabel(UInt64(estimate.weights))) + 运行开销 \(memoryLabel(UInt64(estimate.overhead)))；未能读取模型结构，未计入上下文缓存。当前可用 \(memoryLabel(available)) / \(memoryLabel(total))"))
                    .font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
            .help(L10n.text("按 f16 KV 缓存估算的近似值；滑动窗口、缓存量化等会让实际占用更低。"))
            .accessibilityElement(children: .combine)
        }
    }
}
