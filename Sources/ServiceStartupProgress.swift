import Foundation
import SwiftUI
import Darwin

enum StartupStage: String {
    case preparing, downloading, loading, initializing, checking, ready
    var title: String {
        switch self {
        case .preparing: return "准备启动"
        case .downloading: return "下载配套组件"
        case .loading: return "加载模型权重"
        case .initializing: return "初始化引擎"
        case .checking: return "检查服务接口"
        case .ready: return "服务就绪"
        }
    }
}

struct ServiceStartupProgress {
    var stage: StartupStage = .preparing
    var percentage: Double?
    var measurement = "阶段进度"
    var detail = "等待引擎报告启动进度"
    var percentageLabel: String? { percentage.map { String(format: "%.1f%%", $0) } }
    var summary: String { stage.title + (percentageLabel.map { " · " + $0 } ?? "") }
    static func latestAttempt(_ log: String) -> String {
        log.range(of: "\n—— ", options: .backwards).map { String(log[$0.upperBound...]) } ?? log
    }

    static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func parse(log: String, status: ServiceStatus) -> ServiceStartupProgress {
        if status == .running { return .init(stage: .ready, percentage: 100, detail: "模型接口已通过检查，可以接入使用") }
        // Logs append across retries. A previous successful start must not
        // contribute progress to the current attempt.
        let attempt = latestAttempt(log)
        let clean = attempt.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        var progress = ServiceStartupProgress()
        func phase(_ stage: StartupStage, _ detail: String) {
            progress.stage = stage; progress.detail = detail
            progress.percentage = nil; progress.measurement = "阶段进度"
        }
        for raw in clean.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.contains("fetching ") || lower.contains("downloading ") || lower.contains("download progress") {
                if progress.stage != .downloading { phase(.downloading, "复用本机缓存，下载缺少的配套文件") }
                if lower.contains("dflash") { progress.detail = "下载 DFlash 草稿模型，主模型缓存会保留" }
                if let size = match(#"([0-9.]+\s*[KMGT]?B)\s*,?\s*from\s+([^\s;]+)"#, in: line) {
                    progress.detail = "配套模型 " + size[2] + " · " + size[1]
                }
            } else if lower.contains("loading") && !lower.contains("downloading") || lower.contains("load_tensors") || lower.contains("load model weights") {
                if progress.stage != .loading { phase(.loading, "正在读取本机权重并准备模型") }
            } else if lower.contains("kernel policy") || lower.contains("initializ") || lower.contains("warming up") || lower.contains("warmup") || lower.contains("metal_init") || lower.contains("compute buffer") {
                if progress.stage != .initializing { phase(.initializing, "正在初始化计算资源") }
            } else if lower.contains("ready ·") || lower.contains("model processor loaded") || lower.contains("uvicorn running") || lower.contains("application startup complete") || lower.contains("http server is listening") {
                phase(.checking, "引擎已启动，等待模型接口通过检查")
            }
            if [.downloading, .loading, .initializing].contains(progress.stage),
               let value = match(#"(?<![0-9.])([0-9]+(?:\.[0-9]+)?)\s*%"#, in: line),
               let percent = Double(value[1]), (0...100).contains(percent) {
                progress.percentage = percent
                if progress.stage == .downloading {
                    progress.measurement = lower.contains("fetching ") ? "文件完成进度" : "当前文件进度"
                } else { progress.measurement = "阶段进度" }
                if let count = match(#"\|\s*([0-9]+)\s*/\s*([0-9]+)\s*\["#, in: line), progress.stage == .downloading {
                    let suffix = " · 已完成 " + count[1] + " / " + count[2] + " 个文件"
                    progress.detail = progress.detail.components(separatedBy: " · 已完成 ").first! + suffix
                }
            }
        }
        return progress
    }

