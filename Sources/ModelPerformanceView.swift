import SwiftUI

@MainActor
struct ModelPerformanceSummary: View {
    @ObservedObject var store: AppStore
    @ObservedObject var performance: PerformanceController
    var model: LocalModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(verbatim: L10n.text("模型性能")).font(.system(size: 22, weight: .semibold)); Spacer(); Button(L10n.text("查看资源与实测")) { if let target = store.benchmarkTargets.first(where: { $0.modelID.map(model.matchesID) == true }) { performance.selection = target.id }; store.tab = .monitor }.buttonStyle(.bordered) }
            if let result = performance.records.first(where: { $0.target.modelID.map(model.matchesID) == true }) {
                BenchmarkCards(result: result, columns: 2)
                Text(verbatim: L10n.text("\(result.target.engineName) \(result.target.engineVersion) · \(result.requestedTokens) tokens · \(result.date.formatted(date: .abbreviated, time: .shortened))")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else { Text(verbatim: L10n.text("暂无实测数据。启动此模型的服务后，可测量生成速度、首个输出与服务内存。")).font(.system(size: 14)).foregroundStyle(Theme.muted) }
        }
    }
}
