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
/// A player's ledger exists only while it has owners: it is removed once empty, so a closed scene's player and its
/// audio are never kept alive by this table (#763 review).
@MainActor
public enum CapturePlaybackSuppression {
    /// Each owner's check that its capture is still starting, recording, finalizing or interrupting.
    public static var liveness: [UUID: @MainActor () -> Bool] = [:]
    private static var ledgers: [ObjectIdentifier: CaptureSuppressionLedger] = [:]
    private static var reporters: [ObjectIdentifier: @MainActor (Int) -> Void] = [:]

    /// Whether `playback` has a ledger now; only a player with an outstanding hold does.
    static func hasLedger(for playback: ReplyPlaybackController) -> Bool { existing(playback) != nil }

    public static func begin(_ owner: UUID, using playback: ReplyPlaybackController) { ledger(playback).begin(owner) }

    /// Each call that can heal returns how many holds the heal dropped (#760), and tells that player's own reporter.
    @discardableResult
    public static func end(_ owner: UUID, using playback: ReplyPlaybackController, resuming: Bool) -> Int {
        liveness[owner] = nil
        guard let ledger = existing(playback) else { return 0 }
        let count = healed(ledger.end(owner, resuming: resuming), playback)
        pruneIfEmpty(playback)
        return count
    }

    public static func markCleanupComplete(_ owner: UUID, using playback: ReplyPlaybackController) {
        existing(playback)?.markCleanupComplete(owner)
    }

    /// On appearing and on scene activation: routine releases of completed teardowns, then any heal.
    @discardableResult
    public static func releaseCompleted(using playback: ReplyPlaybackController) -> Int {
        guard let ledger = existing(playback) else { return 0 }
        for owner in ledger.releaseCompleted() { liveness[owner] = nil }
        return reconcile(using: playback)
    }

    @discardableResult
    public static func reconcile(using playback: ReplyPlaybackController) -> Int {
        guard let ledger = existing(playback) else { return 0 }
        let count = healed(ledger.reconcile(), playback)
        pruneIfEmpty(playback)
        return count
    }

    /// Where `playback`'s heals are logged, set by its scene when it appears (nil removes it): a heal is reported only
    /// through its own scene. The reporter should hold its scene's state weakly, so this table keeps nothing alive.
    public static func reportHeals(for playback: ReplyPlaybackController, to reporter: (@MainActor (Int) -> Void)?) {
        reporters[ObjectIdentifier(playback)] = reporter
    }

    private static func existing(_ playback: ReplyPlaybackController) -> CaptureSuppressionLedger? {
        ledgers[ObjectIdentifier(playback)]
    }

    private static func pruneIfEmpty(_ playback: ReplyPlaybackController) {
        let key = ObjectIdentifier(playback)
        if ledgers[key]?.owners.isEmpty == true { ledgers[key] = nil }
    }

    private static func healed(_ owners: [UUID], _ playback: ReplyPlaybackController) -> Int {
        for owner in owners { liveness[owner] = nil }
        if !owners.isEmpty { reporters[ObjectIdentifier(playback)]?(owners.count) }
        return owners.count
    }

    private static func ledger(_ playback: ReplyPlaybackController) -> CaptureSuppressionLedger {
        let key = ObjectIdentifier(playback)
        if let ledger = ledgers[key] { return ledger }
        let ledger = CaptureSuppressionLedger(playback: playback) { liveness[$0]?() ?? false }
        ledgers[key] = ledger
        return ledger
    }
}
