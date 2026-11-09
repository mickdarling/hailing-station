import Testing
@testable import HailCore

@Suite("Destination control (#1115)")
struct DestinationControlStateTests {
    private let build = DestinationLabel(hostName: "Studio", targetName: "build", targetKind: "tmux", targetID: "%1")
    private let notes = DestinationLabel(hostName: "Studio", targetName: "notes", targetKind: "voice", targetID: "v-2")

    private func resolve(
        _ availability: StationAvailability, confirmed: DestinationLabel? = nil, remembered: DestinationLabel? = nil
    ) -> DestinationControlState {
        DestinationControlState.resolve(availability: availability, confirmed: confirmed, remembered: remembered)
    }

    @Test func aConfirmedDestinationOnAReadyStationIsCurrent() {
        let state = resolve(.ready, confirmed: build, remembered: build)
        #expect(state == .confirmed(build))
        #expect(state.talkReady)
        #expect(state.primaryText == "Terminal · build")
        #expect(state.secondaryText == "Mac · Studio")
        #expect(state.accessibilityValue == "Destination: Mac Studio, Terminal build.")
    }

    @Test func aConfirmedLabelIsNeverCurrentUnlessTheStationIsReady() {
        let notReady: [StationAvailability] = [
            .connecting, .reconnecting, .restoringSelection, .offline, .failed, .noAllowedTargets,
            .waitingForTargets, .selectionFailed, .unconfigured, .chooseTarget
        ]
        for availability in notReady {
            let state = resolve(availability, confirmed: build, remembered: build)
            #expect(!state.talkReady, "\(availability)")
            if case .confirmed = state { Issue.record("\(availability) resolved to confirmed") }
        }
    }

    @Test func readyWithoutAnOwnerConfirmationIsUnavailable() {
        let state = resolve(.ready, remembered: build)
        #expect(state == .unavailable(.unconfirmed, saved: build))
        #expect(!state.talkReady)
    }

    @Test func aRestoreShowsTheSavedSelectionAsNotCurrent() {
        let state = resolve(.restoringSelection, remembered: build)
        #expect(state == .confirming(saved: build))
        #expect(state.primaryText == "Confirming…")
        #expect(state.secondaryText == "Saved · not confirmed: Mac Studio, Terminal build")
    }

    @Test func aStaleConfirmedLabelIsShownOnlyAsSaved() {
        #expect(resolve(.reconnecting, confirmed: build) == .confirming(saved: build))
        // The owner's saved selection wins over a stale confirmed label.
        #expect(resolve(.offline, confirmed: build, remembered: notes) == .unavailable(.offline, saved: notes))
    }

    @Test func anOfflineConfiguredRouteStaysVisibleButUnavailable() {
        let state = resolve(.offline, remembered: notes)
        #expect(state.primaryText == "Unavailable: offline")
        #expect(state.secondaryText == "Saved · not confirmed: Mac Studio, Voice target notes")
        #expect(state.accessibilityValue
            == "Destination unavailable: offline. Saved, not confirmed: Mac Studio, Voice target notes.")
    }

    @Test func reasonsComeOnlyFromAvailability() {
        #expect(resolve(.failed) == .unavailable(.failed, saved: nil))
        #expect(resolve(.noAllowedTargets) == .unavailable(.noAllowedTargets, saved: nil))
        #expect(resolve(.waitingForTargets) == .unavailable(.waitingForTargets, saved: nil))
        #expect(resolve(.selectionFailed, remembered: build) == .unavailable(.selectionFailed, saved: build))
        #expect(resolve(.connecting) == .confirming(saved: nil))
    }

    @Test func nothingChosenAsksForADestination() {
        #expect(resolve(.chooseTarget) == .none)
        #expect(resolve(.unconfigured) == .none)
        #expect(DestinationControlState.none.primaryText == "Choose a destination")
        #expect(!DestinationControlState.none.talkReady)
    }

    // Jarvis, PR 3 plan: wherever a saved name appears outside a confirmed state, both the visible text and the
    // accessibility string say it is not confirmed, and the state leads.
    @Test func everySavedNameOutsideConfirmedSaysNotConfirmed() {
        let states: [DestinationControlState] = [
            .confirming(saved: build),
            .unavailable(.offline, saved: build), .unavailable(.failed, saved: build),
            .unavailable(.noAllowedTargets, saved: build), .unavailable(.waitingForTargets, saved: build),
            .unavailable(.selectionFailed, saved: build), .unavailable(.unconfirmed, saved: build)
        ]
        for state in states {
            #expect(!state.primaryText.contains(build.targetName), "\(state)")
            #expect(state.secondaryText?.contains("not confirmed") == true, "\(state)")
            #expect(state.secondaryText?.contains(build.summary) == true, "\(state)")
            #expect(state.accessibilityValue.contains("not confirmed: \(build.summary)"), "\(state)")
        }
    }

    @Test func withoutASavedNameThereIsNoSavedLine() {
        #expect(DestinationControlState.confirming(saved: nil).secondaryText == nil)
        #expect(DestinationControlState.unavailable(.offline, saved: nil).accessibilityValue
            == "Destination unavailable: offline.")
    }

    // Codex review of #1150: the one-line toolbar names the Mac, so the same target name on two Macs differs.
    @Test func theToolbarLineNamesTheMacOfAConfirmedDestination() {
        let other = DestinationLabel(hostName: "Laptop", targetName: "build", targetKind: "tmux", targetID: "%7")
        let studio = DestinationControlState.confirmed(build).singleLineText
        #expect(studio == "Terminal · build · Mac Studio")
        #expect(studio != DestinationControlState.confirmed(other).singleLineText)
        // Unconfirmed states keep their own line and never carry a saved name.
        #expect(DestinationControlState.confirming(saved: build).singleLineText == "Confirming…")
        #expect(DestinationControlState.unavailable(.offline, saved: build).singleLineText == "Unavailable: offline")
    }
}
