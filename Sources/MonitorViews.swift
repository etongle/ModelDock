import SwiftUI
import AppKit

func diskLabel(_ bytes: Int64) -> String { bytes >= 1_000_000_000_000 ? String(format: "%.2f TB", locale: L10n.locale, Double(bytes) / 1e12) : sizeLabel(bytes) }
func secondsLabel(_ value: Double?) -> String { value.map { $0 < 1 ? String(format: "%.0f ms", locale: L10n.locale, $0 * 1000) : String(format: "%.2f s", locale: L10n.locale, $0) } ?? "—" }
func rateLabel(_ value: Double?) -> String { value.map { String(format: "%.1f tok/s", locale: L10n.locale, $0) } ?? "—" }
extension BenchmarkResult {
    var speedTitle: String { generationRate == nil ? "端到端吞吐" : "生成速度" }
    var measuredRate: Double? { generationRate ?? endToEndRate }
}

struct ResourceCard: View {
    var title: String; var symbol: String; var value: String; var detail: String; var fraction: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text(title), systemImage: symbol).font(.system(size: TypeScale.body, weight: .semibold)).foregroundStyle(Theme.muted)
            Text(verbatim: L10n.text(value)).font(.system(size: TypeScale.section, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            ProgressView(value: min(1, max(0, fraction ?? 0))).tint(Theme.accent).accessibilityLabel(L10n.text(title + "占用"))
            Text(verbatim: L10n.text(detail)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(2).frame(minHeight: 30, alignment: .top)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 13)).overlay { RoundedRectangle(cornerRadius: 13).stroke(Theme.line) }.accessibilityElement(children: .combine)
    }
}
@MainActor
struct ResourceOverview: View {
    @ObservedObject var monitor: ResourceMonitor
    var body: some View {
        HStack(spacing: 16) {
            ResourceCard(title: L10n.text("系统 CPU"), symbol: "cpu", value: percentageLabel(monitor.system?.cpu), detail: "整机 CPU 利用率 · 每 3 秒更新", fraction: monitor.system?.cpu.map { $0 / 100 })
            ResourceCard(title: L10n.text("系统内存"), symbol: "memorychip", value: monitor.system.map { memoryLabel($0.memoryUsed) + " / " + memoryLabel($0.memoryTotal) } ?? "读取中…", detail: monitor.system.map { "压缩内存 " + memoryLabel($0.compressed) } ?? "等待系统采样", fraction: monitor.system.map { Double($0.memoryUsed) / Double(max(1, $0.memoryTotal)) })
            ResourceCard(title: L10n.text("模型所在磁盘"), symbol: "internaldrive", value: monitor.system.map { diskLabel($0.diskUsed) + " / " + diskLabel($0.diskTotal) } ?? "读取中…", detail: monitor.system.map { "模型库 " + ($0.modelBytes.map(sizeLabel) ?? "统计中") + " · 可用 " + diskLabel($0.diskAvailable) } ?? "等待磁盘采样", fraction: monitor.system.flatMap { $0.diskTotal > 0 ? Double($0.diskUsed) / Double($0.diskTotal) : nil })
        }
    }
}
struct ResourceTrend: View {
    var points: [ResourcePoint]
    func path(_ size: CGSize, value: (ResourcePoint) -> Double?) -> Path {
        var path = Path(); var started = false
        for (index, point) in points.enumerated() {
            guard let value = value(point) else { started = false; continue }
            let position = CGPoint(x: CGFloat(index) / CGFloat(max(1, points.count - 1)) * size.width, y: size.height * (1 - CGFloat(min(100, max(0, value))) / 100))
            if started { path.addLine(to: position) } else { path.move(to: position); started = true }
        }
        return path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(verbatim: L10n.text("实时趋势")).font(.system(size: TypeScale.body, weight: .semibold)); Spacer(); Label(L10n.text("CPU"), systemImage: "circle.fill").foregroundStyle(Theme.linkColor); Label(L10n.text("内存"), systemImage: "circle.fill").foregroundStyle(.teal) }.font(.system(size: TypeScale.caption))
            GeometryReader { geometry in
                ZStack {
                    ForEach([0.0, 0.5, 1.0], id: \.self) { value in Path { path in path.move(to: CGPoint(x: 0, y: geometry.size.height * value)); path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * value)) }.stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                    path(geometry.size, value: { $0.cpu }).stroke(Theme.linkColor, lineWidth: 2)
                    path(geometry.size, value: { $0.memory }).stroke(.teal, lineWidth: 2)
                }
            }.frame(height: 72).accessibilityLabel(L10n.text("CPU 与内存占用趋势"))
            HStack { Text(verbatim: L10n.text("0–100% · 最多保留最近 3 分钟")); Spacer(); Text(verbatim: L10n.text(points.last?.date.formatted(date: .omitted, time: .standard) ?? "采样中")) }.font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
        }.padding(18).background(Theme.line.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
}
@MainActor
struct ServiceResourceRows: View {
    @ObservedObject var monitor: ResourceMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: L10n.text("模型服务资源")).font(.system(size: TypeScale.section, weight: .semibold))
            if monitor.services.isEmpty { Text(verbatim: L10n.text("服务启动后，显示引擎及其子进程的内存和 CPU 占用。")).foregroundStyle(Theme.muted).font(.system(size: TypeScale.body)) }
            ForEach(monitor.services) { service in
                HStack(spacing: 18) {
                    Image(systemName: "server.rack").foregroundStyle(Theme.linkColor).frame(width: 30)
                    VStack(alignment: .leading, spacing: 6) { Text(verbatim: L10n.text(service.name)).fontWeight(.semibold); Text(verbatim: "\(service.model) · \(service.port)").font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted).lineLimit(1).help(L10n.text(service.model)) }.frame(maxWidth: .infinity, alignment: .leading)
                    value("内存", service.memory.map(memoryLabel) ?? "—")
                    value("CPU", percentageLabel(service.cpu))
                    value("进程", service.processCount > 0 ? String(service.processCount) : "—")
                }.padding(16).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).accessibilityElement(children: .combine)
            }
            Text(verbatim: L10n.text("服务内存统计包括可读取的子进程；服务 CPU 以单核 100% 计算，多核负载可超过 100%。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
        }
    }
    func value(_ title: String, _ text: String) -> some View { VStack(alignment: .trailing, spacing: 7) { Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted); Text(verbatim: L10n.text(text)).font(.system(size: TypeScale.body, weight: .medium)).monospacedDigit() }.frame(width: 90, alignment: .trailing) }
}
struct BenchmarkCards: View {
    var result: BenchmarkResult
    var columns = 4
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            metric(result.speedTitle, rateLabel(result.measuredRate))
            metric("首个输出", secondsLabel(result.firstOutput))
            metric("总耗时", secondsLabel(result.elapsed))
            metric("采样峰值内存", result.peakMemory.map(memoryLabel) ?? "—")
        }
    }
    func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 12) { Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); Text(verbatim: L10n.text(value)).font(.system(size: TypeScale.section, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.selection.opacity(0.7), in: RoundedRectangle(cornerRadius: 11)) }
}

