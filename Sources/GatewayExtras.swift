import Foundation
import SwiftUI
import AppKit
import Darwin

/// 网关请求日志中的一条元数据（不含请求和回复内容）。
struct GatewayRequestEntry: Identifiable, Hashable {
    var id: String { "\(time)-\(model ?? "")-\(status)" }
    var time: Date
    var model: String?
    var path: String
    var status: Int
    var milliseconds: Int
    var client: String
    var promptTokens: Int?
    var completionTokens: Int?
    var failed: Bool { status >= 400 || status == 0 }
}

/// 按模型汇总的用量。
struct GatewayUsage: Identifiable, Hashable {
    var id: String { model }
    var model: String
    var requests = 0
    var failures = 0
    var promptTokens = 0
    var completionTokens = 0
    var totalMilliseconds = 0
    var averageMilliseconds: Int { requests == 0 ? 0 : totalMilliseconds / requests }
}

enum GatewayRequestLog {
    /// 读取日志末尾（最多 limit 条），新到旧排列。
    static func read(_ url: URL, limit: Int = 2000) -> [GatewayRequestEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 1_048_576
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if size > window, !lines.isEmpty { lines.removeFirst() }
        return lines.suffix(limit).reversed().compactMap { parse(String($0)) }
    }
    static func parse(_ line: String) -> GatewayRequestEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let time = (object["time"] as? NSNumber)?.doubleValue else { return nil }
        return .init(time: Date(timeIntervalSince1970: time), model: object["model"] as? String, path: object["path"] as? String ?? "", status: (object["status"] as? NSNumber)?.intValue ?? 0,
                     milliseconds: (object["ms"] as? NSNumber)?.intValue ?? 0, client: object["client"] as? String ?? "local",
                     promptTokens: (object["prompt_tokens"] as? NSNumber)?.intValue, completionTokens: (object["completion_tokens"] as? NSNumber)?.intValue)
    }
    static func usage(_ entries: [GatewayRequestEntry]) -> [GatewayUsage] {
        var table: [String: GatewayUsage] = [:]
        for entry in entries {
            let key = entry.model ?? "—"
            var value = table[key] ?? GatewayUsage(model: key)
            value.requests += 1; value.failures += entry.failed ? 1 : 0
            value.promptTokens += entry.promptTokens ?? 0; value.completionTokens += entry.completionTokens ?? 0
            value.totalMilliseconds += entry.milliseconds
            table[key] = value
        }
        return table.values.sorted { $0.requests > $1.requests }
    }
}

enum NetworkInterfaces {
    /// 本机局域网 IPv4 地址（排除回环与链路本地地址）。
    static func lanAddresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var result: [String] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254."), !result.contains(text) { result.append(text) }
        }
        return result
    }
}

@MainActor extension GatewayController {
    var requestLogURL: URL { root.appendingPathComponent("requests.jsonl") }
    var activityURL: URL { root.appendingPathComponent("activity.json") }
    var wakeDirectory: URL { root.appendingPathComponent("wake") }

    /// 切换局域网共享；网关运行中时自动重启以更换监听地址。
    func setLAN(_ enabled: Bool, store: AppStore) {
        if enabled {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = L10n.text("开启局域网共享？")
            alert.informativeText = L10n.text("同一网络中的设备可以通过本机地址访问网关里的模型，请求必须携带网关密钥。请只在可信网络中开启，并妥善保管密钥。macOS 可能会询问是否允许接入网络连接。")
            alert.addButton(withTitle: L10n.text("开启")); alert.addButton(withTitle: L10n.text("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        settings.lanEnabled = enabled ? true : nil
        do { try save() } catch { self.error = error.localizedDescription; return }
        guard ownsProcess() else { return }
        stop()
        Task {
            for _ in 0..<60 where busy || process != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            start(store: store)
        }
    }

    func clearRequestLog() {
        try? FileManager.default.removeItem(at: requestLogURL)
    }
}

@MainActor extension AppStore {
    /// 每 3 秒处理网关的唤醒请求，并检查开启了空闲停止的服务。
    func beginIdleMonitor() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.idleTick() } }
    }

    func idleTick() {
        handleWakeRequests()
        let now = Date().timeIntervalSince1970
        let activity = (try? Data(contentsOf: gateway.activityURL)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        for spec in services.records where spec.idleMinutes != nil && spec.pid != nil && services.status(spec) == .running && relaunchingServiceID != spec.id {
            // CPU 明显占用（例如直接访问端口在生成）视为活动，避免中途停止。
            if let cpu = resources.services.first(where: { $0.id == spec.id })?.cpu, cpu > 10 { idleBusy[spec.id] = now }
            let last = [activity[spec.id], spec.startedAt?.timeIntervalSince1970, idleBusy[spec.id]].compactMap { $0 }.max() ?? now
            guard let minutes = spec.idleMinutes, now - last > Double(minutes) * 60 else { continue }
            do {
                try services.stop(spec)
                services.updateBehavior(spec.id, sleeping: true)
                idleBusy[spec.id] = nil
            } catch { message = L10n.text("空闲自动停止失败：") + error.localizedDescription }
        }
    }

    /// 网关为休眠服务写入的唤醒请求：按已保存的配置启动对应服务。
    private func handleWakeRequests() {
        let directory = gateway.wakeDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path), !names.isEmpty else { return }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            guard let spec = services.records.first(where: { $0.id == name && $0.sleeping == true }), spec.pid == nil else { continue }
            do { try startSaved(spec) } catch { message = L10n.text("唤醒服务失败：") + "端口 \(spec.port) · \(spec.modelName)：\(error.localizedDescription)" }
        }
    }
}

