import Foundation

extension HostConnection {
    func clearSocketDiagnostics() {
        pendingPings.removeAll()
        snapshot.negotiatedVersion = nil
        snapshot.capabilities = []
        snapshot.lastPingMilliseconds = nil
        snapshot.targets = []
        snapshot.receivedTargetList = false
    }

    func scheduleNegotiationDeadline(token: UInt64, reconnectAttempt: Int) {
        cancelNegotiationDeadline()
        let deadlineID = negotiationDeadlineID
        negotiationStartedAt = monotonicNow()
        negotiationReconnectAttempt = reconnectAttempt
        // Generation and attempt checks make callbacks from replaced deadlines inert.
        negotiationScheduler(negotiationTimeout) { [weak self] in
            Task {
                await self?.negotiationTimedOut(
                    id: deadlineID, token: token, reconnectAttempt: reconnectAttempt
                )
            }
        }
    }

    func cancelNegotiationDeadline() {
        negotiationDeadlineID &+= 1
        negotiationStartedAt = nil
        negotiationReconnectAttempt = nil
    }

    func negotiationHasExpired() -> Bool {
        guard let negotiationStartedAt else { return false }
        return negotiationStartedAt.duration(to: monotonicNow()) >= negotiationTimeout
    }

    private func negotiationTimedOut(id: UInt64, token: UInt64, reconnectAttempt: Int) async {
        guard id == negotiationDeadlineID, isCurrent(token), wantsConnection,
              negotiationReconnectAttempt == reconnectAttempt else { return }
        negotiationStartedAt = nil
        negotiationReconnectAttempt = nil
        await replaceLoop(reconnectAttempt: reconnectAttempt)
    }
}

extension HostConnectionFailure {
    var description: String {
        switch self {
        case .malformed(let reason): reason
        case .incompatibleVersion: "no compatible Hail protocol version"
        case .remote(let reason): "host error: \(reason)"
        case .notReady: "host is not ready"
        case .unsupportedCapability(let capability): "host does not support \(capability)"
        }
    }
}
