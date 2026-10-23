import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

enum ImageGenerationMode: String, CaseIterable { case text = "文生图", image = "图生图" }

struct ImageReference {
    let name: String
    let data: Data
    let image: NSImage
    static func read(_ url: URL) throws -> Self {
        let limit = 16 * 1024 * 1024
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= limit else { throw LaunchError.message("参考图片不能超过 16 MB。") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_000_000,
              let image = NSImage(data: data) else { throw LaunchError.message("请选择单张 PNG、JPEG 或 WebP 图片，最多 1600 万像素，单边不超过 8192 像素。") }
        return .init(name: url.lastPathComponent, data: data, image: image)
    }
}

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
        case "encoding_image": return "理解参考图和提示词"
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
    @Published var mode: ImageGenerationMode = .text
    @Published var reference: ImageReference?
    @Published var strength = 0.75
    @Published var supportsImageToImage: Bool?
    @Published var busy = false
    @Published var cancelling = false
    @Published var progress: ImageGenerationProgress?
    @Published var image: NSImage?
    @Published var error: String?
    private(set) var data: Data?
    private var job: String?
    private var task: Task<Void, Never>?
    let spec: ServiceSpec
    let apiModel: String
    init(spec: ServiceSpec, apiModel: String = ImageModelPolicy.repository) { self.spec = spec; self.apiModel = apiModel }
    private var ownsService: Bool { spec.pid.map { $0 > 1 && spec.processStart == processStartTime($0) } ?? false }
    func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard ownsService else { throw LaunchError.message("图片服务已停止或重新启动，请重新打开服务。") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(spec.port)" + path)!)
        request.timeoutInterval = path.hasPrefix("/v1/images/") ? 1800 : 5
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    var canGenerate: Bool {
        !busy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.count <= 4096 && UInt32(seed) != nil && (mode == .text || (reference != nil && supportsImageToImage == true))
    }
    func checkFeatures() async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request("/health"))
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200, value?["service"] as? String == "modeldock-mflux" else { supportsImageToImage = false; return }
            supportsImageToImage = (value?["features"] as? [String] ?? []).contains("reference_editing")
        } catch { supportsImageToImage = false }
    }
    func chooseReference() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("选择参考图片…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { reference = try ImageReference.read(url); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func generate() {
        guard canGenerate, let seed = UInt32(seed) else { return }
        busy = true; cancelling = false; error = nil; progress = nil; image = nil; data = nil
        let job = UUID().uuidString; self.job = job
        var body: [String: Any] = ["model": apiModel, "prompt": prompt, "size": size, "seed": seed, "n": 1, "response_format": "b64_json", "job_id": job]
        let path = mode == .image ? "/v1/images/edits" : "/v1/images/generations"
        if mode == .image, let reference { body["image"] = reference.data.base64EncodedString(); body["strength"] = strength }
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
                let (bytes, response) = try await URLSession.shared.data(for: request(path, body: body))
                guard bytes.count < 32_000_000, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LaunchError.message("图片服务返回了无效数据。") }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LaunchError.message((object["error"] as? [String: Any])?["message"] as? String ?? "图片生成失败，请查看服务日志。") }
                guard let entry = (object["data"] as? [[String: Any]])?.first, let encoded = entry["b64_json"] as? String,
                      let data = Data(base64Encoded: encoded), data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), let image = NSImage(data: data) else { throw LaunchError.message("图片服务未返回有效的 PNG 图片。") }
                self.data = data; self.image = image
                let steps = object["steps"] as? Int ?? progress?.total ?? 8
                progress = .init(stage: "complete", completed: steps, total: steps, job_id: job, elapsed: progress?.elapsed ?? 0)
            } catch {
                if cancelling { progress = .init(stage: "cancelled", completed: 0, total: progress?.total ?? 8, job_id: job, elapsed: progress?.elapsed ?? 0) }
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
    func imageSession(_ spec: ServiceSpec, apiModel: String? = nil) -> ImageGenerationSession {
        let model = apiModel ?? (services.reportedModels[spec.port]?.count == 1 ? services.reportedModels[spec.port]?.first : nil) ?? ImageModelPolicy.repository
        let key = spec.id + ":" + String(spec.processStart ?? 0) + ":" + model
        if let value = imageSessions[key] { return value }
        let value = ImageGenerationSession(spec: spec, apiModel: model); imageSessions[key] = value; return value
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
    var showService: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L10n.text("生成图片")).font(.system(size: TypeScale.section, weight: .semibold))
            Picker(L10n.text("生成方式"), selection: $session.mode) {
                ForEach(ImageGenerationMode.allCases, id: \.self) { Text(verbatim: L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).fixedSize().disabled(session.busy).accessibilityIdentifier("image-generation-mode")
            if session.mode == .image { referenceControls }
            TextEditor(text: $session.prompt).font(.system(size: TypeScale.body)).frame(height: 90).padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.line) }.accessibilityLabel(L10n.text("图片提示词")).disabled(session.busy)
            HStack(spacing: 14) {
                Picker(L10n.text("图片尺寸"), selection: $session.size) { ForEach(["1024x1024", "1344x768", "768x1344"], id: \.self) { Text($0).tag($0) } }.fixedSize().disabled(session.busy)
                TextField(L10n.text("种子"), text: $session.seed).textFieldStyle(.roundedBorder).frame(width: 110).disabled(session.busy)
                Spacer()
                if session.busy { Button(L10n.text(session.cancelling ? "正在取消…" : "取消生成")) { session.cancel() }.buttonStyle(.bordered).disabled(session.cancelling) }
                else { Button(L10n.text("生成图片")) { session.generate() }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!session.canGenerate) }
            }
            if let value = session.progress {
                HStack { Text(verbatim: L10n.text(value.title)); Spacer(); if value.stage == "denoising" { Text(verbatim: "\(value.completed) / \(value.total) · \(value.completed * 100 / max(1, value.total))%") }; Text(verbatim: String(format: "%.1f s", value.elapsed)).foregroundStyle(Theme.muted) }.font(.system(size: TypeScale.callout)).monospacedDigit()
                if value.stage == "denoising" { ProgressView(value: Double(value.completed), total: Double(max(1, value.total))).tint(Theme.accent) }
                else if session.busy { ProgressView().controlSize(.small) }
            } else if session.busy { ProgressView().controlSize(.small) }
            if let error = session.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            if let image = session.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 520).accessibilityLabel(L10n.text("生成的图片")); Button(L10n.text("保存 PNG…")) { session.save() }.buttonStyle(.bordered) }
            Button(L10n.text("复制图片 API 示例")) {
                if session.mode == .image {
                    copy("""
                    : "${MODELDOCK_IMAGE_FILE:?Set MODELDOCK_IMAGE_FILE to a PNG, JPEG or WebP file}"
                    curl --fail-with-body http://127.0.0.1:\(session.spec.port)/v1/images/edits --form-string \(ServiceCommand.quote("model=" + session.apiModel)) --form "image=@${MODELDOCK_IMAGE_FILE}" --form-string 'prompt=A quiet lakeside cabin in winter' --form-string 'strength=0.75' --form-string 'size=1024x1024' --form-string 'response_format=b64_json'
                    """)
                    return
                }
                let payload: [String: Any] = ["model": session.apiModel, "prompt": "A quiet lakeside cabin at sunrise", "size": "1024x1024", "n": 1, "response_format": "b64_json"]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let body = String(data: data, encoding: .utf8) { copy("curl http://127.0.0.1:\(session.spec.port)/v1/images/generations -H 'Content-Type: application/json' --data " + ServiceCommand.quote(body)) }
            }.buttonStyle(PlainAction()).font(.system(size: TypeScale.callout))
        }.padding(18).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("image-generation")
            .task { await session.checkFeatures() }
    }
    @ViewBuilder private var referenceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.supportsImageToImage == false {
                Text(verbatim: L10n.text("运行中的图片服务需要重新启动，才能启用图生图。")).foregroundStyle(Theme.warningText)
                if let showService { Button(L10n.text("查看服务"), action: showService).buttonStyle(.bordered) }
            }
            HStack(alignment: .center, spacing: 14) {
                if let reference = session.reference {
                    Image(nsImage: reference.image).resizable().scaledToFit().frame(width: 110, height: 80).accessibilityLabel(L10n.text("参考图片"))
                    Text(reference.name).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button(L10n.text("更换图片…")) { session.chooseReference() }.buttonStyle(.bordered)
                    Button(L10n.text("移除图片")) { session.reference = nil }.buttonStyle(.bordered)
                } else {
                    Button { session.chooseReference() } label: { Label(L10n.text("选择参考图片…"), systemImage: "photo.badge.plus") }.buttonStyle(.bordered).accessibilityIdentifier("choose-image-reference")
                }
            }.disabled(session.busy)
            HStack {
                Text(verbatim: L10n.text("重绘强度"))
                Slider(value: $session.strength, in: 0.125...1, step: 0.125).frame(maxWidth: 260).disabled(session.busy).accessibilityLabel(L10n.text("重绘强度"))
                Text(verbatim: String(format: "%.1f%%", session.strength * 100)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            Text(verbatim: L10n.text("数值越高，改动越大。参考图按所选尺寸适配；原图不会修改。支持单图重绘，不含局部蒙版或多图编辑。")).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: TypeScale.callout))
    }
}
