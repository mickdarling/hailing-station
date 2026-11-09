import Testing
@testable import HailCore

@Suite("Microphone indicator (#334)")
struct MicLiveIndicatorTests {
    private func state(
        engine: MicEngineState? = .stopped, ambient: StationMenuStatus.Listening? = .off,
        talk: TalkCapturePhase? = .idle
    ) -> MicLiveState {
        MicLiveInputs(engine: engine, ambient: ambient, talk: talk).state
    }

    @Test func clearOnlyWhenTheEngineIsStoppedAndEveryPhaseIsOff() {
        #expect(state() == .off)
        #expect(!MicLiveState.off.showsRed)
        #expect(state(ambient: .elsewhere) == .off)
    }

    @Test func recordingFromEitherOwnerIsLive() {
        #expect(state(engine: .running, ambient: .listening) == .live)
        #expect(state(engine: .running, talk: .recording) == .live)
        #expect(MicLiveState.live.showsRed)
    }

    // Jarvis, PR 2 plan: a host-reported phase must never clear the red while the local engine may be capturing.
    @Test func hostSaysElsewhereButTheLocalEngineRunsIsLive() {
        #expect(state(engine: .running, ambient: .elsewhere) == .live)
        #expect(state(engine: .running, ambient: .off, talk: .idle) == .live)
    }

    @Test func anUnknownEngineIsNeverClear() {
        #expect(state(engine: .unknown) == .uncertain)
        #expect(state(engine: .unknown, ambient: .elsewhere) == .uncertain)
        #expect(MicLiveState.uncertain.showsRed)
    }

    @Test func aSourceThatHasNotReportedIsUncertain() {
        #expect(state(engine: nil) == .uncertain)
        #expect(state(ambient: nil) == .uncertain)
        #expect(state(talk: nil) == .uncertain)
        #expect(MicLiveInputs(engine: nil, ambient: nil, talk: nil).state == .uncertain)
    }

    @Test func transitionsAndAnAutomaticResumeAreUncertain() {
        #expect(state(ambient: .starting) == .uncertain)
        #expect(state(ambient: .paused) == .uncertain)
        #expect(state(talk: .starting) == .uncertain)
        #expect(state(talk: .finishing) == .uncertain)
    }

    @Test func theMostAlarmingSourceWins() {
        #expect(state(engine: .unknown, talk: .recording) == .live)
        #expect(state(engine: .stopped, ambient: .listening) == .live)
        #expect(state(engine: .stopped, ambient: .paused, talk: .idle) == .uncertain)
    }

    @Test func labelsNameEachStateDistinctly() {
        let labels = [MicLiveState.live, .uncertain, .off].map(\.label)
        #expect(labels == ["Microphone on", "Microphone may be on", "Microphone off"])
    }
}
