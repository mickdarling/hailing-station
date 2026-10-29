#if os(macOS)
import Foundation
import HailProtocol

/// Content-free retraction identity; no target selection, input request, or permission is created by a cancel.
struct SessionUpdateCancellationReceipt: Sendable {
    let update: UUID
    let connection: UUID
    let privacyRevision: UInt64
    let frame: Frame

    init(update: UUID, connection: UUID, privacyRevision: UInt64, frame: Frame) {
        self.update = update; self.connection = connection; self.privacyRevision = privacyRevision
        self.frame = Frame(version: frame.version, timestamp: frame.timestamp, target: frame.target,
                           source: frame.source, payload: .control(.sessionUpdateCancel(update: update)))
    }
}

extension WebSocketListener {
    /// Quiet retracts all known proactive audio. A privacy entry retracts only identities admitted before that
    /// entry, so an asynchronously delivered old entry cannot cancel a newer public update after the owner's exit.
    func cancelProactiveSessionUpdateAudio(beforePrivacyRevision revision: UInt64? = nil) async {
        await refreshTaskProgressEnvironment()
        if revision != nil { purgePrivateSessionUpdates() }
        let receipts = sessionUpdateFence.cancelProactive(olderThan: revision)
        for receipt in receipts {
            guard let peer = peers.values.first(where: {
                $0.session.connectionID == receipt.connection
            }) else { continue }
            await peer.cancelSessionUpdate(receipt)
        }
    }
}

extension WebSocketPeer {
    func cancelSessionUpdate(_ receipt: SessionUpdateCancellationReceipt) async {
        guard !ended, receipt.connection == session.connectionID,
              await session.peerCapabilities.contains(SessionUpdateCard.audioCapability) else { return }
        // Retraction must work after policy/selection/privacy changes. It contains only the exact already-sent
        // identity, original target and host; it is never a generic stop_playback or publication fallback.
        _ = post(receipt.frame)
    }
}
#endif
