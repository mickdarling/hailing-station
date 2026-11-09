import Testing
@testable import HailCore

/// The recovery sheet's promises over every combination of its inputs (#1115).
@Suite("Recovery sheet sweep (#1115)")
struct RecoverySheetSweepTests {
    private typealias Fixture = RecoveryFixtures
    private static let availabilities: [StationAvailability] = [
        .unconfigured, .connecting, .reconnecting, .waitingForTargets, .restoringSelection, .chooseTarget,
        .noAllowedTargets, .selectionFailed, .ready, .failed, .offline
    ]
    private static let destinations: [DestinationControlState] = [
        Fixture.confirmed, .confirming(saved: nil), .unavailable(.waitingForTargets, saved: nil),
        .unavailable(.offline, saved: Fixture.build), .unavailable(.unconfirmed, saved: nil), .none
    ]
    private static let privacies: [RailPrivacy?] = [
        nil, .unsupported, Fixture.privacy(on: true), Fixture.privacy(on: false), Fixture.unconfirmed,
        Fixture.privacy(on: true, requested: true), Fixture.privacy(on: true, stopped: true)
    ]
    private static let listenings: [StationMenuStatus.Listening?] = [
        nil, .off, .starting, .listening, .paused, .elsewhere
    ]
    private static let turns: [TurnOutcome?] = [
        nil, .sending, .waitingForReply, .noReplyYet, .sentUnverified, .replyReceived,
        .notSent(reason: "Destination changed"), .refused(reason: "Input holds unsent text")
    ]
    private static let forbidden = ["retry", "resend", "restart", "flush", "done", "completed", "everything is fine"]

    // 11 availabilities × 6 destinations × 7 privacies × 6 listening × 2 was-on × 8 turns.
    @Test func everyCombinationKeepsTheSheetsPromises() {
        var count = 0
        for availability in Self.availabilities {
            for destination in Self.destinations {
                for privacy in Self.privacies {
                    for listening in Self.listenings {
                        for wasOn in [false, true] {
                            for turn in Self.turns {
                                count += 1
                                let state = Fixture.resolve(availability, destination: destination, privacy: privacy,
                                                            listening: listening, wasListening: wasOn, turn: turn)
                                checkSteps(state, privacy: privacy)
                                checkRequest(state, turn: turn)
                            }
                        }
                    }
                }
            }
        }
        #expect(count == 44_352)
    }

    private func checkSteps(_ state: RecoverySheetState, privacy: RailPrivacy?) {
        let item = "\(state.header) \(String(describing: privacy))"
        let applicable = state.steps.filter { $0.state != .notApplicable }
        if state.isRestored { #expect(applicable.allSatisfy { $0.state == .confirmed }, "\(item)") }
        if applicable.contains(where: { $0.state == .failed }) { #expect(state.header == "Needs attention") }
        // Privacy that is unknown, pending, unconfirmed or unavailable is never confirmed, and only confirmed
        // privacy reads as private.
        let mode = state.steps[2]
        if case .status(let status)? = privacy, status.pending || status.shown == .unconfirmed
            || status.shown == .privateListeningUnavailable {
            #expect(mode.state != .confirmed, "\(item)")
        }
        if privacy == nil { #expect(mode.state != .confirmed, "\(item)") }
        if mode.text.localizedCaseInsensitiveContains("private") {
            #expect(privacy == Fixture.privacy(on: true), "\(item)")
        }
        #expect(state.intents.first == .inspectConnection, "\(item)")
        #expect(state.intents.contains(.chooseDestination) == (state.steps[1].state != .confirmed), "\(item)")
        let listeningLapsed = state.steps[3].state == .waiting || state.steps[3].state == .failed
        #expect(state.intents.contains(.openListening) == listeningLapsed, "\(item)")
    }

    private func checkRequest(_ state: RecoverySheetState, turn: TurnOutcome?) {
        let item = "\(String(describing: turn)) \(state.header)"
        // Jarvis, PR 7 plan: a request that may have left the device never says it wasn't sent.
        switch turn {
        case .sending?, .waitingForReply?, .noReplyYet?, .sentUnverified?, .replyReceived?, .refused?:
            #expect(state.request?.contains("Nothing was sent") == false, "\(item)")
            #expect(state.request?.localizedCaseInsensitiveContains("not sent") == false, "\(item)")
        case .notSent?:
            #expect(state.request?.hasPrefix("Nothing was sent") == true, "\(item)")
        case nil:
            #expect(state.request == nil, "\(item)")
        }
        // A request in doubt or in flight is never all-clear.
        if turn != nil, turn != .replyReceived { #expect(!state.isRestored, "\(item)") }
        let text = [state.header, state.request, state.nextStep].compactMap { $0 }
            + state.steps.map(\.text)
        for word in Self.forbidden {
            #expect(!text.contains { $0.localizedCaseInsensitiveContains(word) }, "\(word): \(item)")
        }
    }
}
