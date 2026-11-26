import AVFAudio
import SwiftUI
import Testing
@testable import HailCore

@Suite("Station on-air listening bar (#1399)")
struct StationListeningBarTests {
    @Test func everyListeningAndDockPhaseSelectsItsOwnCapture() {
        for listening in RailFixtures.listenings {
            let ambient: StationListeningCapture = switch listening {
            case .listening?: .ambient
            case .off?, .starting?, .paused?, .elsewhere?, nil: .inactive
            }
            for talk in RailFixtures.talks {
                let expected: StationListeningCapture = switch talk {
                case .idle?: ambient
                case .recording?: .talk
                case .starting?, .finishing?, nil: .inactive
                }
                #expect(StationListeningCapture(listening: listening, talk: talk) == expected)
            }
        }
    }

    @Test(arguments: StationListeningCapture.allCases)
    func onlyAnActiveOwnerWithARunningEngineIsOnAir(_ source: StationListeningCapture) {
        let rail = RailFixtures.resolve(mic: .live, privacy: RailFixtures.notPrivate)
        for engine: MicEngineState in [.unknown, .stopped, .running] {
            let expected: ListeningBarStyle = switch engine {
            case .unknown, .stopped: .standard
            case .running:
                switch source {
                case .ambient, .talk: .onAir
                case .inactive: .standard
                }
            }
            #expect(source.barStyle(engine: engine, rail: rail, privacy: RailFixtures.notPrivate) == expected)
        }
    }

    @Test(arguments: StationListeningCapture.allCases)
    func aRunningEngineStillNeedsReadyNonPrivateCapture(_ source: StationListeningCapture) {
        let listening: StationMenuStatus.Listening = source == .ambient ? .listening : .off
        let talk: TalkCapturePhase = source == .talk ? .recording : .idle
        for item in RailFixtures.everyCase where item.mic == .live && item.listening == listening && item.talk == talk {
            let host = item.host
            let style = source.barStyle(engine: .running, rail: item.state, privacy: host.privacy)
            let nonPrivate = host.privacy == .unsupported || host.privacy == RailFixtures.notPrivate
            let local = switch host.handoff {
            case .movedAway?: false
            case .movedHere?, nil: true
            }
            let allowed = source != .inactive && nonPrivate && local && hostIsReady(host.availability)
                && host.connection == nil
            #expect(style == (allowed ? .onAir : .standard), "\(item)")
        }
    }

    private func hostIsReady(_ availability: StationAvailability) -> Bool {
        switch availability {
        case .ready: true
        case .unconfigured, .connecting, .reconnecting, .waitingForTargets, .restoringSelection, .chooseTarget,
             .noAllowedTargets, .selectionFailed, .failed, .offline: false
        }
    }

    @Test func noEngineClaimCanPromoteAnUncertainRail() {
        let rail = RailFixtures.resolve(mic: .uncertain, privacy: RailFixtures.notPrivate)
        #expect(rail.kind == .mayBeRecording)
        #expect(StationListeningCapture.ambient.barStyle(engine: .running, rail: rail,
                                                        privacy: RailFixtures.notPrivate) == .standard)
    }

    @MainActor @Test func nativeEngineEvidenceIsWindowScopedAndStopsWithTheInputTap() throws {
        let fake = FakeEngineOperations()
        let input = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                         operations: fake.operations)
        let guarder = AmbientReplyEchoGuard()
        let otherWindow = AmbientReplyEchoGuard()
        let masked = guarder.masking(input)
        let admission = AudioCaptureAdmission()
        #expect(guarder.ambientInputEngineState == .unknown)
        #expect(input.inputEngineState == .stopped)
        let stream = try AudioCaptureAdmission.$current.withValue(admission) { try masked.start() }
        defer { withExtendedLifetime(stream) {} }
        #expect(guarder.ambientInputEngineState == .running)
        #expect(otherWindow.ambientInputEngineState == .unknown)
        admission.setPaused(true)
        #expect(guarder.ambientInputEngineState == .unknown)
        admission.setPaused(false)
        fake.running = false
        #expect(guarder.ambientInputEngineState == .stopped)
        masked.stop()
        fake.running = true
        #expect(input.inputEngineState == .stopped)
        #expect(guarder.ambientInputEngineState == .stopped)
    }

    @MainActor @Test func replacementWithoutEngineEvidenceCannotBorrowAPreviousRunningInput() throws {
        let guarder = AmbientReplyEchoGuard()
        let fake = FakeEngineOperations()
        let input = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                         operations: fake.operations)
        let first = guarder.masking(input)
        let firstStream = try first.start()
        defer { first.stop(); withExtendedLifetime(firstStream) {} }
        let replacement = guarder.masking(FakeAudioCapture())
        let nextStream = try replacement.start()
        defer { replacement.stop(); withExtendedLifetime(nextStream) {} }
        #expect(input.inputEngineState == .running)
        #expect(guarder.ambientInputEngineState == .unknown)
    }

    @Test @MainActor func onAirColorsHaveTextAndControlContrastInBothAppearances() {
        let colors = ListeningBarStyle.onAirColors
        for scheme: ColorScheme in [.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            func luminance(_ color: Color) -> Double {
                let rgb = color.resolve(in: environment)
                return 0.2126 * Double(rgb.linearRed) + 0.7152 * Double(rgb.linearGreen)
                    + 0.0722 * Double(rgb.linearBlue)
            }
            let bar = luminance(colors.fill)
            let canvas = luminance(environment.stationPalette[.elevatedSurface])
            #expect((luminance(colors.ink) + 0.05) / (bar + 0.05) >= 4.5)
            #expect((max(canvas, bar) + 0.05) / (min(canvas, bar) + 0.05) >= 3)
        }
    }
}

