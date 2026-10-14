import Foundation

enum DistributionChecks {
    @MainActor static func run() async throws {
        guard let state = argumentValue("--state-dir"), let output = argumentValue("--check-dir"), let resources = Bundle.main.resourceURL else { throw LaunchError.message("Isolated state and output required") }
        let root = URL(fileURLWithPath: output)
        try ConnectionFiles.privateDirectory(root)
        let store = AppStore(stateDirectory: URL(fileURLWithPath: state))
        guard store.services.records.isEmpty else { throw LaunchError.message("Distribution check requires empty state") }
        if store.gateway.ownsProcess() {
            store.gateway.stop()
            for _ in 0..<60 { if !store.gateway.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let python = EnginePaths.bundledPython, EnginePaths.gatewayPython == python, python.hasPrefix(resources.path + "/") else { throw LaunchError.message("Portable Python runtime missing") }
        if let expected = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            try ConnectionChecks.require(Scanner.home.path == expected, "Fresh home was not isolated")
        }
        store.inventory = .init(engines: Scanner.engines(), models: [], storageBytes: 0, memoryBytes: 0, chip: "Apple Silicon", roots: [], warnings: [], scannedAt: Date())
        let ports = try MultiModelPlanner.availablePorts(base: 18970, count: 1, occupied: NetworkProbe.portOccupied)
        store.gateway.portText = String(ports[0]); store.synchronizeGateway(); store.gateway.start(store: store)
        do {
            for _ in 0..<80 { if store.gateway.ready && !store.gateway.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(store.gateway.ready, "Bundled gateway did not start: " + (store.gateway.error ?? ""))
            var request = URLRequest(url: URL(string: store.gateway.endpoint + "/models")!)
            request.setValue("Bearer " + store.gateway.settings.apiKey, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try ConnectionChecks.require((response as? HTTPURLResponse)?.statusCode == 200 && body?["data"] as? [[String: Any]] != nil, "Fresh gateway API unavailable")
            guard let process = store.gateway.process else { throw LaunchError.message("Gateway identity missing") }
            let actualPython = PortIdentity.executable(process.pid)
            let expectedPython = URL(fileURLWithPath: python).resolvingSymlinksInPath().path
            try ConnectionChecks.require(actualPython == expectedPython && PortIdentity.arguments(process.pid).contains("-B"), "Gateway used external Python or wrote bytecode")
            store.gateway.stop()
            for _ in 0..<60 { if !store.gateway.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try ConnectionChecks.require(!NetworkProbe.portOccupied(ports[0]), "Distribution test gateway did not stop")
            let reportData = try ConnectionFiles.json(["result": "passed", "bundledPython": true, "gatewayHTTP": 200, "testPortReleased": true, "freshHome": ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil, "installedEnginesVisible": Scanner.engines().filter(\.installed).count, "servicesModified": false])
            try reportData.write(to: root.appendingPathComponent("result.json")); print(String(decoding: reportData, as: UTF8.self))
        } catch {
            store.gateway.stop()
            for _ in 0..<60 { if !store.gateway.busy { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            throw error
        }
    }
}