    static func draftSource(_ log: String) -> (repository: String, revision: String)? {
        for line in latestAttempt(log).components(separatedBy: .newlines).reversed() {
            if let parts = match(#"Fetching.*from\s+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([a-f0-9]{12,40})"#, in: line),
               ModelOrigin.validRepository(parts[1]), parts[1].contains("DFlash") { return (parts[1], parts[2]) }
        }
        return nil
    }

    // Xet can write chunks out of order, so logical file length alone is
    // not a transfer counter. Count allocated bytes, and exclude partials
    // left by earlier attempts. This is explicitly shown as an estimate.
    static func cachedDraft(log: String, root: URL, startedAt: Date?) -> (received: Int64, total: Int64)? {
        guard let source = draftSource(log) else { return nil }
        let repo = root.appendingPathComponent("models--" + source.repository.replacingOccurrences(of: "/", with: "--"))
        let trees = (try? FileManager.default.contentsOfDirectory(at: repo.appendingPathComponent("trees"), includingPropertiesForKeys: nil)) ?? []
        guard let tree = trees.first(where: { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 40 && $0.deletingPathExtension().lastPathComponent.allSatisfy(\.isHexDigit) && $0.lastPathComponent.hasPrefix(source.revision) }),
              let files = jsonFile(tree)?["files"] as? [String: [String: Any]],
              files["model.safetensors"] != nil, files["config.json"] != nil else { return nil }
        let blobs = repo.appendingPathComponent("blobs")
        let partials = (try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var total: Int64 = 0, received: Int64 = 0
        for name in ["model.safetensors", "config.json"] {
            guard let entry = files[name], let size = (entry["size"] as? NSNumber)?.int64Value, size > 0,
                  let blob = (entry["lfs_sha256"] ?? entry["blob_id"]) as? String, [40, 64].contains(blob.count), blob.allSatisfy(\.isHexDigit) else { return nil }
            total += size
            let final = blobs.appendingPathComponent(blob).resolvingSymlinksInPath()
            if let bytes = try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(bytes) == size { received += size; continue }
            let candidates = partials.filter { $0.lastPathComponent.hasPrefix(blob + ".") && $0.pathExtension == "incomplete" }.filter {
                guard let start = startedAt else { return false }
                return ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= start
            }
            let bytes = candidates.map { url -> Int64 in
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return 0 }
                return min(Int64(info.st_size), Int64(info.st_blocks) * 512)
            }.max() ?? 0
            received += min(size, bytes)
        }
        return (received, total)
    }
}

@MainActor
extension ServiceController {
    func startupProgress(_ spec: ServiceSpec) -> ServiceStartupProgress {
        let text = log(spec.id)
        var result = ServiceStartupProgress.parse(log: text, status: status(spec))
        if result.stage == .downloading && status(spec) == .starting {
            for root in startupCacheRoots(spec) {
                if let cache = ServiceStartupProgress.cachedDraft(log: text, root: root, startedAt: spec.startedAt) {
                    result.percentage = min(100, Double(cache.received) / Double(cache.total) * 100)
                    result.measurement = "磁盘写入进度（估算）"
                    result.detail = "配套草稿模型 · " + sizeLabel(cache.received) + " / " + sizeLabel(cache.total) + " · 下载完成后继续加载"
                    break
                }
            }
        }
        return result
    }
    func startupCacheRoots(_ spec: ServiceSpec) -> [URL] {
        var roots: [String] = []
        if let text = spec.commandText, let words = try? ServiceCommand.words(text) {
            if let cache = words.first(where: { $0.hasPrefix("HF_HUB_CACHE=") }) { roots.append(String(cache.dropFirst(13))) }
            if let home = words.first(where: { $0.hasPrefix("HF_HOME=") }) { roots.append(String(home.dropFirst(8)) + "/hub") }
        }
        if let hub = ModelOrigin.hubRoot(spec.modelPath) { roots.append(hub) }
        roots += [Scanner.defaultRoot.appendingPathComponent("hf-cache/hub").path, Scanner.home.appendingPathComponent(".cache/huggingface/hub").path]
        var seen = Set<String>()
        return roots.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
    }
}

@MainActor
struct StartupProgressView: View {
    @ObservedObject var services: ServiceController
    var spec: ServiceSpec
    var compact = false
    var body: some View {
        let progress = services.startupProgress(spec)
        let failed = services.status(spec) == .failed
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(spacing: 12) {
                Text(verbatim: L10n.text(failed ? "启动中断 · " + progress.stage.title : progress.stage.title)).font(.system(size: TypeScale.body, weight: .semibold))
                Spacer()
                if let percentage = progress.percentageLabel {
                    Text(verbatim: L10n.text((compact ? "" : progress.measurement + " · ") + percentage)).font(.system(size: TypeScale.body, weight: .semibold)).monospacedDigit().foregroundStyle(failed ? Color.red : Color.primary)
                } else if !failed { ProgressView().controlSize(.small) }
            }
            if let percentage = progress.percentage { ProgressView(value: percentage, total: 100).tint(failed ? .red : Theme.accent) }
            if !compact {
                Text(verbatim: L10n.text(progress.detail)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if progress.percentage == nil && !failed {
                    Text(verbatim: L10n.text("引擎尚未报告百分比，当前显示实际阶段。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                }
            }
        }.padding(compact ? 12 : 18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("startup-progress-" + spec.id)
    }
}
