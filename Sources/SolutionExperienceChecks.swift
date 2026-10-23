import Foundation

@MainActor enum SolutionExperienceChecks {
    static func translation(store: AppStore, deployment: SolutionDeployment, input: URL) async throws {
        func require(_ value: Bool, _ message: String) throws { try ConnectionChecks.require(value, message) }
        let session = store.experienceSession(deployment)
        session.input = "Hello from the first turn"; session.send(store: store)
        try await SolutionChecks.wait { !session.sending }
        try require(session.turns.count == 1 && session.turns[0].response == "Bonjour le monde" && session.turns[0].error == nil, "Conversation first turn failed")
        session.dismiss()
        try require(store.experienceSession(deployment) === session && session.turns.count == 1, "Closing a conversation lost its history")
        session.input = "And the next turn"; session.send(store: store)
        try await SolutionChecks.wait { !session.sending }
        try require(session.turns.count == 2 && session.turns.allSatisfy { !$0.pending && $0.error == nil }, "Follow-up overwrote the previous turn")
        let serviceID = deployment.components.first { $0.role == .text }!.serviceID
        let spec = store.services.records.first { $0.id == serviceID }!
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(spec.port)/fixture/conversations")!)
        let sent = try JSONSerialization.jsonObject(with: data) as! [[[String: String]]]
        let context = sent.last!
        try require(context.map { $0["role"]! } == ["system", "user", "assistant", "user"] && context[1]["content"] == "Hello from the first turn" && context[3]["content"] == "And the next turn", "Follow-up did not send completed translation context")
        var other = deployment; other.id = UUID().uuidString
        let isolated = store.experienceSession(other)
        try require(isolated !== session && isolated.turns.isEmpty, "Shared service mixed histories from different solution instances")
        session.translateAudio(input, store: store)
        try await SolutionChecks.wait { !session.sending }
        try require(session.turns.count == 3 && session.turns.last?.input == "Hello world" && session.turns.last?.response == "Bonjour le monde", "Audio result did not join the same conversation")
        session.microphone.start(deployment, store: store, microphone: false, preserveHistory: true)
        try await SolutionChecks.wait { session.microphone.listening || session.microphone.error != nil }
        session.microphone.submit(SpeechSegmenter.wav([Float](repeating: 0.1, count: 16000)), deployment: deployment, store: store)
        try await SolutionChecks.wait { !session.microphone.processing }
        session.dismiss()
        try require(session.turns.count == 4 && !session.microphone.listening && !session.microphone.processing, "Microphone history or capture lifetime is incorrect")
        session.newConversation()
        try require(session.turns.isEmpty && session.translationContext.isEmpty && isolated.turns.isEmpty, "New conversation retained model context")
        var changed = deployment; changed.draft.language = "Portuguese"
        try require(store.experienceSession(changed) !== session, "Changed solution configuration reused an old translation conversation")
        print("SOLUTION CONVERSATION CHECKS PASSED: gateway follow-ups, instance isolation, reopening, audio, microphone, new conversation")
    }
}
