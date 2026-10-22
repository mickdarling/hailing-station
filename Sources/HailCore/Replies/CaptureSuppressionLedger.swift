public import Foundation

/// Who holds reply playback's capture suppression (#91): replies are held while any owner's tap-to-talk capture
/// runs, and suppression ends only when no owner is left.
///
/// An owner whose capture is over must never keep replies held (#760). `isLive` answers, for an owner, whether its
/// capture is still starting, recording, finalizing or interrupting; an owner that never said counts as over. An
/// owner left behind with no live capture is dropped when another owner ends, and on `reconcile`, which the app runs
/// when the scene becomes active and when a reply arrives.
@MainActor
public final class CaptureSuppressionLedger {
    private struct Entry {
        var cleanupComplete = false
    }

    private let playback: ReplyPlaybackController
    private let isLive: @MainActor (UUID) -> Bool
    private var entries: [UUID: Entry] = [:]

    public init(playback: ReplyPlaybackController, isLive: @escaping @MainActor (UUID) -> Bool = { _ in false }) {
        self.playback = playback
        self.isLive = isLive
    }

    /// The owners holding suppression now.
    public var owners: Set<UUID> { Set(entries.keys) }

    /// Holds replies for `owner`'s capture. Beginning again re-arms an owner whose teardown had completed.
    public func begin(_ owner: UUID) {
        let wasEmpty = entries.isEmpty
        entries[owner] = Entry()
        if wasEmpty { playback.beginCaptureSuppression() }
    }

    /// Ends `owner`'s hold. Any other owner whose capture is no longer live is dropped with it, so a hold left
    /// behind cannot outlast the capture that did end. Returns those dropped owners.
    @discardableResult
    public func end(_ owner: UUID, resuming: Bool) -> [UUID] {
        guard entries.removeValue(forKey: owner) != nil else { return [] }
        let stale = dropOwners { !isLive($1) }
        if entries.isEmpty { playback.endCaptureSuppression(resumingPlayback: resuming) }
        return stale
    }

    /// `owner`'s capture was torn down while the scene was not active; `releaseCompleted` ends its hold.
    public func markCleanupComplete(_ owner: UUID) {
        entries[owner]?.cleanupComplete = true
    }

    /// The scene is active again: ends the holds of owners whose teardown completed and whose capture is not live.
    /// Returns those owners.
    @discardableResult
    public func releaseCompleted() -> [UUID] {
        let released = dropOwners { entry, owner in entry.cleanupComplete && !isLive(owner) }
        if !released.isEmpty, entries.isEmpty { playback.endCaptureSuppression(resumingPlayback: true) }
        return released
    }

    /// Self-heal (#760): drops every owner whose capture is no longer live, and resumes playback once none is left.
    /// An owner's explicit pause or mute still stands. Returns the dropped owners; empty when nothing was stale.
    @discardableResult
    public func reconcile() -> [UUID] {
        let stale = dropOwners { !isLive($1) }
        if !stale.isEmpty, entries.isEmpty { playback.endCaptureSuppression(resumingPlayback: true) }
        return stale
    }

    private func dropOwners(where shouldDrop: (Entry, UUID) -> Bool) -> [UUID] {
        let dropped = entries.filter { shouldDrop($0.value, $0.key) }.map(\.key)
        for owner in dropped { entries[owner] = nil }
        return dropped
    }
}

/// Reply playback's capture suppression (#91), one `CaptureSuppressionLedger` per player. Each capture owner registers
/// whether its capture is live, so a hold with no capture behind it is dropped instead of muting replies (#760).
@MainActor
public enum CapturePlaybackSuppression {
    /// Each owner's check that its capture is still starting, recording, finalizing or interrupting.
    public static var liveness: [UUID: @MainActor () -> Bool] = [:]
    /// Told how many holds a heal dropped, for the diagnostics log (#760).
    public static var onHeal: (@MainActor (Int) -> Void)?
    private static var ledgers: [ObjectIdentifier: CaptureSuppressionLedger] = [:]

    public static func begin(_ owner: UUID, using playback: ReplyPlaybackController) { ledger(playback).begin(owner) }

    public static func end(_ owner: UUID, using playback: ReplyPlaybackController, resuming: Bool) {
        liveness[owner] = nil
        healed(ledger(playback).end(owner, resuming: resuming))
    }

    public static func markCleanupComplete(_ owner: UUID, using playback: ReplyPlaybackController) {
        ledger(playback).markCleanupComplete(owner)
    }

    /// On appearing and on scene activation: routine releases of completed teardowns, then any heal.
    public static func releaseCompleted(using playback: ReplyPlaybackController) {
        for owner in ledger(playback).releaseCompleted() { liveness[owner] = nil }
        reconcile(using: playback)
    }

    public static func reconcile(using playback: ReplyPlaybackController) { healed(ledger(playback).reconcile()) }

    private static func healed(_ owners: [UUID]) {
        guard !owners.isEmpty else { return }
        for owner in owners { liveness[owner] = nil }
        onHeal?(owners.count)
    }

    private static func ledger(_ playback: ReplyPlaybackController) -> CaptureSuppressionLedger {
        let key = ObjectIdentifier(playback)
        if let ledger = ledgers[key] { return ledger }
        let ledger = CaptureSuppressionLedger(playback: playback) { liveness[$0]?() ?? false }
        ledgers[key] = ledger
        return ledger
    }
}
