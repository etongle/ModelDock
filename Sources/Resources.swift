import Foundation
import Combine
import Darwin

private func systemMetrics(_ values: UnsafeMutablePointer<UInt64>) -> Int32 { mm_system_metrics(values) }
private func groupMetrics(_ pid: Int32, _ expected: UInt64, _ values: UnsafeMutablePointer<UInt64>, _ capacity: Int32) -> Int32 { mm_group_metrics(pid, expected, values, capacity) }

func memoryLabel(_ bytes: UInt64) -> String { String(format: "%.1f GB", locale: L10n.locale, Double(bytes) / 1_073_741_824) }
func percentageLabel(_ percent: Double?) -> String { percent.map { String(format: "%.1f%%", locale: L10n.locale, $0) } ?? "—" }

struct ProcessCounters: Codable { var pid: Int32; var birth: UInt64; var cpuNanoseconds: UInt64; var memory: UInt64 }
struct ProcessSample { var processes: [ProcessCounters]; var at: UInt64; var bytes: UInt64 { processes.reduce(0) { $0 + $1.memory } } }
struct ServiceResource: Identifiable {
    var id: String; var name: String; var model: String; var port: Int; var pid: Int32?
    var memory: UInt64?; var cpu: Double?; var processCount: Int
}
struct SystemResource: Codable {
    var cpu: Double?; var memoryUsed: UInt64; var memoryTotal: UInt64; var compressed: UInt64; var fileCache: UInt64
    var diskTotal: Int64; var diskAvailable: Int64; var diskPath: String
    var modelBytes: Int64?; var sampledAt: Date
    var diskUsed: Int64 { max(0, diskTotal - diskAvailable) }
}
struct ResourcePoint: Identifiable { var id = UUID(); var date: Date; var cpu: Double?; var memory: Double }
struct ResourceTarget: Sendable { var id: String; var name: String; var model: String; var port: Int; var pid: Int32?; var birth: UInt64? }
struct RawResources { var ticks: [UInt64]?; var system: SystemResource?; var services: [(ResourceTarget, ProcessSample?)] }

