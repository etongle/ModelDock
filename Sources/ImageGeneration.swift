import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageGenerationProgress: Decodable {
    var stage: String
    var completed: Int
    var total: Int
    var job_id: String?
    var elapsed: Double
    var title: String {
        switch stage {
        case "loading": return "加载图片模型"
        case "encoding": return "理解提示词"
        case "denoising": return "生成图片"
        case "decoding": return "解码图片"
        case "complete": return "图片已生成"
        case "cancelled": return "已取消生成"
        case "failed": return "图片生成失败"
        default: return "准备生成"
        }
    }
}

@MainActor final class ImageGenerationSession: ObservableObject {
    @Published var prompt = ""
    @Published var size = "1024x1024"
    @Published var seed = "42"
    @Published var busy = false
    @Published var cancelling = false
    @Published var progress: ImageGenerationProgress?
    @Published var image: NSImage?
    @Published var error: String?
    private var data: Data?
    private var job: String?
    private var task: Task<Void, Never>?
    let spec: ServiceSpec
    init(spec: ServiceSpec) { self.spec = spec }
    private var ownsService: Bool { spec.pid.map { $0 > 1 && spec.processStart == processStartTime($0) } ?? false }
    func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard ownsService else { throw LaunchError.message("图片服务已停止或重新启动，请重新打开服务。") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(spec.port)" + path)!)
        request.timeoutInterval = path == "/v1/images/generations" ? 1800 : 5
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    func generate() {
        guard !busy, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 4096, let seed = UInt32(seed) else { return }
        busy = true; cancelling = false; error = nil; progress = nil; image = nil; data = nil
        let job = UUID().uuidString; self.job = job
        let body: [String: Any] = ["model": ImageModelPolicy.repository, "prompt": prompt, "size": size, "seed": seed, "n": 1, "response_format": "b64_json", "job_id": job]
        task = Task { [self] in
            let polling = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, let request = try? self.request("/modeldock/progress"),
                       let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                       let value = try? JSONDecoder().decode(ImageGenerationProgress.self, from: data), value.job_id == job { self.progress = value }
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                }
            }
            defer { polling.cancel(); busy = false; cancelling = false; self.job = nil; task = nil }
            do {
                let (bytes, response) = try await URLSession.shared.data(for: request("/v1/images/generations", body: body))
                guard bytes.count < 32_000_000, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LaunchError.message("图片服务返回了无效数据。") }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LaunchError.message((object["error"] as? [String: Any])?["message"] as? String ?? "图片生成失败，请查看服务日志。") }
                guard let entry = (object["data"] as? [[String: Any]])?.first, let encoded = entry["b64_json"] as? String,
                      let data = Data(base64Encoded: encoded), data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), let image = NSImage(data: data) else { throw LaunchError.message("图片服务未返回有效的 PNG 图片。") }
                self.data = data; self.image = image
                progress = .init(stage: "complete", completed: 8, total: 8, job_id: job, elapsed: progress?.elapsed ?? 0)
            } catch {
                if cancelling { progress = .init(stage: "cancelled", completed: 0, total: 8, job_id: job, elapsed: progress?.elapsed ?? 0) }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() {
        guard busy, !cancelling, let job else { return }
        cancelling = true
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request("/modeldock/cancel", body: ["job_id": job]))
                if (response as? HTTPURLResponse)?.statusCode != 200 { cancelling = false }
            } catch { cancelling = false; self.error = error.localizedDescription }
        }
    }
    func save() {
        guard let data else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "ModelDock-Qwen-Image.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
}

