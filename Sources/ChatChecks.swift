import Foundation

enum ChatChecks {
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: argumentValue("--check-dir") ?? "/private/tmp/model-manager-chat").resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try ConnectionFiles.privateDirectory(root)
        let port = try MultiModelPlanner.availablePorts(base: 29680, count: 1, occupied: NetworkProbe.portOccupied)[0]
        // 模拟 OpenAI 兼容流式接口：先返回思考，再返回正文和 usage；模型名为 bad 时返回 400 错误。
        let script = root.appendingPathComponent("server.py")
        try ConnectionFiles.write(Data("""
        import json,sys,pathlib
        from http.server import HTTPServer,BaseHTTPRequestHandler
        out=pathlib.Path(sys.argv[2])
        class H(BaseHTTPRequestHandler):
            def log_message(self,*a):pass
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));out.write_text(json.dumps(body))
                if body['model']=='bad':
                    data=json.dumps({'error':{'message':'context too long'}}).encode()
                    self.send_response(400);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
                self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
                for e in [{'choices':[{'delta':{'reasoning_content':'think'}}]},{'choices':[{'delta':{'content':'Hello '}}]},{'choices':[{'delta':{'content':'world'},'finish_reason':'stop'}]},{'choices':[],'usage':{'prompt_tokens':5,'completion_tokens':2}}]:
                    self.wfile.write(('data: '+json.dumps(e)+'\\n\\n').encode());self.wfile.flush()
                self.wfile.write(b'data: [DONE]\\n\\n');self.wfile.flush()
        HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
        """.utf8), to: script)
        let request = root.appendingPathComponent("request.json")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script.path, String(port), request.path]
        try process.run(); defer { process.terminate() }
        for _ in 0..<40 where !NetworkProbe.portOccupied(port) { try await Task.sleep(nanoseconds: 100_000_000) }
        func target(_ model: String, images: Bool = false) -> ConnectionTarget {
            var value = ConnectionTarget(id: model, engineName: "fixture", engineID: "llama", model: model, port: port, pid: 1, birth: 1)
            value.capabilities = ModelCapabilities(inputs: images ? ["text", "image"] : ["text"]); return value
        }
        func wait(_ session: ChatSession) async throws { for _ in 0..<50 where session.streaming { try await Task.sleep(nanoseconds: 100_000_000) } }
        let session = ChatSession(targets: [target("fixture", images: true), target("bad")])
        session.system = "be brief"; session.temperature = 0.3; session.maxTokens = 512
        var recorded: [BenchmarkResult] = []
        session.benchmarkTargets = ["fixture": BenchmarkTarget(id: "fixture", engineID: "llama", engineName: "fixture", engineVersion: "1", modelID: "m", modelName: "fixture", apiModel: "fixture", port: port)]
        session.record = { recorded.append($0) }
        session.attachments = ["data:image/png;base64,AAAA"]; session.input = "hi"; session.send(); try await wait(session)
        let reply = session.messages.last
        try ConnectionChecks.require(session.error == nil && reply?.text == "Hello world" && reply?.reasoning == "think", "Streamed reply wrong: \(String(describing: reply)) \(session.error ?? "")")
        try ConnectionChecks.require(reply?.stats?.contains("2 tokens") == true && reply?.stats?.contains("≈") == false, "Usage stats missing: \(reply?.stats ?? "nil")")
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: request)) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let parts = messages.last?["content"] as? [[String: Any]] ?? []
        try ConnectionChecks.require(body["stream"] as? Bool == true && body["max_tokens"] as? Int == 512 && messages.first?["content"] as? String == "be brief"
            && parts.contains { $0["type"] as? String == "image_url" } && parts.contains { $0["text"] as? String == "hi" }, "Request body wrong: \(body)")
        try ConnectionChecks.require(recorded.count == 1 && recorded[0].outputTokens == 2 && recorded[0].requestedTokens == 512 && recorded[0].firstOutput != nil && recorded[0].rateSource.hasPrefix("来自试聊"), "Chat result not recorded: \(recorded)")
        session.targetID = "bad"; session.input = "again"; session.send(); try await wait(session)
        try ConnectionChecks.require(recorded.count == 1, "Failed chat should not be recorded")
        try ConnectionChecks.require(session.error == "context too long" && session.messages.count == 3, "Error response not surfaced: \(session.error ?? "nil") \(session.messages.count)")
        // 对比模式：同一条消息同时发给两个会话，两边都记录速度。
        let pair = ChatSession(targets: [target("fixture")])
        pair.benchmarkTargets = session.benchmarkTargets; pair.record = { recorded.append($0) }
        pair.makeSession = { targets in let other = ChatSession(targets: targets); other.benchmarkTargets = ["fixture-2": BenchmarkTarget(id: "fixture-2", engineID: "llama", engineName: "fixture", engineVersion: "1", modelName: "fixture", apiModel: "fixture", port: port)]; other.record = { recorded.append($0) }; return other }
        var second = target("fixture"); second.id = "fixture-2"
        pair.startCompare(second); pair.input = "compare"; pair.send()
        for _ in 0..<50 where pair.busy { try await Task.sleep(nanoseconds: 100_000_000) }
        try ConnectionChecks.require(pair.messages.last?.text == "Hello world" && pair.compare?.messages.last?.text == "Hello world" && recorded.count == 3, "Compare mode wrong: \(recorded.count)")
        let report = try ConnectionFiles.json(["result": "passed", "checks": ["Streams content and reasoning", "Reports usage-based stats", "Sends system prompt, parameters and image parts", "Surfaces service error message", "Completed reply recorded to measurement history; failures are not", "Compare mode sends to both services and records both"]])
        try report.write(to: root.appendingPathComponent("result.json")); print(String(decoding: report, as: UTF8.self))
    }
}