@MainActor
struct MonitorWorkspace: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    @ObservedObject var monitor: ResourceMonitor
    @ObservedObject var performance: PerformanceController
    var current: BenchmarkTarget? { store.benchmarkTargets.first { $0.id == performance.selection } ?? store.benchmarkTargets.first }
    var latest: BenchmarkResult? {
        guard let current else { return performance.records.first }
        return performance.records.first { $0.target.id == current.id || (current.modelID != nil && $0.target.modelID == current.modelID && $0.target.engineID == current.engineID) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 9) { Text(verbatim: L10n.text("资源与性能")).font(.system(size: TypeScale.title, weight: .bold)); Text(verbatim: L10n.text("整机资源、模型服务与本机推理实测")).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, alignment: .leading)
                ResourceOverview(monitor: monitor)
                ResourceTrend(points: monitor.history)
                ServiceResourceRows(monitor: monitor)
                Divider()
                Text(verbatim: L10n.text("模型推理性能")).font(.system(size: TypeScale.section, weight: .semibold))
                if store.benchmarkTargets.isEmpty {
                    EmptyMessage(symbol: "speedometer", title: L10n.text("启动主模型服务后即可实测"), detail: "选择正在运行的语言模型，测量生成速度、首个输出延迟和服务内存。")
                    Button(L10n.text("查看模型服务")) { store.tab = .services }.buttonStyle(.bordered)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker(L10n.text("模型服务"), selection: Binding(get: { current?.id ?? "" }, set: { performance.selection = $0 })) { ForEach(store.benchmarkTargets) { target in Text(verbatim: "\(target.engineName) · \(target.apiModel) · \(target.port)").tag(target.id) } }.disabled(performance.running)
                        HStack(spacing: 20) { Picker(L10n.text("输出上限"), selection: $performance.outputLimit) { ForEach([64, 128, 256], id: \.self) { Text(verbatim: L10n.text("\($0) tokens")).tag($0) } }.frame(width: 220).disabled(performance.running); Spacer(); if performance.running { ProgressView().controlSize(.small); Button(L10n.text("取消测量")) { performance.cancel() }.buttonStyle(.bordered) } else { Button { if let current { performance.measure(current, chip: store.inventory?.chip ?? "本机 Mac") } } label: { Label(L10n.text("一键实测"), systemImage: "speedometer") }.buttonStyle(AccentButton()).disabled(store.maintaining) } }
                        SecureField(L10n.text("本地服务访问密钥（可选，仅本次打开有效）"), text: $performance.apiKey).textFieldStyle(.roundedBorder).disabled(performance.running)
                        Text(verbatim: L10n.text("使用固定短提示进行一次推理。首个输出包含思考和排队等待；对比时请使用相同输出长度，留意缓存与其他服务负载。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
                        if !performance.phase.isEmpty { Text(verbatim: L10n.text(performance.phase)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.linkColor) }
                        if let message = performance.message { Text(verbatim: L10n.text(message)).font(.system(size: TypeScale.body)).foregroundStyle(Theme.errorText).textSelection(.enabled) }
                    }.padding(22).background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                }
                if let latest {
                    Text(verbatim: L10n.text("最近实测：\(latest.target.modelName) · \(latest.target.engineName) \(latest.target.engineVersion) · \(latest.date.formatted(date: .abbreviated, time: .shortened))")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    BenchmarkCards(result: latest)
                    HStack(spacing: 20) { Text(verbatim: L10n.text("输入 \(latest.promptTokens.map(String.init) ?? "—") / 输出 \(latest.outputTokens.map(String.init) ?? "—") tokens")); Text(verbatim: L10n.text("输入速度 " + rateLabel(latest.promptRate))); Text(verbatim: L10n.text("端到端吞吐 " + rateLabel(latest.endToEndRate))) }.font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    Text(verbatim: L10n.text(latest.rateSource)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
                    Text(verbatim: L10n.text("\(latest.chip) · 输出上限 \(latest.requestedTokens) tokens · 缓存输入 \(latest.cachedTokens.map(String.init) ?? "—") tokens")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                } else { Text(verbatim: L10n.text("暂无实测数据。测量后会在这里显示结果，并保存历史。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted) }
                if !performance.records.isEmpty {
                    Text(verbatim: L10n.text("实测历史")).font(.system(size: TypeScale.section, weight: .semibold))
                    ForEach(Array(performance.records.prefix(12))) { result in
                        HStack(spacing: 20) { VStack(alignment: .leading, spacing: 7) { Text(result.target.modelName).font(.system(size: TypeScale.body, weight: .semibold)).lineLimit(1); Text(verbatim: L10n.text("\(result.target.engineName) \(result.target.engineVersion) · \(result.requestedTokens) tokens · \(result.date.formatted(date: .abbreviated, time: .shortened))")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, alignment: .leading); VStack(alignment: .trailing, spacing: 5) { Text(verbatim: L10n.text(rateLabel(result.measuredRate))).font(.system(size: TypeScale.body, weight: .medium)).monospacedDigit(); Text(verbatim: L10n.text(result.speedTitle)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted) }; Text(verbatim: L10n.text(secondsLabel(result.firstOutput))).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted).frame(width: 90, alignment: .trailing) }.padding(16).background(Theme.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 10)).help(L10n.text(result.chip))
                    }
                }
            }.padding(30)
        }
    }
}

@MainActor
struct StatusBarPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var services: ServiceController
    @ObservedObject var monitor: ResourceMonitor
    @ObservedObject var performance: PerformanceController
    // Menu-bar utility layout: header, compact meters, live activity, then native-style menu rows.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: L10n.text("模型管理")).font(.system(size: TypeScale.body, weight: .semibold))
                    Text(verbatim: L10n.text("\(services.records.filter { $0.pid != nil }.count) 个受管服务 · \(services.external.filter(\.ready).count) 个外部接口")).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                meter("CPU", value: percentageLabel(monitor.system?.cpu), fraction: monitor.system?.cpu.map { $0 / 100 }, symbol: "cpu")
                meter("内存", value: monitor.system.map { memoryLabel($0.memoryUsed) + " / " + memoryLabel($0.memoryTotal) } ?? "读取中", fraction: monitor.system.map { Double($0.memoryUsed) / Double(max(1, $0.memoryTotal)) }, symbol: "memorychip")
                VStack(alignment: .leading, spacing: 5) {
                    meter("磁盘", value: monitor.system.map { diskLabel($0.diskUsed) + " / " + diskLabel($0.diskTotal) } ?? "读取中", fraction: monitor.system.flatMap { $0.diskTotal > 0 ? Double($0.diskUsed) / Double($0.diskTotal) : nil }, symbol: "internaldrive")
                    Text(verbatim: L10n.text("模型库：" + (monitor.system?.modelBytes.map(sizeLabel) ?? "统计中"))).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted)
                }
            }.padding(16)
            if !monitor.services.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("模型服务")
                    ForEach(Array(monitor.services.prefix(3))) { service in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) { Text(verbatim: L10n.text(service.name)).font(.system(size: TypeScale.body, weight: .medium)); Text(verbatim: L10n.text(service.model)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).lineLimit(1) }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) { Text(verbatim: L10n.text(service.memory.map(memoryLabel) ?? "—")).font(.system(size: TypeScale.callout)).monospacedDigit(); Text(verbatim: L10n.text("CPU " + percentageLabel(service.cpu))).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).monospacedDigit() }
                        }
                    }
                }.padding(16)
            }
            if let latest = performance.records.first {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) { Text(verbatim: L10n.text("最近实测 · " + latest.speedTitle)).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted); Text(latest.target.modelName).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.muted).lineLimit(1) }
                    Spacer()
                    Text(verbatim: L10n.text(rateLabel(latest.measuredRate))).font(.system(size: TypeScale.body, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.linkColor)
                }.padding(16)
            }
            StatusDownloads(store: store, downloads: store.downloads)
            if performance.running || store.installation.running {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if performance.running { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text(performance.phase)).font(.system(size: TypeScale.caption)).foregroundStyle(Theme.linkColor).lineLimit(2); Spacer(); Button(L10n.text("取消")) { performance.cancel() }.controlSize(.small) } }
                    if store.installation.running { HStack { ProgressView().controlSize(.small); Text(verbatim: L10n.text("引擎安装或更新进行中")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.linkColor) } }
                }.padding(16)
            }
            Divider()
            VStack(spacing: 0) {
                MenuRow(title: "打开管理界面", symbol: "macwindow") { store.showMainWindow?() }
                MenuRow(title: "资源与性能", symbol: "gauge.with.dots.needle.33percent") { store.tab = .monitor; store.showMainWindow?() }
            }.padding(5)
            Divider()
            VStack(spacing: 0) {
                MenuRow(title: "设置…", symbol: "gearshape", shortcut: "⌘,") { store.showSettings?() }
                MenuRow(title: "退出模型管理", symbol: "power", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
            }.padding(5)
        }.frame(width: 340).background(Theme.background)
    }
    func sectionTitle(_ title: String) -> some View { Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(Theme.muted) }
    func meter(_ title: String, value: String, fraction: Double?, symbol: String) -> some View {
        VStack(spacing: 6) {
            HStack { Label(L10n.text(title), systemImage: symbol).font(.system(size: TypeScale.body)); Spacer(); Text(verbatim: L10n.text(value)).font(.system(size: TypeScale.callout)).monospacedDigit().foregroundStyle(Theme.muted) }
            UsageBar(fraction: fraction)
        }.accessibilityElement(children: .combine)
    }
}

/// Thin usage meter drawn with explicit colors, so it keeps its tint when the popover is not key.
struct UsageBar: View {
    var fraction: Double?
    var body: some View {
        let value = min(1, max(0, fraction ?? 0))
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(value >= 0.9 ? Color.red : value >= 0.75 ? Color.orange : Theme.accent).frame(width: geometry.size.width * value)
            }
        }.frame(height: 5)
    }
}

/// Hover flag for rows; the swiftc build has no SwiftUI macro plugin, so @State is unavailable.
final class HoverState: ObservableObject { @Published var active = false }

/// Native-menu-style row: full-width, highlighted on hover.
struct MenuRow: View {
    var title: String
    var symbol: String
    var shortcut: String?
    var action: () -> Void
    @StateObject private var hover = HoverState()
    private var hovering: Bool { hover.active }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
                Text(verbatim: L10n.text(title)).font(.system(size: TypeScale.body))
                Spacer()
                if let shortcut { Text(verbatim: shortcut).font(.system(size: TypeScale.body)).foregroundStyle(hovering ? Color.white.opacity(0.85) : Theme.muted) }
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(hovering ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover.active = $0 }
    }
}