@MainActor extension AppStore {
    func imageSession(_ spec: ServiceSpec) -> ImageGenerationSession {
        let key = spec.id + ":" + String(spec.processStart ?? 0)
        if let value = imageSessions[key] { return value }
        let value = ImageGenerationSession(spec: spec); imageSessions[key] = value; return value
    }
    func showImageDownload() {
        if let job = downloads.jobs.last(where: { $0.repository == ImageModelPolicy.repository && $0.revision == ImageModelPolicy.revision }) {
            if job.state == .complete { showDownloadedModel(job) } else { downloads.showTask(job.id); tab = .downloads }
            return
        }
        downloads.beginImport(); downloads.address = "https://huggingface.co/" + ImageModelPolicy.repository + "/tree/" + ImageModelPolicy.revision
        downloads.resolve(); tab = .downloads
    }
}

@MainActor struct ImageEngineSetupView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Qwen-Image-2.1-Turbo", systemImage: "photo.badge.plus").font(.system(size: TypeScale.body, weight: .semibold))
            Text(verbatim: L10n.text("完整组件约 32.45 GB：主模型、文本编码器、VAE 与处理配置。默认 8 步生成；图片生成与 Strata 的图片问答分别运行。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            Text(verbatim: L10n.text("启动时离线加载，运行内存还包括文本编码器与图片缓存；同时使用其他大模型时需留出余量。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            HStack {
                Button(L10n.text("下载或查看图片模型")) { store.showImageDownload() }.buttonStyle(.bordered).accessibilityIdentifier("download-qwen-image-turbo")
                if !store.engine.installed { Button(L10n.text("安装图片引擎…")) { store.engineSection = .overview }.buttonStyle(.bordered) }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor struct ImageGenerationView: View {
    @ObservedObject var session: ImageGenerationSession
    var copy: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L10n.text("生成图片")).font(.system(size: TypeScale.section, weight: .semibold))
            TextEditor(text: $session.prompt).font(.system(size: TypeScale.body)).frame(height: 90).padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.line) }.accessibilityLabel(L10n.text("图片提示词")).disabled(session.busy)
            HStack(spacing: 14) {
                Picker(L10n.text("图片尺寸"), selection: $session.size) { ForEach(["1024x1024", "1344x768", "768x1344"], id: \.self) { Text($0).tag($0) } }.fixedSize().disabled(session.busy)
                TextField(L10n.text("种子"), text: $session.seed).textFieldStyle(.roundedBorder).frame(width: 110).disabled(session.busy)
                Spacer()
                if session.busy { Button(L10n.text(session.cancelling ? "正在取消…" : "取消生成")) { session.cancel() }.buttonStyle(.bordered).disabled(session.cancelling) }
                else { Button(L10n.text("生成图片")) { session.generate() }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(session.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.prompt.count > 4096 || UInt32(session.seed) == nil) }
            }
            if let value = session.progress {
                HStack { Text(verbatim: L10n.text(value.title)); Spacer(); if value.stage == "denoising" { Text(verbatim: "\(value.completed) / \(value.total) · \(value.completed * 100 / max(1, value.total))%") }; Text(verbatim: String(format: "%.1f s", value.elapsed)).foregroundStyle(Theme.muted) }.font(.system(size: TypeScale.callout)).monospacedDigit()
                if value.stage == "denoising" { ProgressView(value: Double(value.completed), total: Double(max(1, value.total))).tint(Theme.accent) }
                else if session.busy { ProgressView().controlSize(.small) }
            } else if session.busy { ProgressView().controlSize(.small) }
            if let error = session.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            if let image = session.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 520).accessibilityLabel(L10n.text("生成的图片")); Button(L10n.text("保存 PNG…")) { session.save() }.buttonStyle(.bordered) }
            Button(L10n.text("复制图片 API 示例")) {
                let payload: [String: Any] = ["model": ImageModelPolicy.repository, "prompt": "A quiet lakeside cabin at sunrise", "size": "1024x1024", "n": 1, "response_format": "b64_json"]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let body = String(data: data, encoding: .utf8) { copy("curl http://127.0.0.1:\(session.spec.port)/v1/images/generations -H 'Content-Type: application/json' --data " + ServiceCommand.quote(body)) }
            }.buttonStyle(PlainAction()).font(.system(size: TypeScale.callout))
        }.padding(18).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("image-generation")
    }
}
