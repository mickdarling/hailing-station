/// A conservative, host-scoped summary for the mobile station's connection and destination state.
/// It does not infer that a sent message was delivered or that a reply belongs to that message.
public enum StationAvailability: Equatable, Sendable {
    case unconfigured
    case connecting
    case reconnecting
    case waitingForTargets
    case restoringSelection
    case chooseTarget
    case noAllowedTargets
    case selectionFailed
    case ready
    case failed
    case offline

    public static func resolve(
        hosts: [HostConnectionSnapshot],
        preferredHostID: HostEndpoint.Identifier?,
        selectionConfirmed: Bool,
        hasRememberedSelection: Bool,
        selectionInProgress: Bool
    ) -> Self {
        guard !hosts.isEmpty else { return .unconfigured }
        let relevant = preferredHostID.map { preferred in hosts.filter { $0.id == preferred } } ?? hosts
        guard !relevant.isEmpty else { return .offline }
        if selectionConfirmed, relevant.contains(where: { $0.state == .ready }) { return .ready }
        if relevant.contains(where: { $0.state == .ready }) {
            return readyState(
                relevant, hasRememberedSelection: hasRememberedSelection,
                selectionInProgress: selectionInProgress
            )
        }
        return connectionState(relevant)
    }

    private static func readyState(
        _ hosts: [HostConnectionSnapshot],
        hasRememberedSelection: Bool,
        selectionInProgress: Bool
    ) -> Self {
        let ready = hosts.filter { $0.state == .ready }
        let listed = ready.filter(\.receivedTargetList)
        let hasLiveTarget = listed.contains { $0.targets.contains(where: \.alive) }
        if !hasLiveTarget {
            let pending = hosts.filter { $0.state != .ready }
            if !pending.isEmpty {
                let state = connectionState(pending)
                if state == .connecting || state == .reconnecting { return state }
            }
            return listed.count == ready.count ? .noAllowedTargets : .waitingForTargets
        }
        if selectionInProgress { return .restoringSelection }
        return hasRememberedSelection ? .selectionFailed : .chooseTarget
    }

    private static func connectionState(_ hosts: [HostConnectionSnapshot]) -> Self {
        if hosts.contains(where: {
            if case .reconnecting = $0.state { return true }
            return false
        }) { return .reconnecting }
        if hosts.contains(where: {
            switch $0.state {
            case .connecting, .negotiating: true
            default: false
            }
        }) { return .connecting }
        if hosts.contains(where: {
            if case .failed = $0.state { return true }
            return false
        }) { return .failed }
        return .offline
    }
}
