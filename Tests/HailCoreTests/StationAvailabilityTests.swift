import Foundation
import HailCore
import HailProtocol
import Testing

@Suite struct StationAvailabilityTests {
    private func endpoint() throws -> HostEndpoint {
        try HostEndpoint(
            id: "preferred", name: "Test Mac",
            url: #require(URL(string: "ws://127.0.0.1:8765"))
        )
    }

    private func snapshot(
        _ state: HostConnectionState,
        receivedTargetList: Bool = false,
        targets: [TargetInfo] = []
    ) throws -> HostConnectionSnapshot {
        try HostConnectionSnapshot(
            endpoint: endpoint(), state: state, targets: targets,
            receivedTargetList: receivedTargetList
        )
    }

    private var liveTarget: TargetInfo {
        TargetInfo(id: "test:one", kind: "test", name: "one", alive: true)
    }

    private func resolve(
        _ hosts: [HostConnectionSnapshot],
        preferredHostID: String? = "preferred",
        selectionConfirmed: Bool = false,
        hasRememberedSelection: Bool = true,
        selectionInProgress: Bool = false
    ) -> StationAvailability {
        .resolve(
            hosts: hosts, preferredHostID: preferredHostID,
            selectionConfirmed: selectionConfirmed,
            hasRememberedSelection: hasRememberedSelection,
            selectionInProgress: selectionInProgress
        )
    }

    @Test func reconnectingAndFailureReplaceStaleReady() throws {
        #expect(resolve([]) == .unconfigured)
        #expect(resolve([try snapshot(.connecting)]) == .connecting)
        #expect(resolve([try snapshot(.negotiating)]) == .connecting)
        #expect(resolve([try snapshot(.reconnecting(attempt: 2, nextDelay: 1))]) == .reconnecting)
        #expect(resolve([try snapshot(.failed(reason: "unavailable"))]) == .failed)
        #expect(resolve([try snapshot(.disconnected)]) == .offline)
        #expect(resolve([try snapshot(.failed(reason: "unavailable"))], selectionConfirmed: true) == .failed)
    }

    @Test func targetCatalogAndSelectionHaveSeparateStates() throws {
        #expect(resolve([try snapshot(.ready)]) == .waitingForTargets)
        #expect(resolve([try snapshot(.ready, receivedTargetList: true)]) == .noAllowedTargets)
        let listed = try snapshot(.ready, receivedTargetList: true, targets: [liveTarget])
        #expect(resolve([listed], selectionInProgress: true) == .restoringSelection)
        #expect(resolve([listed]) == .selectionFailed)
        #expect(resolve([listed], hasRememberedSelection: false) == .chooseTarget)
        #expect(resolve([listed], selectionConfirmed: true) == .ready)
    }

    @Test func unrelatedReadyHostCannotMaskPreferredHostFailure() throws {
        let other = try HostEndpoint(
            id: "other", name: "Other Mac", url: #require(URL(string: "ws://127.0.0.1:8766"))
        )
        let otherReady = HostConnectionSnapshot(
            endpoint: other, state: .ready, targets: [liveTarget], receivedTargetList: true
        )
        #expect(resolve([try snapshot(.failed(reason: "unavailable")), otherReady]) == .failed)
        #expect(resolve([otherReady]) == .offline)
        #expect(resolve([otherReady], preferredHostID: nil, hasRememberedSelection: false) == .chooseTarget)
    }

    @Test func waitsForEveryReadyHostsCatalogUnlessOneAlreadyHasALiveTarget() throws {
        let other = try HostEndpoint(
            id: "other", name: "Other Mac", url: #require(URL(string: "ws://127.0.0.1:8766"))
        )
        let empty = try snapshot(.ready, receivedTargetList: true)
        let pending = HostConnectionSnapshot(endpoint: other, state: .ready)
        #expect(resolve([empty, pending], preferredHostID: nil, hasRememberedSelection: false) == .waitingForTargets)
        let live = HostConnectionSnapshot(
            endpoint: other, state: .ready, targets: [liveTarget], receivedTargetList: true
        )
        #expect(resolve([empty, live], preferredHostID: nil, hasRememberedSelection: false) == .chooseTarget)
        #expect(resolve([try snapshot(.ready), live],
                        preferredHostID: nil, hasRememberedSelection: false) == .chooseTarget)
    }
}
