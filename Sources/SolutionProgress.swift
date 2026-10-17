import Foundation
import SwiftUI

enum SolutionPreparationPhase: Int, Codable, CaseIterable {
    case checking, engines, models, configuration
    var title: String { ["检查方案", "安装引擎", "下载模型", "配置服务"][rawValue] }
}

struct SolutionPreparationProgress: Codable {
    var phase: SolutionPreparationPhase
    var completed = 0
    var total = 0
    var detail = ""
    var engineID: String?
    var engineStep: EngineInstallProgress?
}

/// Byte percentages describe downloads; command percentages describe completed installation steps.
/// Neither is presented as an estimate of the entire installation's elapsed time.
struct SolutionProgressSnapshot {
    var phase: SolutionPreparationPhase
    var fraction: Double?
    var metric: String
    var received: Int64 = 0
    var total: Int64 = 0
    var filesDone = 0
    var filesTotal = 0
    var downloadIDs: [String] = []
    var percentage: String { fraction.map { String(format: "%.1f%%", min(1, max(0, $0)) * 100) } ?? "—" }
    static func make(_ record: SolutionDeployment, jobs: [ModelDownload]) -> Self {
        let phase = record.progress?.phase ?? (record.state == .installing ? .engines : record.state == .downloading ? .models : record.state == .configured ? .configuration : .checking)
        if record.state == .configured { return .init(phase: .configuration, fraction: 1, metric: L10n.text("安装完成，服务尚未启动")) }
        if phase != .models {
            let value = record.progress
            let done = value?.engineStep?.completed ?? value?.completed ?? 0
            let total = value?.engineStep?.total ?? value?.total ?? 0
            let fraction = total > 0 ? min(1, Double(done) / Double(total)) : nil
            let key = phase == .engines && value?.engineStep != nil ? "已完成安装步骤 {0} / {1}" : "已完成 {0} / {1}"
            return .init(phase: phase, fraction: fraction, metric: total > 0 ? L10n.format(key, [String(done), String(total)]) : L10n.text("正在准备…"))
        }
        let identifiers = Set(record.components.compactMap(\.downloadID))
        let tasks = jobs.filter { identifiers.contains($0.id) }
        let missing = record.components.contains { component in component.modelPath == nil && (component.downloadID == nil || !tasks.contains { $0.id == component.downloadID }) }
        var result = Self(phase: .models, fraction: nil, metric: "", downloadIDs: tasks.map(\.id))
        func add(_ left: Int64, _ right: Int64) -> Int64 { left > Int64.max - max(0, right) ? Int64.max : left + max(0, right) }
        for job in tasks {
            result.total = add(result.total, job.total)
            result.received = add(result.received, job.total > 0 ? min(job.total, max(0, job.received)) : max(0, job.received))
            result.filesTotal += job.files.count
            result.filesDone += job.files.filter { job.finished.contains($0.path) }.count
        }
        let known = !missing && !tasks.isEmpty && tasks.allSatisfy { $0.totalKnown && $0.total > 0 }
        if known { result.fraction = min(1, Double(result.received) / Double(max(1, result.total))) }
        result.metric = L10n.format("文件已完成 {0} / {1}", [String(result.filesDone), String(result.filesTotal)])
        return result
    }
    static func latestOutput(_ log: String) -> String? {
        let cleaned = log.replacingOccurrences(of: #"\x1b\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        return cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { !$0.isEmpty }).map { String($0.suffix(260)) }
    }
}

@MainActor extension AppStore {
    func solutionProgress(_ record: SolutionDeployment) -> SolutionProgressSnapshot {
        SolutionProgressSnapshot.make(record, jobs: downloads.jobs)
    }
}

@MainActor struct SolutionInstallationCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var controller: SolutionController
    var record: SolutionDeployment
    private var snapshot: SolutionProgressSnapshot { store.solutionProgress(record) }
    private var busy: Bool { [.preparing, .installing, .downloading].contains(record.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: L10n.text("安装进度")).font(.system(size: TypeScale.body, weight: .semibold))
                    Text(verbatim: L10n.text(record.stage)).font(.system(size: TypeScale.callout)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(verbatim: L10n.format("阶段 {0} / {1}", [String(snapshot.phase.rawValue + 1), "4"]))
                    .font(.system(size: TypeScale.callout, weight: .medium)).foregroundStyle(Theme.linkColor).fixedSize()
                if record.state == .preparing || record.state == .downloading { Button(L10n.text("暂停")) { controller.pause(record.id, store: store) }.buttonStyle(.bordered) }
            }
            HStack(spacing: 10) {
                ForEach(SolutionPreparationPhase.allCases, id: \.rawValue) { phase in
                    HStack(spacing: 5) {
                        Image(systemName: phase.rawValue < snapshot.phase.rawValue || record.state == .configured ? "checkmark.circle.fill" : "\(phase.rawValue + 1).circle")
                        Text(verbatim: L10n.text(phase.title)).lineLimit(2)
                    }.font(.system(size: TypeScale.caption, weight: phase == snapshot.phase ? .semibold : .regular))
                        .foregroundStyle(phase.rawValue <= snapshot.phase.rawValue ? Theme.linkColor : Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let fraction = snapshot.fraction { ProgressView(value: fraction).tint(Theme.accent).accessibilityValue(snapshot.percentage) }
            else if busy { ProgressView().progressViewStyle(.linear).tint(Theme.accent) }
            HStack {
                Text(verbatim: snapshot.metric).foregroundStyle(Theme.muted).help(L10n.text("百分比按已完成的安装步骤计算，不代表下载字节或剩余时间。"))
                Spacer()
                if snapshot.fraction != nil { Text(verbatim: snapshot.percentage).monospacedDigit().foregroundStyle(Theme.linkColor) }
            }.font(.system(size: TypeScale.callout))
            if snapshot.phase == .models, !snapshot.downloadIDs.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { downloadMetrics }
                    VStack(alignment: .leading, spacing: 6) { downloadMetrics }
                }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            } else if let step = record.progress?.engineStep {
                HStack(spacing: 8) {
                    if busy && step.completed < step.total { ProgressView().controlSize(.mini) }
                    Text(verbatim: L10n.text(step.title)).font(.system(size: TypeScale.callout))
                }
            } else if let detail = record.progress?.detail, !detail.isEmpty {
                Text(verbatim: L10n.text(detail)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            if let error = record.error { Text(verbatim: L10n.text(error)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
            if !record.log.isEmpty {
                if record.state == .installing, let output = SolutionProgressSnapshot.latestOutput(record.log) {
                    Text(verbatim: output).font(.system(size: TypeScale.caption, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(2).textSelection(.enabled)
                }
                DisclosureGroup(L10n.text("安装日志")) { Text(verbatim: record.log).font(.system(size: TypeScale.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .font(.system(size: TypeScale.callout))
            }
        }.padding(16).background(Theme.selection.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("solution-installation-progress")
    }
    @ViewBuilder private var downloadMetrics: some View {
        Text(verbatim: sizeLabel(snapshot.received) + " / " + (snapshot.fraction == nil ? L10n.text("大小待确认") : sizeLabel(snapshot.total)))
        Text(verbatim: L10n.text("在下载页面管理进度和文件"))
        Button(L10n.text("查看下载")) { controller.showDownloads(record.id, store: store) }.buttonStyle(PlainAction())
    }
}
