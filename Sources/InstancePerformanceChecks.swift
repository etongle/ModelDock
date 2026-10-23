import Foundation
import Darwin

enum InstancePerformanceChecks {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/modeldock-instance-performance").appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let port = try MultiModelPlanner.availablePorts(base: 29740, count: 1, occupied: NetworkProbe.portOccupied)[0]
        let script = root.appendingPathComponent("server.py"), log = root.appendingPathComponent("requests.jsonl")
        try ConnectionFiles.write(Data("""
        import json,sys,time,io,wave,base64
        from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
        class H(BaseHTTPRequestHandler):
            def log_message(self,*a): pass
            def send(self,value,kind='application/json'):
                data=json.dumps(value).encode() if not isinstance(value,bytes) else value
                self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
            def do_GET(self):self.send({'data':[{'id':x} for x in ['fixture','nostats','broken','slow','asr','tts','image','embedding']]})
            def do_POST(self):
                data=self.rfile.read(int(self.headers['Content-Length']))
                multipart=self.headers['Content-Type'].startswith('multipart/')
                body={} if multipart else json.loads(data)
                model='asr' if multipart else body['model']
                with open(sys.argv[2],'a') as f:f.write(json.dumps({'path':self.path,'model':model,'max_tokens':body.get('max_tokens'),'multipart':multipart,'has_audio':b'RIFF' in data})+'\\n')
                if model=='asr': self.send({'text':'fixture transcript'});return
                if model=='tts':
                    out=io.BytesIO()
                    with wave.open(out,'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(bytes(64000))
                    self.send(out.getvalue(),'audio/wav');return
                if model=='embedding':self.send({'data':[{'embedding':[0.1,0.2,0.3]}]});return
                if model=='image':self.send({'data':[{'b64_json':'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='}]});return
                if model=='broken':self.send({'error':{'message':'bad fixture'}});return
                self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
                events=[{'choices':[{'delta':{'role':'assistant'}}]},{'choices':[{'delta':{'content':'hello'}}]},{'choices':[{'delta':{},'finish_reason':'stop'}]}]
                if model!='nostats':events.append({'choices':[],'usage':{'prompt_tokens':5,'completion_tokens':2},'timings':{'predicted_per_second':20}})
                if model=='slow':time.sleep(3)
                try:
                    for e in events:self.wfile.write(('data: '+json.dumps(e)+'\\n\\n').encode());self.wfile.flush();time.sleep(0.02)
                    self.wfile.write(b'data: [DONE]\\n\\n');self.wfile.flush()
                except (BrokenPipeError,ConnectionResetError):pass
        ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
        """.utf8), to: script)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script.path, String(port), log.path]
        try process.run(); defer { process.terminate() }
        for _ in 0..<40 where !NetworkProbe.portOccupied(port) { try await Task.sleep(nanoseconds: 50_000_000) }
        let instanceA = UUID().uuidString, instanceB = UUID().uuidString
        func target(_ name: String, operation: BenchmarkOperation = .chat, instance: String? = nil) -> BenchmarkTarget {
            .init(id: "\(instance ?? instanceA):\(name)", engineID: "fixture", engineName: "Fixture", engineVersion: "1", modelID: "same-local-model", modelName: "same model", apiModel: name, port: port, operation: operation)
        }
        var checks: [String] = []
        try ServiceDisplayChecks.run(root: root)
        checks.append("Canonical file names across services, path aliases and revisions; saved API aliases remain unchanged")
        let result = try await BenchmarkRunner().run(target: target("fixture"), tokens: 64, chip: "Fixture") { _ in }
        try ConnectionChecks.require(result.outputTokens == 2 && result.generationRate == 20 && result.firstOutput != nil && result.elapsed > 0, "Instance stream metrics missing")
        let noStats = try await BenchmarkRunner().run(target: target("nostats"), tokens: 128, chip: "Fixture") { _ in }
        try ConnectionChecks.require(noStats.generationRate == nil && noStats.endToEndRate == nil && noStats.firstOutput != nil, "Fabricated throughput for missing usage")
        do { _ = try await BenchmarkRunner().run(target: target("missing"), tokens: 64, chip: "Fixture") { _ in }; throw LaunchError.message("Silently changed the selected API model") }
        catch { try ConnectionChecks.require(error.localizedDescription.contains("所选模型"), "Unexpected model identity error") }
        checks.append("Streaming TTFT, usage, engine rate and unknown-token handling; never switch to another API model")
        var recycled = target("fixture"); recycled.pid = getpid(); recycled.birth = processStartTime(getpid()) + 1
        do { try recycled.validateProcess(); throw LaunchError.message("Accepted recycled process") }
        catch { try ConnectionChecks.require(error.localizedDescription.contains("进程"), "Unexpected process identity error") }
        try ConnectionChecks.require(result.target.instanceKey == instanceA && target("fixture", instance: instanceB).instanceKey != instanceA, "Same-model instances grouped together")
        checks.append("Distinct service UUIDs stay separate even when model and port match; reject recycled PIDs")
        let controller = PerformanceController(directory: root)
        try controller.add(result)
        var second = result; second.id = UUID().uuidString; second.target = target("fixture", instance: instanceB); try controller.add(second)
        try ConnectionChecks.require(controller.records.filter { $0.target.instanceKey == instanceA }.count == 1, "Another instance's history leaked")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        var oldTarget = legacy["target"] as! [String: Any]; oldTarget.removeValue(forKey: "operation"); legacy["target"] = oldTarget
        for key in ["audioSeconds", "outputUnits", "sampleDescription"] { legacy.removeValue(forKey: key) }
        _ = try JSONDecoder().decode(BenchmarkResult.self, from: JSONSerialization.data(withJSONObject: legacy))
        try ConnectionChecks.require(PerformanceController(directory: root).records.count == 2, "History not persisted")
        checks.append("Per-instance history persistence and compatibility with existing measurements")
        let wav = root.appendingPathComponent("sample.wav")
        var header = Data("RIFF".utf8)
        func le(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        header.append(le(64036)); header.append(Data("WAVEfmt ".utf8)); header.append(le(16)); header.append(contentsOf: [1, 0, 1, 0]); header.append(le(16000)); header.append(le(32000)); header.append(contentsOf: [2, 0, 16, 0]); header.append(Data("data".utf8)); header.append(le(64000)); header.append(Data(repeating: 0, count: 64000)); try header.write(to: wav)
        try ConnectionChecks.require(BenchmarkRunner.wavDuration(header) == 2 && BenchmarkRunner.wavDuration(Data(header.prefix(40))) == nil, "WAV duration accepted truncated data")
        for (name, operation) in [("asr", BenchmarkOperation.transcription), ("tts", .speech), ("image", .image), ("embedding", .embedding)] {
            let value = try await BenchmarkRunner().runOperation(target: target(name, operation: operation), input: .init(audioURL: wav, referenceText: "fixture"), chip: "Fixture") { _ in }
            try ConnectionChecks.require(value.elapsed > 0 && value.firstOutput == nil && value.outputTokens == nil && value.generationRate == nil, "Non-chat response presented as token throughput")
            if operation == .speech || operation == .transcription { try ConnectionChecks.require(value.audioSeconds == 2, "Audio duration missing") }
            if operation == .embedding { try ConnectionChecks.require(value.outputUnits == 3, "Embedding dimensions missing") }
            if operation == .image { try ConnectionChecks.require(value.outputUnits == 1, "Image count missing") }
            try controller.add(value)
        }
        checks.append("ASR multipart, TTS WAV duration, image response and embedding dimensions; no fabricated TTFT or token rates")
        let baseline = controller.records.count
        controller.measure(target("broken"), chip: "Fixture")
        for _ in 0..<60 where controller.running { try await Task.sleep(nanoseconds: 50_000_000) }
        try ConnectionChecks.require(controller.records.count == baseline && controller.message != nil, "Failed response saved as success")
        controller.measure(target("slow"), chip: "Fixture")
        controller.measure(target("fixture", instance: instanceB), chip: "Fixture")
        try ConnectionChecks.require(controller.activeTarget?.apiModel == "slow", "Concurrent test replaced the active instance")
        try await Task.sleep(nanoseconds: 150_000_000); controller.cancel()
        for _ in 0..<60 where controller.running { try await Task.sleep(nanoseconds: 50_000_000) }
        try ConnectionChecks.require(!controller.running && controller.records.count == baseline && controller.activeTarget == nil, "Cancelled test saved a result or kept running")
        checks.append("Errors and cancellation create no success history; one test at a time without stopping services")
        try ConnectionChecks.require(BenchmarkOperation.detect(engine: "audio", model: "Qwen3-ASR", kind: .speech, capabilities: .init()) == .transcription && BenchmarkOperation.detect(engine: "audio", model: "Qwen3-TTS-Base", kind: .speech, capabilities: .init(outputs: ["audio"])) == .speech, "Audio task misdetected")
        let requests = try String(contentsOf: log).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try ConnectionChecks.require(requests.contains { $0["path"] as? String == "/v1/audio/transcriptions" && $0["multipart"] as? Bool == true && $0["has_audio"] as? Bool == true }, "ASR did not receive audio")
        let report = try ConnectionFiles.json(["result": "passed", "checks": checks, "fixtures": root.path])
        try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
    }
}
