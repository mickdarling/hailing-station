import Testing
@testable import HailCore

/// The voice dock's promises over every combination of its inputs (#1115).
@Suite("Voice dock sweep (#1115)")
struct VoiceDockSweepTests {
    private static let build = DestinationLabel(
        hostName: "Studio", targetName: "build", targetKind: "tmux", targetID: "%1")
    private static let destinations: [DestinationControlState] = [
        .confirmed(build), .confirming(saved: nil), .confirming(saved: build), .unavailable(.offline, saved: build),
        .unavailable(.unconfirmed, saved: nil), .unavailable(.selectionFailed, saved: build), .none
    ]
    private static let phases: [TalkCapturePhase?] = [nil, .idle, .starting, .recording, .finishing]
    private static let activities: [TalkActivity] = phases.flatMap { phase in
        [false, true].flatMap { pending in
            [false, true].map { TalkActivity(phase: phase, sendPending: pending, interrupting: $0) }
        }
    }
    private static let accessories: [DockAccessories] = [false, true].flatMap { escape in
        [false, true].flatMap { privacy in
            [false, true].map { DockAccessories(escape: escape, privacy: privacy, paste: $0) }
        }
    }

    // Jarvis, PR 5 plan: 5 phases × 2 pending × 2 interrupting × 7 destinations × 8 accessory sets.
    @Test func everyCombinationKeepsTheDocksPromises() {
        var count = 0
        for talk in Self.activities {
            for destination in Self.destinations {
                for offered in Self.accessories {
                    count += 1
                    let state = VoiceDockState.resolve(talk: talk, destination: destination, accessories: offered)
                    checkPrimary(state, talk: talk, destination: destination)
                    checkSecondary(state, talk: talk, offered: offered)
                }
            }
        }
        #expect(count == 1_120)
    }

    private func checkPrimary(_ state: VoiceDockState, talk: TalkActivity, destination: DestinationControlState) {
        let item = "\(talk) \(destination)"
        if state.primaryIntent == .talk {
            #expect(talk.phase == .idle && destination.talkReady && !talk.sendPending && !talk.interrupting,
                    "\(item)")
        }
        // Recording never traps the microphone open. Only an Escape under way, which is already stopping and
        // discarding the capture, disables Finish.
        if talk.phase == .recording {
            #expect(state.primaryIntent == (talk.interrupting ? nil : VoiceDockIntent.finish), "\(item)")
            if talk.interrupting { #expect(state.primary == .interrupting, "\(item)") }
        }
        if state.primaryIntent == .finish { #expect(talk.phase == .recording, "\(item)") }
        if state.label.localizedCaseInsensitiveContains("send") { #expect(destination.talkReady, "\(item)") }
        if talk.phase == nil { #expect(!state.isEnabled, "\(item)") }
        if !state.isEnabled { #expect(state.primaryIntent == nil, "\(item)") }
        #expect(state.showsCaption == [.starting, .recording, .finishing].contains(talk.phase), "\(item)")
    }

    private func checkSecondary(_ state: VoiceDockState, talk: TalkActivity, offered: DockAccessories) {
        let item = "\(talk) \(offered)"
        // Escape comes only from its owner. It is disabled only while finishing or while an Escape is under way,
        // so an unknown or recording talk phase always keeps it (Jarvis, PR 5 plan).
        if offered.escape {
            let busy = talk.phase == .finishing || talk.interrupting
            #expect(state.escape == (busy ? .disabled : .enabled), "\(item)")
        } else {
            #expect(state.escape == .hidden, "\(item)")
        }
        #expect((state.privacy == .hidden) == !offered.privacy, "\(item)")
        #expect((state.paste == .hidden) == !offered.paste, "\(item)")
        // Paste is disabled while a request is pending, as the owner's paste button is.
        if offered.paste { #expect((state.paste == .enabled) == !talk.sendPending, "\(item)") }
    }
}
