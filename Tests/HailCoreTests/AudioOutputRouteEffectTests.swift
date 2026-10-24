import Testing
@testable import HailCore

@Suite struct AudioOutputRouteEffectTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [[], [Policy.Port.speaker]])
    func fieldSequenceExecutesOneOverrideClearIncludingEchoes(_ blipOutputs: [Policy.Port]) {
        let session = ScriptedOutputSession()
        session.send(Self.speakerChoice)
        #expect(session.effects.isEmpty)
        session.send(.init(
            outputs: [.bluetoothA2DP], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        // 21:16Z: input loss followed by availability, with external output in notification history (#852).
        session.options.defaultToSpeaker = true
        session.send(.init(
            outputs: blipOutputs, inputs: [], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.clears == 0)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable))
        #expect(session.decisionReasons.last == .repairRequested)
        session.drainEchoes()
        #expect(session.categories == 1)
        #expect(session.clears == 1)
        // An echo still on built-in output is conservatively treated as a choice (#852).
        #expect(session.state.userChoseBuiltIn)
    }

    @Test func inputReturnInCategoryEchoWaitsForAvailability() {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(.init(
            outputs: [.speaker], inputs: [], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ))
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .categoryChange))
        #expect(session.clears == 0)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable))
        session.drainEchoes()
        #expect(session.clears == 1)
    }

    @Test(arguments: [false, true])
    func failedApplyRetriesOnNextGenuineEpisode(failClear: Bool) {
        let session = ScriptedOutputSession()
        session.failure = failClear ? .clearOverride : .setCategory(.init())
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ))
        #expect(session.applyResult == .failed)
        session.drainEchoes()
        #expect(session.categories == 1)
        session.send(.init(
            outputs: [.speaker], inputs: [], previousInputs: [.usbAudio], reason: .override
        ))
        // A queued category echo can observe the returned input before the genuine availability event (#852).
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .categoryChange))
        #expect(session.categories == 1)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable))
        session.drainEchoes()
        #expect(session.categories == 2)
        #expect(session.clears == (failClear ? 2 : 1))
        #expect(session.applyResult == .succeeded)
    }

    @Test func repeatedUserChoiceAndUSBBlipExecuteZeroEffects() {
        let session = ScriptedOutputSession()
        session.send(Self.speakerChoice)
        session.drainEchoes()
        session.send(.init(
            outputs: [.bluetoothA2DP], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        session.send(Self.speakerChoice)
        session.drainEchoes()
        #expect(session.categories == 0)
        #expect(session.clears == 0)
        session.send(.init(
            outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ))
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ))
        session.drainEchoes()
        #expect(session.categories == 0)
        #expect(session.clears == 0)
        #expect(session.state.userChoseBuiltIn)
    }

    @Test func playbackKeepaliveExecutesZeroEffects() {
        let session = ScriptedOutputSession()
        session.state.externalOutputSeen = true
        session.options = .init(defaultToSpeaker: true, mixWithOthers: true)
        for reason in Policy.Reason.allCases {
            session.send(.init(
                category: .playback, outputs: [.speaker], inputs: [.usbAudio],
                previousOutputs: [.bluetoothA2DP], reason: reason
            ))
        }
        session.drainEchoes()
        #expect(session.decisionReasons.allSatisfy { $0 == .keepalive })
        #expect(session.categories == 0)
        #expect(session.clears == 0)
        #expect(session.options == .init(defaultToSpeaker: true, mixWithOthers: true))
    }

    private static var speakerChoice: Policy.Route {
        .init(outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
              previousInputs: [.usbAudio], reason: .override)
    }
}

/// Executes the production runner and queues the category/override echoes its effects can cause (#852).
final class ScriptedOutputSession {
    typealias Policy = AudioOutputRoutePolicy
    typealias Effect = AudioOutputRouteDriver.Effect
    enum Failure: Error { case scripted }
    enum ApplyResult { case notAttempted, succeeded, failed }
    var state = Policy.State()
    var options = Policy.Options()
    var effects: [Effect] = []
    var applyResult = ApplyResult.notAttempted
    var failure: Effect?
    var overrideOutputs: [Policy.Port]?
    var decisionReasons: [Policy.DecisionReason] = []
    private var echoes: [Policy.Route] = []

    var categories: Int { effects.filter { if case .setCategory = $0 { true } else { false } }.count }
    var clears: Int { effects.filter { $0 == .clearOverride }.count }

    func send(_ route: Policy.Route) {
        var current = route
        current.options = options
        let snapshot = current
        applyResult = AudioOutputRouteDriver.process(snapshot, state: &state, observeDecision: { decision in
            self.decisionReasons.append(decision.reason)
        }, perform: { effect in
            try self.perform(effect, route: snapshot)
        }) ? .succeeded : .failed
    }

    func drainEchoes() {
        for _ in 0..<20 {
            guard !echoes.isEmpty else { return }
            send(echoes.removeFirst())
        }
        #expect(echoes.isEmpty, "Effects must not create a notification loop")
    }

    private func perform(_ effect: Effect, route: Policy.Route) throws {
        effects.append(effect)
        var echo = route
        echo.previousInputs = route.inputs
        echo.previousOutputs = route.outputs
        echo.reason = effect == .clearOverride ? .override : .categoryChange
        if effect == failure {
            failure = nil
            throw Failure.scripted
        }
        if effect == .clearOverride, let overrideOutputs { echo.outputs = overrideOutputs }
        echoes.append(echo)
        if case .setCategory(let desired) = effect { options = desired }
    }
}
