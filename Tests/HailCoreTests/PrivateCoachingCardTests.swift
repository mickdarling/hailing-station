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
                                 hostedConsentConfirmed: false)
    }
}

@Suite("Private coaching setup (#645)")
struct PrivateCoachingSetupTests {
    private static let local = """
    {"haild":"/synthetic/haild","rightyo":"/synthetic/rightyo","rightyoConfig":"/synthetic/config",
     "listenerProfile":"/synthetic/profile","listener":"owner","rendererOutputRoot":"/synthetic/out"}
    """
    private static let hosted = """
    {"haild":"/synthetic/haild","rightyo":"/synthetic/rightyo","rightyoConfig":"/synthetic/config",
     "listenerProfile":"/synthetic/profile","listener":"owner","rendererOutputRoot":"/synthetic/out",
     "hosted":{"maxRequests":12,"adviceCatalog":"/synthetic/catalog"}}
    """

    @Test func localArgumentsCarryNoHostedFlags() throws {
        let setup = try PrivateCoachingSetup.parse(Data(Self.local.utf8))
        #expect(!setup.offersHosted)
        let arguments = try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .local,
                                            hostedConsentConfirmed: true)
        #expect(arguments.prefix(2) == ["coaching", "--parent-control"])
        #expect(!arguments.contains("--coaching-allow-hosted-text"))
        #expect(arguments.contains("7") && arguments.contains("9"))
        #expect(throws: PrivateCoachingSetup.SetupError.hostedNotConfigured) {
            try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .hosted, hostedConsentConfirmed: true)
        }
    }

    @Test func hostedArgumentsRequireConsent() throws {
        let setup = try PrivateCoachingSetup.parse(Data(Self.hosted.utf8))
        #expect(throws: PrivateCoachingSetup.SetupError.hostedConsentRequired) {
            try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .hosted, hostedConsentConfirmed: false)
        }
        let arguments = try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .hosted,
                                            hostedConsentConfirmed: true)
        #expect(arguments.suffix(7) == ["--coaching-provider", "jev", "--coaching-allow-hosted-text",
                                        "--coaching-max-requests", "12",
                                        "--coaching-advice-catalog", "/synthetic/catalog"])
        let local = try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .local,
                                        hostedConsentConfirmed: true)
        #expect(!local.contains("--coaching-allow-hosted-text"))
    }

    @Test func sameOrUnknownDevicesAreRefused() throws {
        let setup = try PrivateCoachingSetup.parse(Data(Self.local.utf8))
        #expect(throws: PrivateCoachingSetup.SetupError.invalid) {
            try setup.arguments(privateOutput: 7, roomMicrophone: 7, provider: .local, hostedConsentConfirmed: false)
        }
        #expect(throws: PrivateCoachingSetup.SetupError.invalid) {
            try setup.arguments(privateOutput: 0, roomMicrophone: 7, provider: .local, hostedConsentConfirmed: false)
        }
    }

    @Test func relativePathsBadListenersAndBudgetsAreRefused() {
        let bad = [
            Self.local.replacingOccurrences(of: "/synthetic/rightyo", with: "synthetic/rightyo"),
            Self.local.replacingOccurrences(of: "\"owner\"", with: "\"own\\ner\""),
            Self.hosted.replacingOccurrences(of: "12", with: "0"),
            Self.hosted.replacingOccurrences(of: "12", with: "101"),
            "{}", ""
        ]
        for text in bad {
            #expect(throws: PrivateCoachingSetup.SetupError.invalid) { try PrivateCoachingSetup.parse(Data(text.utf8)) }
        }
    }
}
