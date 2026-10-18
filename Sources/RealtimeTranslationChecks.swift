import Foundation

@MainActor enum RealtimeTranslationChecks {
    static func segments() throws {
        func require(_ value: Bool, _ message: String) throws { try ConnectionChecks.require(value, message) }
        try require(SolutionCatalog.visible.map(\.id) == ["voice-translation"], "Unverified solutions remain in the visible catalog")
        var segmenter = SpeechSegmenter()
        let silence = [Float](repeating: 0, count: 1600)
        let speech = (0..<1600).map { Float(sin(Double($0) * 0.12)) * 0.1 }
        var clips: [Data] = []
        for _ in 0..<4 { clips += segmenter.append(silence) }
        try require(clips.isEmpty, "Silence created an audio request")
        for _ in 0..<10 { clips += segmenter.append(speech) }
        for _ in 0..<7 { clips += segmenter.append(silence) }
        try require(clips.count == 1 && clips[0].prefix(4) == Data("RIFF".utf8) && clips[0].subdata(in: 8..<12) == Data("WAVE".utf8), "Speech pause did not emit WAV audio")
        for _ in 0..<125 { clips += segmenter.append(speech) }
        try require(clips.count >= 3 && clips.allSatisfy { $0.count <= 44 + 16000 * 2 * 7 }, "Continuous audio produced an unbounded request")
    }

    static func editing(store: AppStore, deployment: SolutionDeployment, root: URL) async throws {
        try segments()
        let isolated = AppStore(stateDirectory: root.appendingPathComponent("editing-state"))
        isolated.inventory = store.inventory
        isolated.services.records = store.solutions.services(deployment, store: store).map { value in var result = value; result.pid = nil; result.processStart = nil; return result }
        let controller = isolated.solutions
        defer { controller.stop(controller.deployments.first?.id ?? "", store: isolated); isolated.gateway.stop() }
        var record = deployment; record.id = UUID().uuidString
        record.draft.speechOutput = false; record.components.removeAll { $0.role == .tts }
        for index in record.components.indices { record.components[index].ownsConfiguration = false }
        record.processes = []; controller.deployments = [record]
        controller.drafts[record.solutionID] = record.draft; controller.selectedID = record.solutionID
        let endpoint = isolated.gateway.solutionEndpoint(record)
        controller.edit(record.id, store: isolated)
        var draft = controller.draft; draft.language = "Portuguese"; draft.sourceLanguage = "English"; controller.setDraft(draft)
        controller.install(store: isolated)
        try await SolutionChecks.wait { controller.preparingID == nil && controller.latest?.state == .configured }
        try ConnectionChecks.require(controller.latest?.id == record.id && controller.latest?.draft.language == "Portuguese" && controller.latest?.components.count == 2 && isolated.gateway.solutionEndpoint(controller.latest!) == endpoint, "Editing did not update the same deployment and stable URL")
        let port = try MultiModelPlanner.availablePorts(base: 29930, count: 1, occupied: NetworkProbe.portOccupied)[0]
        isolated.gateway.settings.port = port; isolated.gateway.portText = String(port)
        controller.start(record.id, store: isolated)
        try await SolutionChecks.wait { !controller.startingIDs.contains(record.id) }
        let latest = controller.latest!
        try ConnectionChecks.require(controller.runtime(latest, store: isolated).allReady && controller.services(latest, store: isolated).allSatisfy { $0.pid != nil } && isolated.gateway.solutionReady(latest), latest.error ?? "Stopped reused services did not start with the solution")
        try ConnectionChecks.require(latest.components.allSatisfy { !$0.ownsConfiguration } && latest.processes.count == 2, "Starting reused services changed configuration ownership or lost process tracking")
        controller.stop(record.id, store: isolated)
        for _ in 0..<100 {
            await isolated.services.refresh()
            if controller.services(latest, store: isolated).allSatisfy({ $0.pid == nil }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try ConnectionChecks.require(controller.services(latest, store: isolated).allSatisfy { $0.pid == nil }, "Solution did not stop the borrowed processes it explicitly started")
        isolated.gateway.stop()
        for _ in 0..<80 { if !isolated.gateway.busy { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try ConnectionChecks.require(deployment.components.allSatisfy { component in store.services.records.contains { $0.id == component.serviceID && $0.pid == nil } }, "Original service records changed")
    }

    static func pipeline(store: AppStore, deployment: SolutionDeployment) async throws {
        let controller = store.realtimeTranslation
        controller.start(deployment, store: store, microphone: false)
        try await SolutionChecks.wait { controller.listening || controller.error != nil }
        try ConnectionChecks.require(controller.error == nil, controller.error ?? "Realtime session failed")
        let audio = SpeechSegmenter.wav([Float](repeating: 0.1, count: 16000))
        controller.submit(audio, deployment: deployment, store: store)
        controller.submit(audio, deployment: deployment, store: store)
        try await SolutionChecks.wait { !controller.processing }
        try ConnectionChecks.require(controller.subtitles.count == 2 && controller.subtitles.allSatisfy { $0.original == "Hello world" && $0.translated == "Bonjour le monde" }, controller.error ?? "Realtime segments did not produce ordered subtitles")
        controller.cancel()
        try ConnectionChecks.require(!controller.listening && !controller.processing && controller.pending == 0, "Realtime cancellation retained microphone or queued work")
    }
}