enum ResourceSampler {
    static func process(_ pid: Int32, birth: UInt64? = nil) -> ProcessSample? {
        var values = [UInt64](repeating: 0, count: 256 * 4)
        let count = groupMetrics(pid, birth ?? 0, &values, 256)
        guard count > 0 else { return nil }
        let counters = (0..<Int(count)).map { index in ProcessCounters(pid: Int32(values[index * 4]), birth: values[index * 4 + 1], cpuNanoseconds: values[index * 4 + 2], memory: values[index * 4 + 3]) }
        return .init(processes: counters, at: DispatchTime.now().uptimeNanoseconds)
    }
    static func cpu(previous: ProcessSample?, current: ProcessSample) -> Double? {
        guard let previous, current.at > previous.at, current.at - previous.at < 30_000_000_000 else { return nil }
        let old = Dictionary(uniqueKeysWithValues: previous.processes.map { ($0.pid, $0) })
        var delta: UInt64 = 0; var matched = false
        for process in current.processes {
            if let prior = old[process.pid], prior.birth == process.birth, process.cpuNanoseconds >= prior.cpuNanoseconds { delta += process.cpuNanoseconds - prior.cpuNanoseconds; matched = true }
        }
        return matched ? Double(delta) / Double(current.at - previous.at) * 100 : nil
    }
    static func cpuTicks(previous: [UInt64]?, current: [UInt64]) -> Double? {
        guard let previous, previous.count == 4, current.count == 4 else { return nil }
        let deltas = zip(previous, current).map { prior, now in now >= prior ? now - prior : now + (1 << 32) - prior }
        let total = deltas.reduce(0, +)
        // Darwin CPU_STATE_IDLE is 2; user/system/nice are the other states.
        return total > 0 ? Double(total - deltas[2]) / Double(total) * 100 : nil
    }
    static func modelDisk(_ roots: [String]) -> Int64 {
        var seen = Set<FileIdentityKey>(); var bytes: Int64 = 0
        for root in roots {
            guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            while let file = files.nextObject() as? URL {
                var value = stat(); guard lstat(file.path, &value) == 0 else { continue }
                if value.st_mode & S_IFMT == S_IFLNK { files.skipDescendants(); continue }
                if value.st_mode & S_IFMT == S_IFREG, seen.insert(.init(device: value.st_dev, inode: value.st_ino)).inserted { bytes += Int64(value.st_blocks) * 512 }
            }
        }
        return bytes
    }
    private struct FileIdentityKey: Hashable { var device: Int32; var inode: UInt64 }
    static func collect(targets: [ResourceTarget], roots: [String], countModels: Bool) -> RawResources {
        var values = [UInt64](repeating: 0, count: 8)
        let valid = systemMetrics(&values) == 1
        let preferred = roots.first ?? Scanner.defaultRoot.path
        var volume = URL(fileURLWithPath: preferred)
        while !FileManager.default.fileExists(atPath: volume.path) && volume.path != "/" { volume.deleteLastPathComponent() }
        let filesystem = try? FileManager.default.attributesOfFileSystem(forPath: volume.path)
        let system: SystemResource? = valid ? .init(cpu: nil, memoryUsed: values[4], memoryTotal: values[5], compressed: values[6], fileCache: values[7], diskTotal: (filesystem?[.systemSize] as? NSNumber)?.int64Value ?? 0, diskAvailable: (filesystem?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0, diskPath: volume.path, modelBytes: countModels ? modelDisk(roots) : nil, sampledAt: Date()) : nil
        let services = targets.map { target -> (ResourceTarget, ProcessSample?) in
            var target = target
            if target.pid == nil {
                let value = runText("/usr/sbin/lsof", ["-nP", "-iTCP:\(target.port)", "-sTCP:LISTEN", "-t"]).components(separatedBy: "\n").compactMap(Int32.init).first
                target.pid = value; target.birth = value.map(processStartTime)
            }
            return (target, target.pid.flatMap { process($0, birth: target.birth) })
        }
        return .init(ticks: valid ? Array(values.prefix(4)) : nil, system: system, services: services)
    }
}

@MainActor
final class ResourceMonitor: ObservableObject {
    @Published var system: SystemResource?
    @Published var services: [ServiceResource] = []
    @Published var history: [ResourcePoint] = []
    @Published var sampling = false
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var previousTicks: [UInt64]?
    private var previous: [String: ProcessSample] = [:]
    private var lastDisk = Date.distantPast
    private var lastRoots: [String] = []
    func begin(targets: @escaping () -> [ResourceTarget], roots: @escaping () -> [String]) {
        Task { await refresh(targets: targets(), roots: roots()) }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh(targets: targets(), roots: roots()) } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func refresh(targets: [ResourceTarget], roots: [String], forceDisk: Bool = false) async {
        guard !sampling else { return }; sampling = true; defer { sampling = false }
        let countModels = forceDisk || roots != lastRoots || Date().timeIntervalSince(lastDisk) > 30
        let result = await Task.detached(priority: .utility) { ResourceSampler.collect(targets: targets, roots: roots, countModels: countModels) }.value
        if var current = result.system {
            if let ticks = result.ticks { current.cpu = ResourceSampler.cpuTicks(previous: previousTicks, current: ticks); previousTicks = ticks }
            if !countModels { current.modelBytes = system?.modelBytes }
            system = current
            history.append(.init(date: current.sampledAt, cpu: current.cpu, memory: Double(current.memoryUsed) / Double(max(1, current.memoryTotal)) * 100))
            if history.count > 60 { history.removeFirst(history.count - 60) }
        }
        var next: [String: ProcessSample] = [:]
        services = result.services.map { target, sample in
            let cpu = sample.flatMap { ResourceSampler.cpu(previous: previous[target.id], current: $0) }
            if let sample { next[target.id] = sample }
            return .init(id: target.id, name: target.name, model: target.model, port: target.port, pid: target.pid, memory: sample?.bytes, cpu: cpu, processCount: sample?.processes.count ?? 0)
        }
        previous = next
        if countModels { lastDisk = Date(); lastRoots = roots }
        onChange?()
    }
    func end() { timer?.invalidate(); timer = nil }
}