extension StationListeningBarTests {
    private var handedOffHost: RailHost {
        let handoff = AmbientHandoff.movedAway(to: "pad")
        return RailHost(privacy: RailFixtures.notPrivate, handoff: handoff, availability: .ready,
                        connection: .stopped(reason: handoff.status))
    }

    @MainActor @Test func ambientElsewhereWithLocalTalkRecordingIsOnAir() {
        let rail = StationListeningRail(listening: .elsewhere, talk: .recording, host: handedOffHost)
        #expect(rail.capture == .talk)
        let (state, style) = rail.presentation(engine: .running)
        #expect(state.kind == .recording)
        #expect(style == .onAir)
        let view = ListeningPrivacyRailView(state: state, isDetailPresented: .constant(false), barStyle: style)
        #expect(view.spokenSummary == "Recording, on air")
        for engine: MicEngineState in [.unknown, .stopped] {
            #expect(rail.presentation(engine: engine).style == .standard)
        }
    }

    @MainActor @Test func ambientElsewhereWithIdleTalkStaysOffAir() {
        let rail = StationListeningRail(listening: .elsewhere, talk: .idle, host: handedOffHost)
        #expect(rail.capture == .inactive)
        for engine: MicEngineState in [.running, .unknown, .stopped] {
            let (state, style) = rail.presentation(engine: engine)
            #expect(style == .standard)
            let view = ListeningPrivacyRailView(state: state, isDetailPresented: .constant(false), barStyle: style)
            #expect(!view.spokenSummary.contains("on air"))
        }
    }

    @Test func localTalkAfterHandoffStillRequiresReadyNonPrivateCapture() {
        for availability in RailFixtures.availabilities {
            for privacy in RailFixtures.privacies {
                var host = handedOffHost
                host.availability = availability
                host.privacy = privacy
                let rail = StationListeningRail(listening: .elsewhere, talk: .recording, host: host)
                let nonPrivate = privacy == .unsupported || privacy == RailFixtures.notPrivate
                let allowed = hostIsReady(availability) && nonPrivate
                #expect(rail.presentation(engine: .running).style == (allowed ? .onAir : .standard))
            }
        }
        var host = handedOffHost
        host.connection = .reconnecting
        let reconnecting = StationListeningRail(listening: .elsewhere, talk: .recording, host: host)
        #expect(reconnecting.presentation(engine: .running).style == .standard)
    }

    @MainActor @Test func pausedAndMayBeRecordingKeepTheirAlertBackground() {
        let paused = RailFixtures.resolve(mic: .uncertain, listening: .paused, privacy: RailFixtures.notPrivate)
        let uncertain = RailFixtures.resolve(mic: .live, privacy: RailFixtures.pending)
        #expect(paused.kind == .paused)
        #expect(uncertain.kind == .mayBeRecording)
        for state in [paused, uncertain] {
            let view = ListeningPrivacyRailView(state: state, isDetailPresented: .constant(false))
            for scheme: ColorScheme in [.light, .dark] {
                let palette = StationPalette(theme: .astra, scheme: scheme)
                #expect(view.colors(in: palette).fill == palette[.alertSurface])
            }
        }
    }
}
