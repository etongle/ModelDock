import Foundation
import Darwin

enum MonitorChecks {
    @MainActor static func run() async throws {
        let directory = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-monitor-checks").appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default; try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String] = []
        try FeatureChecks.require(ResourceSampler.cpuTicks(previous: [10, 10, 10, 10], current: [20, 20, 20, 20]) == 75, "Whole-machine CPU calculation failed")
        try FeatureChecks.require(ResourceSampler.cpuTicks(previous: [UInt64(UInt32.max) - 1, 0, 0, 0], current: [1, 0, 1, 0]) == 75, "CPU counter wrap failed")
        let previous = ProcessSample(processes: [.init(pid: 42, birth: 1, cpuNanoseconds: 100, memory: 100)], at: 1_000_000_000)
        let current = ProcessSample(processes: [.init(pid: 42, birth: 1, cpuNanoseconds: 2_000_000_100, memory: 100)], at: 2_000_000_000)
        try FeatureChecks.require(ResourceSampler.cpu(previous: previous, current: current) == 200, "Multicore CPU was incorrectly limited")
        let recycled = ProcessSample(processes: [.init(pid: 42, birth: 2, cpuNanoseconds: 2_000_000_100, memory: 100)], at: 2_000_000_000)
        try FeatureChecks.require(ResourceSampler.cpu(previous: previous, current: recycled) == nil, "Reused PID produced a false CPU reading")
        checks.append("CPU tick deltas, wrapping counters, multicore usage and PID-reuse isolation")

        let raw = await Task.detached { ResourceSampler.collect(targets: [], roots: [], countModels: false) }.value
        guard let system = raw.system else { throw LaunchError.message("Native system metrics unavailable") }
        try FeatureChecks.require(system.memoryUsed > 0 && system.memoryUsed <= system.memoryTotal && system.diskTotal > 0 && system.diskAvailable >= 0, "Invalid native resource values")
        let pid = getpid(); let birth = processStartTime(pid)
        guard let before = ResourceSampler.process(pid, birth: birth) else { throw LaunchError.message("Native process footprint unavailable") }
        let work = await Task.detached { () -> Double in
            let until = DispatchTime.now().uptimeNanoseconds + 250_000_000
            var sum = 0.0
            while DispatchTime.now().uptimeNanoseconds < until { sum += sin(Double(sum.truncatingRemainder(dividingBy: 123)) + 0.1) }
            return sum
        }.value
        guard let after = ResourceSampler.process(pid, birth: birth), let cpu = ResourceSampler.cpu(previous: before, current: after) else { throw LaunchError.message("Native process CPU unavailable") }
        try FeatureChecks.require(work.isFinite && after.bytes > 0 && cpu > 50 && cpu < Double(ProcessInfo.processInfo.activeProcessorCount) * 100 + 100, "Process CPU units or memory footprint incorrect: \(cpu)%")
        try FeatureChecks.require(ResourceSampler.process(pid, birth: birth + 1) == nil, "Wrong process identity accepted")
        checks.append("Native CPU nanosecond counters, physical footprint, total memory and filesystem capacity")

        let diskRoot = directory.appendingPathComponent("disk-fixture"); let child = diskRoot.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let file = child.appendingPathComponent("weight.gguf"); try Data(repeating: 37, count: 16384).write(to: file)
        let first = ResourceSampler.modelDisk([diskRoot.path])
        try fm.linkItem(at: file, to: diskRoot.appendingPathComponent("hardlink.gguf"))
        try fm.createSymbolicLink(at: diskRoot.appendingPathComponent("alias"), withDestinationURL: child)
        try FeatureChecks.require(first == ResourceSampler.modelDisk([diskRoot.path, child.path]), "Model storage double-counted aliases or nested directories")
        checks.append("Allocated model storage de-duplicates hardlinks, symbolic links and nested roots")

        var metrics = StreamMetrics()
        try metrics.line("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}", elapsed: 0.1); try metrics.line("", elapsed: 0.1)
        try FeatureChecks.require(metrics.firstOutput == nil, "Role-only frame treated as output")
        try metrics.line("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}", elapsed: 0.25); try metrics.line("", elapsed: 0.25)
        try metrics.line("data: {\"choices\":[{\"delta\":{\"content\":\"many output characters\"},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":42,\"completion_tokens\":4},\"timings\":{\"predicted_n\":4,\"predicted_per_second\":20,\"prompt_per_second\":100,\"cache_n\":12}}", elapsed: 0.5); try metrics.line("", elapsed: 0.5)
        try metrics.line("data: [DONE]", elapsed: 0.5); try metrics.line("", elapsed: 0.5)
        try FeatureChecks.require(metrics.firstOutput == 0.25 && metrics.outputTokens == 4 && metrics.generationRate == 20 && metrics.cachedTokens == 12 && metrics.done, "Stream timing or token usage parsed incorrectly")
        var unknown = StreamMetrics(); try unknown.line("data: {\"choices\":[{\"delta\":{\"content\":\"lots of words\"},\"finish_reason\":\"stop\"}]}", elapsed: 0.2); try unknown.flush(elapsed: 0.2)
        try FeatureChecks.require(unknown.outputTokens == nil && unknown.generationRate == nil, "Unknown token counts were fabricated from text")
        var adjacent = StreamMetrics()
        try adjacent.line("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}", elapsed: 0.2)
        try adjacent.line("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":1}}", elapsed: 0.3)
        try adjacent.line("data: [DONE]", elapsed: 0.3)
        try FeatureChecks.require(adjacent.firstOutput == 0.2 && adjacent.outputTokens == 1 && adjacent.done, "SSE events without blank lines merged incorrectly")
        var multiline = StreamMetrics()
        try multiline.line("data: {", elapsed: 0.1)
        try multiline.line("data: \"choices\": [{\"delta\": {\"content\": \"hello\"}, \"finish_reason\": \"stop\"}],", elapsed: 0.2)
        try multiline.line("data: \"usage\": {\"completion_tokens\": 1}}", elapsed: 0.3)
        try FeatureChecks.require(multiline.firstOutput == 0.3 && multiline.outputTokens == 1 && multiline.finishReason, "Multiline SSE JSON failed")
        checks.append("Streaming first-output latency, reasoning output, server timings, cache counts and unavailable-metric handling")

