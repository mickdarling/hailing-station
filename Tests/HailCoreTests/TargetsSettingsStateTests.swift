import Foundation
import HailProtocol
import Testing
@testable import HailCore

struct TargetsSettingsStateTests {
    @Test func currentIdentityNeedsTheRootConfirmationAndMatchingSavedSelection() throws {
        let host = try fixture()
        let selection = selection(for: host)
        let confirmed = TargetsSettingsConfirmation(selection: selection, generation: host.connectionGeneration)
        let current = TargetsSettingsState.resolve(
            hosts: [host], availability: .ready, confirmed: confirmed, remembered: selection)
        #expect(current.destination == .confirmed(DestinationLabel(
            hostName: "Example Mac", targetName: "build", targetKind: "tmux", targetID: "tmux:build")))
        #expect(current.destination.talkReady)
        let savedOnly = TargetsSettingsState.resolve(
            hosts: [host], availability: .ready, confirmed: nil, remembered: selection)
        #expect(!savedOnly.destination.talkReady)
        #expect(savedOnly.destination.primaryText == "Unavailable: not confirmed")
        let notRemembered = TargetsSettingsState.resolve(
            hosts: [host], availability: .ready, confirmed: confirmed, remembered: nil)
        #expect(!notRemembered.destination.talkReady)
    }

    @Test func reusedNamesCannotSurviveGenerationEndpointTargetNameOrLivenessChanges() throws {
        let original = try fixture()
        let selection = selection(for: original)
        let confirmed = TargetsSettingsConfirmation(selection: selection, generation: original.connectionGeneration)
        var changedGeneration = original
        changedGeneration.connectionGeneration = UUID()
        var changedURL = original
        changedURL.endpoint.url = try #require(URL(string: "ws://127.0.0.1:8766"))
        var renamed = original
        renamed.targets[0].name = "different session"
        var stopped = original
        stopped.targets[0].alive = false
        var notListed = original
        notListed.receivedTargetList = false
        for host in [changedGeneration, changedURL, renamed, stopped, notListed] {
            let state = TargetsSettingsState.resolve(
                hosts: [host], availability: .ready, confirmed: confirmed, remembered: selection)
            #expect(!state.destination.talkReady)
            #expect(state.remembered == selection, "Rendering cannot rewrite or adopt the saved identity")
            #expect(state.remembered?.targetName == "build")
        }
        let edited = TargetsSettingsState.resolve(
            hosts: [changedURL], availability: .offline, confirmed: confirmed, remembered: selection)
        #expect(!edited.savedHostMatches && edited.savedHostName == "Previously configured Mac")
    }

    @Test func hostDisplayRenameIsNotIdentityAndMatchingNamesOnAnotherMacDoNotConfirm() throws {
        let original = try fixture()
        let selection = selection(for: original)
        let confirmation = TargetsSettingsConfirmation(selection: selection, generation: original.connectionGeneration)
        var displayRename = original
        displayRename.endpoint.name = "Renamed Mac"
        let renamed = TargetsSettingsState.resolve(
            hosts: [displayRename], availability: .ready, confirmed: confirmation, remembered: selection)
        #expect(renamed.destination.talkReady)
        #expect(renamed.destination.secondaryText == "Mac · Renamed Mac")
        var other = original
        other.endpoint = try HostEndpoint(
            id: "other-mac", name: original.endpoint.name, url: original.endpoint.url)
        let different = TargetsSettingsState.resolve(
            hosts: [other], availability: .ready, confirmed: confirmation, remembered: selection)
        #expect(!different.destination.talkReady && !different.savedHostMatches)
    }

    @Test(arguments: [StationAvailability.offline, .connecting, .reconnecting, .restoringSelection,
                      .selectionFailed, .noAllowedTargets, .waitingForTargets])
    func unavailableAndRestoringStatesKeepTheSavedDestinationUnconfirmed(availability: StationAvailability) throws {
        let host = try fixture()
        let selection = selection(for: host)
        let state = TargetsSettingsState.resolve(
            hosts: [host], availability: availability,
            confirmed: TargetsSettingsConfirmation(selection: selection, generation: host.connectionGeneration),
            remembered: selection)
        #expect(!state.destination.talkReady)
        #expect(state.destination.secondaryText?.contains("Saved · not confirmed") == true)
        #expect(state.savedHostName == "Example Mac" && state.remembered == selection)
    }

    private func fixture() throws -> HostConnectionSnapshot {
        let endpoint = try HostEndpoint(
            id: "example-mac", name: "Example Mac", url: #require(URL(string: "ws://127.0.0.1:8765")))
        return HostConnectionSnapshot(endpoint: endpoint, state: .ready,
            targets: [TargetInfo(id: "tmux:build", kind: "tmux", name: "build", alive: true)], receivedTargetList: true)
    }

    private func selection(for host: HostConnectionSnapshot) -> DestinationSelection {
        DestinationSelection(hostID: host.id, hostURL: host.endpoint.url.absoluteString,
                             targetID: "tmux:build", targetName: "build")
    }
}