/// 网关页的局域网共享设置。
@MainActor struct GatewayLANView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var gateway: GatewayController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.text("局域网共享"), isOn: Binding(get: { gateway.settings.lanEnabled == true }, set: { gateway.setLAN($0, store: store) }))
                .toggleStyle(.switch).font(.system(size: TypeScale.body, weight: .semibold)).disabled(gateway.busy).accessibilityIdentifier("gateway-lan")
            if gateway.settings.lanEnabled == true {
                let addresses = NetworkInterfaces.lanAddresses()
                if addresses.isEmpty { Text(verbatim: L10n.text("未检测到局域网地址，请确认已连接网络。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText) }
                ForEach(addresses, id: \.self) { address in
                    HStack(spacing: 8) {
                        Text(verbatim: "http://\(address):\(gateway.settings.port)/v1").font(.system(size: TypeScale.body, design: .monospaced)).textSelection(.enabled)
                        CopyIconButton(help: "复制局域网地址") { store.copy("http://\(address):\(gateway.settings.port)/v1") }
                    }
                }
                Text(verbatim: L10n.text("其他设备使用此地址和网关密钥访问。只在可信网络中开启。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.warningText)
            } else {
                Text(verbatim: L10n.text("默认只允许本机访问。开启后，同一网络中的设备可以凭网关密钥使用这些模型。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Theme.line.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 「资源与性能」中的网关请求日志与用量统计。
@MainActor final class GatewayLogModel: ObservableObject {
    @Published var entries: [GatewayRequestEntry] = []
    func reload(_ url: URL) {
        Task.detached(priority: .utility) {
            let value = GatewayRequestLog.read(url)
            await MainActor.run { self.entries = value }
        }
    }
}

@MainActor struct GatewayRequestsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var model = GatewayLogModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(verbatim: L10n.text("网关请求")).font(.system(size: TypeScale.section, weight: .semibold)); Spacer()
                Button(L10n.text("清空记录")) { store.gateway.clearRequestLog(); model.reload(store.gateway.requestLogURL) }.buttonStyle(PlainAction()).disabled(model.entries.isEmpty)
            }
            Text(verbatim: L10n.text("统一网关只记录时间、模型、接口、状态码、耗时和 token 数，不记录请求和回复内容。")).font(.system(size: TypeScale.callout)).foregroundStyle(Theme.muted)
            if model.entries.isEmpty {
                Text(verbatim: L10n.text("暂无网关请求。客户端经统一网关调用模型后会在这里显示。")).font(.system(size: TypeScale.body)).foregroundStyle(Theme.muted)
            } else {
                let usage = GatewayRequestLog.usage(model.entries)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        ForEach(["模型", "请求", "失败", "输入 tokens", "输出 tokens", "平均耗时"], id: \.self) { Text(verbatim: L10n.text($0)).font(.system(size: TypeScale.callout, weight: .semibold)).foregroundStyle(Theme.muted) }
                    }
                    ForEach(usage.prefix(8)) { row in
                        GridRow {
                            Text(verbatim: row.model).font(.system(size: TypeScale.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .leading)
                            Text(verbatim: row.requests.formatted()).monospacedDigit()
                            Text(verbatim: row.failures.formatted()).monospacedDigit().foregroundStyle(row.failures > 0 ? Theme.errorText : Theme.muted)
                            Text(verbatim: row.promptTokens.formatted()).monospacedDigit()
                            Text(verbatim: row.completionTokens.formatted()).monospacedDigit()
                            Text(verbatim: "\(row.averageMilliseconds.formatted()) ms").monospacedDigit()
                        }.font(.system(size: TypeScale.callout))
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.line.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                DisclosureGroup(L10n.text("最近请求")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.entries.prefix(30)) { entry in
                            HStack(spacing: 12) {
                                Text(verbatim: entry.time.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(Theme.muted)
                                Text(verbatim: "\(entry.status)").monospacedDigit().foregroundStyle(entry.failed ? Theme.errorText : Theme.successText)
                                Text(verbatim: entry.model ?? "—").font(.system(size: TypeScale.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if entry.client == "lan" { Text(verbatim: L10n.text("局域网")).foregroundStyle(Theme.warningText) }
                                Text(verbatim: [entry.promptTokens.map { "\($0) → " } ?? "", entry.completionTokens.map { "\($0) tokens" } ?? ""].joined()).monospacedDigit().foregroundStyle(Theme.muted)
                                Text(verbatim: "\(entry.milliseconds) ms").monospacedDigit().frame(width: 80, alignment: .trailing)
                            }.font(.system(size: TypeScale.callout))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.system(size: TypeScale.body))
            }
        }
        .task { while !Task.isCancelled { model.reload(store.gateway.requestLogURL); try? await Task.sleep(nanoseconds: 5_000_000_000) } }
    }
}
