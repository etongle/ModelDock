import Foundation
import AppKit

@MainActor enum SolutionProgressChecks {
    static func run() throws {
        func check(_ value: Bool, _ message: String) throws { try ConnectionChecks.require(value, message) }
        func job(_ id: String, bytes: Int64, received: Int64) -> ModelDownload {
            var value = ModelDownload(site: .huggingface, repository: id, revision: "fixture", root: "/private/tmp/solution-progress-fixture", folder: id,
                files: [.init(path: "model.safetensors", url: URL(string: "https://fixture.invalid/model")!, bytes: bytes)])
            value.id = id; value.state = .downloading; value.received = received
            return value
        }
        var record = SolutionDeployment(solutionID: "voice-translation", draft: .init())
        record.state = .downloading; record.progress = .init(phase: .models)
        record.components = [.init(role: .asr, engineID: "audio", repository: "asr", revision: "fixture", downloadID: "asr"),
                             .init(role: .tts, engineID: "audio", repository: "tts", revision: "fixture", downloadID: "tts"),
                             .init(role: .text, engineID: "mlx", modelPath: "/Models/local", repository: "local", revision: "fixture"),
                             .init(role: .chat, engineID: "audio", repository: "asr", revision: "fixture", downloadID: "asr")]
        var jobs = [job("asr", bytes: 200, received: 100), job("tts", bytes: 800, received: 200), job("unrelated", bytes: 9000, received: 9000)]
        func snapshot() -> SolutionProgressSnapshot { .make(record, jobs: jobs) }
        let downloading = snapshot()
        try check(downloading.received == 300 && downloading.total == 1000 && downloading.fraction == 0.3, "Solution progress double-counted shared jobs, included unrelated tasks, or averaged percentages instead of bytes")
        record.state = .paused
        try check(snapshot().fraction == 0.3, "Paused solution lost its received bytes")
        record.state = .downloading; jobs[1].files[0].bytes = 0
        try check(snapshot().fraction == nil, "Unknown model size produced a fabricated percentage")
        jobs[1].files[0].bytes = 800; jobs[0].received = 200; jobs[1].received = 800
        try check(snapshot().fraction == 1 && snapshot().filesDone == 0 && snapshot().phase == .models, "Receiving all bytes incorrectly implied successful verification/configuration")
        record.progress = .init(phase: .engines, engineID: "audio", engineStep: .init(completed: 1, total: 5, title: "安装 mlx-audio", sequence: 3))
        record.state = .installing
        try check(snapshot().phase == .engines && snapshot().fraction == 0.2, "Engine steps were confused with download bytes")
        let decoded = try JSONDecoder().decode(SolutionDeployment.self, from: JSONEncoder().encode(record))
        try check(decoded.progress?.engineStep?.completed == 1 && decoded.progress?.phase == .engines, "Installation progress did not survive persistence")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        legacy.removeValue(forKey: "progress")
        let migrated = try JSONDecoder().decode(SolutionDeployment.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(migrated.progress == nil && SolutionProgressSnapshot.make(migrated, jobs: []).fraction == nil, "Legacy solutions failed migration or acquired fabricated progress")
        try check(SolutionProgressSnapshot.latestOutput("\u{1b}[32mCollecting dependency\u{1b}[0m\r\nDownloading model wheel\r\n") == "Downloading model wheel", "Latest installation output kept ANSI control sequences or blank lines")
        record.state = .configured
        try check(snapshot().fraction == 1 && snapshot().phase == .configuration, "Completed installation did not finish the last stage")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("solution-progress-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(stateDirectory: root)
        record.state = .downloading; record.progress = .init(phase: .models)
        store.downloads.jobs = jobs; store.downloads.address = "keep-import-form"
        store.solutions.deployments = [record]; store.solutions.selectedID = record.solutionID; store.tab = .solutions
        store.solutions.showDownloads(record.id, store: store, automatically: true)
        try check(store.tab == .downloads && store.downloads.selectedTaskID == "asr" && store.downloads.address == "keep-import-form", "Solution did not open its download task or changed the import form")
        store.tab = .engines; store.downloads.selectedTaskID = "keep-selection"
        store.solutions.showDownloads(record.id, store: store, automatically: true)
        try check(store.tab == .engines && store.downloads.selectedTaskID == "keep-selection", "Background installation stole navigation focus")
        store.tab = .solutions; var changed = store.solutions.draft; changed.language = "French"; store.solutions.setDraft(changed)
        store.solutions.showDownloads(record.id, store: store, automatically: true)
        try check(store.tab == .solutions, "Old deployment stole focus after switching configuration")
        store.solutions.showDownloads(record.id, store: store)
        try check(store.tab == .downloads, "Explicit task navigation was blocked by a changed draft")
        print("Solution progress and download navigation checks passed")
    }

    static func capture(_ app: AppDelegate, folder: URL) async throws {
        let store = app.store!
        let controller = store.solutions
        var record = SolutionDeployment(solutionID: "voice-translation", draft: controller.draft)
        record.components = try controller.definition.roles.map { try controller.selection($0, draft: controller.draft, store: store) }
        var jobs: [ModelDownload] = []
        for index in record.components.indices where record.components[index].modelPath == nil {
            let component = record.components[index]
            let file = RemoteFile(path: "model-00001-of-00003.safetensors", url: URL(string: "https://fixture.invalid/model")!, bytes: component.role == .asr ? 1_600_000_000 : 4_800_000_000)
            var job = ModelDownload(site: .huggingface, repository: component.repository, revision: component.revision, root: "/private/tmp/ModelDock-Demo/Models", folder: component.role.gatewayModel, files: [file])
            job.state = .downloading; job.received = file.bytes / 3; job.currentFile = file.path
            jobs.append(job); record.components[index].downloadID = job.id
        }
        store.downloads.jobs = jobs
        store.downloads.speeds = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, 8_400_000.0) })
        store.downloads.activeIDs = Set(jobs.map(\.id))
        let downloadComponents = record.components
        for language in [AppLanguage.english, .chinese, .french, .portuguese] {
            store.language = language; controller.section = .configuration
            record.components = downloadComponents.map { var value = $0; value.downloadID = nil; return value }
            record.state = .installing; record.stage = "正在安装 MLX Audio"
            record.progress = .init(phase: .engines, total: 2, engineID: "audio", engineStep: .init(completed: 1, total: 5, title: "安装 mlx-audio", sequence: 3))
            record.log = "Collecting mlx-audio==0.5.9\nDownloading mlx_audio-0.5.9-py3-none-any.whl\n"
            controller.deployments = [record]
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-solution-installing", folder: folder)
            record.components = downloadComponents
            record.state = .downloading; record.stage = "正在下载并校验配套文件"; record.progress = .init(phase: .models)
            controller.deployments = [record]
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-solution-downloading", folder: folder)
            record.state = .paused; record.stage = "已暂停，可继续安装"; controller.deployments = [record]
            try await Task.sleep(nanoseconds: 350_000_000); try app.capture(language.rawValue + "-solution-paused", folder: folder)
        }
        store.downloads.activeIDs = []
    }
}
