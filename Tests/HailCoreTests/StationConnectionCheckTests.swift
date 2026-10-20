import Foundation
import HailCore
import HailProtocol
import Testing

@Suite struct StationConnectionCheckTests {
    private func snapshot(
        _ state: HostConnectionState, id: String = "one", name: String = "Test Mac",
        generation: UUID = UUID(), receivedTargetList: Bool = false, targets: [TargetInfo] = []
    ) throws -> HostConnectionSnapshot {
        try HostConnectionSnapshot(
            endpoint: HostEndpoint(id: id, name: name, url: #require(URL(string: "ws://127.0.0.1:8765"))),
            connectionGeneration: generation, state: state, targets: targets, receivedTargetList: receivedTargetList
        )
    }

    private let live = TargetInfo(id: "test:one", kind: "test", name: "one", alive: true)
    private let dead = TargetInfo(id: "test:two", kind: "test", name: "two", alive: false)

    @Test func connectingHostIsPendingUntilTheTimeoutThenUnreachable() throws {
        for state: HostConnectionState in [.connecting, .negotiating, .disconnected,
                                           .reconnecting(attempt: 2, nextDelay: 1), .ready] {
            let host = try snapshot(state)
            #expect(StationConnectionCheck.outcome(for: host, timedOut: false) == nil)
            #expect(StationConnectionCheck.outcome(for: host, timedOut: true) == .unreachable(host: "Test Mac"))
        }
    }

    @Test func readyHostReportsWhetherItHasALiveDestination() throws {
        let usable = try snapshot(.ready, receivedTargetList: true, targets: [dead, live])
        #expect(StationConnectionCheck.outcome(for: usable, timedOut: false) == .connected(host: "Test Mac"))
        let empty = try snapshot(.ready, receivedTargetList: true, targets: [dead])
        #expect(StationConnectionCheck.outcome(for: empty, timedOut: false) == .noDestinations(host: "Test Mac"))
    }

    /// A failure left from before the check is not its result; one from the check's own attempt is, at once.
    @Test func onlyAFreshFailureEndsTheCheckEarly() throws {
        let before = UUID()
        let stale = try snapshot(.failed(reason: "refused"), generation: before)
        #expect(StationConnectionCheck.outcome(for: stale, staleGeneration: before, timedOut: false) == nil)
        #expect(StationConnectionCheck.outcome(for: stale, staleGeneration: before, timedOut: true)
            == .failed(host: "Test Mac", reason: "refused"))
        let fresh = try snapshot(.failed(reason: "refused"))
        #expect(StationConnectionCheck.outcome(for: fresh, staleGeneration: before, timedOut: false)
            == .failed(host: "Test Mac", reason: "refused"))
    }

    @Test func severalMacsReportTheFirstConnectedOrWaitForAll() throws {
        let failed = try snapshot(.failed(reason: "refused"), id: "a", name: "Mac A")
        let pending = try snapshot(.connecting, id: "b", name: "Mac B")
        let ready = try snapshot(.ready, id: "b", name: "Mac B", receivedTargetList: true, targets: [live])
        #expect(StationConnectionCheck.outcome(for: [failed, pending], timedOut: false) == nil)
        #expect(StationConnectionCheck.outcome(for: [failed, ready], timedOut: false) == .connected(host: "Mac B"))
        #expect(StationConnectionCheck.outcome(for: [failed, pending], timedOut: true)
            == .failed(host: "Mac A", reason: "refused"))
        #expect(StationConnectionCheck.outcome(for: [], timedOut: false) == nil)
        #expect(StationConnectionCheck.outcome(for: [], timedOut: true) == .unreachable(host: "The Mac"))
    }

    @Test func everyResultHasAVisibleMessage() {
        let results: [StationConnectionCheck] = [
            .checking, .connected(host: "M"), .noDestinations(host: "M"),
            .failed(host: "M", reason: "r"), .unreachable(host: "M")
        ]
        for result in results { #expect(!result.message.isEmpty) }
        #expect(results.map(\.isProblem) == [false, false, true, true, true])
    }
}