        var live: BenchmarkResult?
        if CommandLine.arguments.contains("--live-benchmark") {
            let state = Scanner.home.appendingPathComponent("Library/Application Support/ModelManager/services.json")
            let specs = try JSONDecoder().decode([ServiceSpec].self, from: Data(contentsOf: state))
            guard let spec = specs.first(where: { $0.pid != nil && $0.engineID == "splash" }), let pid = spec.pid else { throw LaunchError.message("Existing Splash service unavailable") }
            let response = await NetworkProbe.models(port: spec.port)
            guard response.ready, let apiModel = response.models.first else { throw LaunchError.message("Splash model API unavailable") }
            let inventory = Scanner.scan(); let engine = inventory.engines.first { $0.id == spec.engineID }!
            let target = BenchmarkTarget(id: "\(spec.id):\(apiModel)", engineID: spec.engineID, engineName: engine.name, engineVersion: engine.version, modelID: spec.modelID, modelName: spec.modelName, apiModel: apiModel, port: spec.port, pid: pid, birth: spec.processStart, context: spec.context)
            let result = try await BenchmarkRunner().run(target: target, tokens: 64, chip: inventory.chip) { _ in }
            try FeatureChecks.require(result.outputTokens.map { $0 > 0 } == true && result.firstOutput.map { $0 > 0 && $0 <= result.elapsed } == true && result.elapsed > 0 && result.peakMemory.map { $0 > 0 } == true, "Live inference measurements incomplete")
            try FeatureChecks.require(processStartTime(pid) == spec.processStart && NetworkProbe.portOccupied(spec.port), "Existing service changed during benchmark")
            try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("performance-sample.json"))
            live = result
            checks.append("Real 64-token Splash stream, first-output latency, end-to-end throughput and sampled service memory; same service PID retained")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Codable { var result: String; var checks: [String]; var system: SystemResource; var nativeProcessCPU: Double; var live: BenchmarkResult?; var fixtures: String }
        let report = Report(result: "passed", checks: checks, system: system, nativeProcessCPU: cpu, live: live, fixtures: directory.path)
        let data = try encoder.encode(report); try data.write(to: directory.appendingPathComponent("result.json")); print(String(decoding: data, as: UTF8.self))
    }
}
