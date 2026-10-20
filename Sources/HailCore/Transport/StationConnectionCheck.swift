public import Foundation

/// The visible result of the station's "Check Mac connection" button (#385). The check reconnects the Mac now
/// instead of waiting out its backoff, then reports what it found; it never leaves the button looking inert.
public enum StationConnectionCheck: Equatable, Sendable {
    case checking
    case connected(host: String)
    case noDestinations(host: String)
    case failed(host: String, reason: String)
    case unreachable(host: String)
    /// Disconnected on purpose in Mac Setup: the check leaves it that way rather than reconnecting it.
    case disconnected(host: String)

    /// How long the station waits for a reconnect before it reports the Mac as unreachable.
    public static let timeout: Duration = .seconds(10)

    /// The result for one host, or nil while it is still connecting and the check has time left. A failure from
    /// a new connection attempt is final at once; one left over from before the check (`staleGeneration`) is not.
    /// A host still connecting or retrying when the time runs out is reported unreachable.
    public static func outcome(
        for host: HostConnectionSnapshot?, staleGeneration: UUID? = nil, timedOut: Bool
    ) -> Self? {
        guard let host else { return timedOut ? .unreachable(host: "The Mac") : nil }
        let name = host.endpoint.name
        switch host.state {
        case .ready where host.receivedTargetList:
            return host.targets.contains(where: \.alive) ? .connected(host: name) : .noDestinations(host: name)
        case .failed(let reason) where host.connectionGeneration != staleGeneration || timedOut:
            return .failed(host: name, reason: reason)
        case .disconnected:
            return .disconnected(host: name)
        default:
            return timedOut ? .unreachable(host: name) : nil
        }
    }

    /// The first host that connected wins; otherwise the most useful problem, so one bad Mac among several does
    /// not hide a working one.
    public static func outcome(
        for hosts: [HostConnectionSnapshot], staleGenerations: [HostEndpoint.Identifier: UUID] = [:], timedOut: Bool
    ) -> Self? {
        guard !hosts.isEmpty else { return outcome(for: nil, timedOut: timedOut) }
        let results = hosts.map { outcome(for: $0, staleGeneration: staleGenerations[$0.id], timedOut: timedOut) }
        if let connected = results.first(where: { if case .connected = $0 { true } else { false } }) {
            return connected
        }
        // Wait for every host before reporting a problem: a slower Mac may still connect.
        guard results.allSatisfy({ $0 != nil }) else { return nil }
        return results.compactMap { $0 }.min { $0.rank < $1.rank }
    }

    /// Polls `hosts` until they give an outcome or `timeout` passes. Nil when the check is cancelled first (the view
    /// went away), so the caller goes back to idle instead of showing progress forever.
    @MainActor
    public static func wait(
        for hosts: @MainActor () -> [HostConnectionSnapshot], staleGenerations: [HostEndpoint.Identifier: UUID],
        timeout: Duration = timeout, interval: Duration = .milliseconds(250)
    ) async -> Self? {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            let timedOut = ContinuousClock.now >= deadline
            if let outcome = outcome(for: hosts(), staleGenerations: staleGenerations, timedOut: timedOut) {
                return outcome
            }
            try? await Task.sleep(for: interval)
        }
        return nil
    }

    public var message: String {
        switch self {
        case .checking: "Checking the Mac connection…"
        case .connected(let host): "\(host) is connected."
        case .noDestinations(let host): "\(host) is connected but has no live destination you can use."
        case .failed(let host, let reason): "\(host) could not connect: \(reason)"
        case .unreachable(let host):
            "\(host) did not answer. Check that it is awake, on this network and running Hailing Station."
        case .disconnected(let host): "\(host) is disconnected. Connect it in Mac Setup."
        }
    }

    public var isProblem: Bool {
        switch self {
        case .checking, .connected: false
        case .noDestinations, .failed, .unreachable, .disconnected: true
        }
    }

    private var rank: Int {
        switch self {
        case .connected: 0
        case .noDestinations: 1
        case .failed: 2
        case .unreachable: 3
        case .disconnected: 4
        case .checking: 5
        }
    }
}
