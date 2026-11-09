import Testing
@testable import HailCore

@Suite("Voice dock (#1115)")
struct VoiceDockStateTests {
    private static let build = DestinationLabel(
        hostName: "Studio", targetName: "build", targetKind: "tmux", targetID: "%1")
    private static let confirmed = DestinationControlState.confirmed(build)
    private static let all = DockAccessories(escape: true, privacy: true, paste: true)

    private func resolve(
        _ phase: TalkCapturePhase?, pending: Bool = false, interrupting: Bool = false,
        destination: DestinationControlState = confirmed, accessories: DockAccessories = all
    ) -> VoiceDockState {
        VoiceDockState.resolve(
            talk: TalkActivity(phase: phase, sendPending: pending, interrupting: interrupting),
            destination: destination, accessories: accessories)
    }

    @Test func idleOnAConfirmedDestinationIsTapToTalk() {
        let state = resolve(.idle)
        #expect(state.primary == .talk)
        #expect(state.label == "Tap to talk")
        #expect(state.isEnabled)
        #expect(state.primaryIntent == .talk)
        #expect(state.value == "Destination: Mac Studio, Terminal build.")
        #expect(!state.showsCaption)
    }

    @Test func recordingIsFinishAndSendInTheSamePlace() {
        let state = resolve(.recording)
        #expect(state.primary == .finish)
        #expect(state.label == "Finish & send")
        #expect(state.primaryIntent == .finish)
        #expect(state.showsCaption)
    }

    // Jarvis, PR 5 plan: stopping is never blocked, but "send" needs a confirmed destination.
    @Test func recordingWithoutAConfirmedDestinationStillFinishesWithoutClaimingSend() {
        let state = resolve(.recording, destination: .confirming(saved: Self.build))
        #expect(state.label == "Finish")
        #expect(state.isEnabled)
        #expect(state.value == "Confirming destination. Saved, not confirmed: Mac Studio, Terminal build.")
    }

    // Today's talk button is disabled while an Escape is under way, which is already stopping and discarding the
    // capture: a Finish then would send what Escape discards (Jarvis, PR 5 plan).
    @Test func anEscapeUnderWayDisablesFinish() {
        let state = resolve(.recording, interrupting: true)
        #expect(state.primary == .interrupting)
        #expect(!state.isEnabled)
        #expect(state.primaryIntent == nil)
        #expect(state.escape == .disabled)
    }

    @Test func aPendingRequestDisablesTalkAndPasteAsToday() {
        let state = resolve(.idle, pending: true)
        #expect(state.label == "Tap to talk")
        #expect(!state.isEnabled)
        #expect(state.value == "The last request is still pending.")
        #expect(state.paste == .disabled)
        #expect(state.escape == .enabled)
    }

    @Test func anUnconfirmedDestinationMakesTalkUnavailable() {
        let state = resolve(.idle, destination: .unavailable(.offline, saved: nil))
        #expect(state.primary == .unavailable)
        #expect(state.label == "Talk unavailable")
        #expect(state.value == "Destination unavailable: offline.")
        #expect(resolve(.idle, destination: .none).value == "No destination. Choose a destination.")
    }

    @Test func anUnknownTalkPhaseNeverEnablesTalkButKeepsEscape() {
        let state = resolve(nil)
        #expect(state.label == "Talk unavailable")
        #expect(!state.isEnabled)
        #expect(state.escape == .enabled)
        #expect(!state.showsCaption)
    }

    @Test func startingAndFinishingMatchTodaysButton() {
        let starting = resolve(.starting)
        #expect(starting.label == "Starting…")
        #expect(!starting.isEnabled)
        #expect(starting.showsCaption)
        let finishing = resolve(.finishing)
        #expect(finishing.label == "Finishing…")
        #expect(!finishing.isEnabled)
        #expect(finishing.escape == .disabled)
    }

    @Test func controlsTheOwnersDontOfferAreHidden() {
        let state = resolve(.idle, accessories: DockAccessories(escape: false, privacy: false, paste: false))
        #expect(state.escape == .hidden)
        #expect(state.privacy == .hidden)
        #expect(state.paste == .hidden)
    }
}
