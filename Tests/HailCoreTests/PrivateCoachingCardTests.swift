import Foundation
@testable import HailCore
import Testing

@Suite("Private coaching card model (#645)")
struct PrivateCoachingCardTests {
    @Test func statusLinesParseOnlyContentFreeWords() {
        #expect(PrivateCoachingStatusLine("coaching: active") == .status(.active))
        #expect(PrivateCoachingStatusLine("coaching: off") == .status(.off))
        #expect(PrivateCoachingStatusLine("coaching ended: route") == .ended(.route))
        #expect(PrivateCoachingStatusLine("coaching: listening to something") == nil)
        #expect(PrivateCoachingStatusLine("coaching ended: Synthetic words") == nil)
        #expect(PrivateCoachingStatusLine("Private coaching is OFF. Local controls only:") == nil)
    }

    @Test func endReasonsCollapseSuspensions() {
        #expect(PrivateCoachingEndReason(.routeInvalidated) == .route)
        #expect(PrivateCoachingEndReason(.stopped) == .stopped)
        #expect(PrivateCoachingEndReason(.adviceExpired) == .expired)
        #expect(PrivateCoachingEndReason(.qualificationExpired) == .expired)
        #expect(PrivateCoachingEndReason(.captureFailed) == .failed)
        #expect(PrivateCoachingEndReason(.playbackFailed) == .failed)
    }

    @Test func startGoesLiveOnlyAfterActive() {
        var model = PrivateCoachingCardModel()
        model.startRequested()
        #expect(model.state == .starting)
        model.received(.status(.starting))
        #expect(model.state == .starting)
        model.received(.status(.active))
        #expect(model.state == .live)
        #expect(model.state.holdsAudio)
    }

    @Test func routeChangeSuspendsAndNeverResumesByItself() {
        var model = live()
        model.received(.status(.off))
        model.received(.ended(.route))
        #expect(model.state == .live) // Still holding until the child has exited.
        model.childExited()
        #expect(model.state == .suspendedOnRouteChange)
        model.received(.status(.active))
        #expect(model.state == .suspendedOnRouteChange)
        model.startRequested()
        #expect(model.state == .starting)
    }

    @Test func stopEndsStoppedEvenWithoutAReason() {
        var model = live()
        model.stopRequested()
        model.childExited()
        #expect(model.state == .stopped)
    }

    @Test func unexplainedExitIsAnError() {
        var starting = PrivateCoachingCardModel()
        starting.startRequested()
        starting.childExited()
        #expect(starting.state == .error)
        var failed = live()
        failed.received(.ended(.failed))
        failed.childExited()
        #expect(failed.state == .error)
    }

    @Test func activeAfterStopDoesNotGoLive() {
        var model = PrivateCoachingCardModel()
        model.startRequested()
        model.stopRequested()
        model.received(.status(.active))
        #expect(model.state == .starting)
    }

    @Test func headphoneCheckOnlyForBluetoothAndUSBUntilConfirmed() {
        #expect(PrivateCoachingOutputTransport.bluetooth.needsHeadphoneCheck(outputKey: "a", lastConfirmedKey: nil))
        #expect(PrivateCoachingOutputTransport.usb.needsHeadphoneCheck(outputKey: "a", lastConfirmedKey: "b"))
        #expect(!PrivateCoachingOutputTransport.usb.needsHeadphoneCheck(outputKey: "a", lastConfirmedKey: "a"))
        #expect(!PrivateCoachingOutputTransport.wired.needsHeadphoneCheck(outputKey: "a", lastConfirmedKey: nil))
        #expect(!PrivateCoachingOutputTransport.builtIn.needsHeadphoneCheck(outputKey: "a", lastConfirmedKey: nil))
    }

    @Test func gateNamesTheFirstBlockerAndHostedNeedsConsent() {
        var gate = ready()
        #expect(gate.blocker == nil)
        gate.hostedChosen = true
        #expect(gate.blocker == .hostedConsent)
        gate.hostedConsentConfirmed = true
        #expect(gate.blocker == nil)
        gate.awarenessConfirmed = false
        #expect(gate.blocker == .awareness)
        gate.headphoneCheckNeeded = true
        #expect(gate.blocker == .headphoneCheck)
        gate.ambientListening = true
        #expect(gate.blocker == .ambientListening)
        gate.state = .live
        #expect(gate.blocker == .notIdle)
    }

    @Test func hostedSpeechNeedsItsOwnConsentEvenWithTheLocalProvider() {
        var gate = ready()
        gate.hostedSpeech = true
        #expect(gate.blocker == .hostedSpeechConsent)
        gate.hostedSpeechConsentConfirmed = true
        #expect(gate.blocker == nil)
        #expect(PrivateCoachingConsentText.hostedSpeech.contains("Hosted"))
    }

    @Test func gateRefusesWhileAnotherCaptureHoldsReplies() {
        var gate = ready()
        gate.captureActive = true
        #expect(gate.blocker == .captureActive)
    }

    @Test func consentTextIsMarkedPlaceholder() throws {
        // The wording is Mick's call (#645); these only pin that it exists and is not empty.
        #expect(!PrivateCoachingConsentText.participantAwareness.isEmpty)
        #expect(PrivateCoachingConsentText.hostedProvider.contains("hosted"))
        #expect(!PrivateCoachingConsentText.headphoneCheck.isEmpty)
    }

    private func live() -> PrivateCoachingCardModel {
        var model = PrivateCoachingCardModel()
        model.startRequested()
        model.received(.status(.active))
        return model
    }

    private func ready() -> PrivateCoachingStartGate {
        PrivateCoachingStartGate(state: .idle, setupReady: true, ambientListening: false, captureActive: false,
                                 microphoneChosen: true, outputChosen: true, headphoneCheckNeeded: false,
                                 headphonesConfirmed: false, awarenessConfirmed: true, hostedChosen: false,
                                 hostedConsentConfirmed: false, hostedSpeech: false,
                                 hostedSpeechConsentConfirmed: false)
    }
}
