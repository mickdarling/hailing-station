#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #909 review rounds 2 and 3: each check on "Nothing was sent." on its own. The connection's privacy clip chain is
/// held by a latch piece, so the clip is queued at one moment and plays at another; the router's test-only
/// `notSentQueued` hook says when it is queued, so privacy changes at a known point, never after a pause. Privacy is
/// set in the router's state directly, as an entry a child took would. And a connection torn down before its notice
/// gets no clip and leaves no privacy clip chain behind, by either guard on its own. Synthetic only. Named
/// `AmbientWiring…` so it runs in the serial timing lane.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringNotSentGateTests {
    static let suppressed = "reason=inputPending shown=sent confirm=suppressed_privacy"
    static let shown = Array(AmbientWiringInputPendingTests.told.prefix(3))

    /// Queued while not private, privacy on before it plays: the check when it would play suppresses it.
    @Test func privacyTakenAfterTheClipIsQueuedIsCaughtWhenItWouldPlay() async throws {
        let run = try await PendingInputRun.make()
        defer { run.close() }
        let latch = MeetingLatch()
        defer { latch.open() }
        let connection = try #require(await run.connection)
        run.holdClipChain(connection, until: latch)
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(try await run.seen(3) == Self.shown)
        // Queued, not private, behind the latch.
        #expect(await eventually { run.queued.count(for: connection) == 1 })
        run.setPrivate(true, connection)
        latch.open()
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.suppressed] })
        try await barrier(on: run.socket, step: "no clip once private")
        await run.finish()
    }

    /// Queued while private, privacy off before it plays: the check when it was queued has already suppressed it, so
    /// no "Nothing was sent." follows the privacy that was on when it was decided.
    @Test func aClipQueuedWhilePrivateStaysSuppressedAfterPrivacyEnds() async throws {
        let run = try await PendingInputRun.make()
        defer { run.close() }
        let latch = MeetingLatch()
        defer { latch.open() }
        let connection = try #require(await run.connection)
        run.holdClipChain(connection, until: latch)
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        await run.adapter.holdHandoff()
        try await run.speak()
        await run.adapter.waitForHandoff()
        run.setPrivate(true, connection)
        await run.adapter.releaseHandoff()
        #expect(try await run.seen(3) == Self.shown)
        // Queued, private, behind the latch.
        #expect(await eventually { run.queued.count(for: connection) == 1 })
        run.setPrivate(false, connection)
        latch.open()
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.suppressed] })
        try await barrier(on: run.socket, step: "no clip after privacy ended")
        await run.finish()
    }

    /// The device drops while the notice waits for its acknowledgement: no line, no clip, and no privacy clip chain is
    /// made again for the connection `stop(connection:)` already cleared. The notice is released only once the run has
    /// ended and its teardown mark is pruned, so the line's `no_connection` alone must stop the clip.
    @Test func aConnectionGoneBeforeItsNoticeGetsNoClipAndLeavesNoChain() async throws {
        let latch = MeetingLatch()
        defer { latch.open() }
        let run = try await PendingInputRun.make(hold: AcknowledgementHold { await latch.wait() })
        defer { run.close() }
        let connection = try #require(await run.connection)
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(await eventually { await run.adapter.contexts.count == 1 })
        run.pair.close()
        #expect(await eventually { await run.env.listener.peers.isEmpty })
        #expect(await eventually { run.env.router.state.withLock { !$0.closed.contains(connection) } })
        latch.open()
        let gone = "reason=inputPending shown=no_connection confirm=no_connection"
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [gone] })
        #expect(run.env.router.state.withLock { $0.privacyClips[connection] == nil })
        #expect(run.queued.count(for: connection) == 0)
        await run.finish()
    }

    /// The connection is torn down after the line is shown but before the clip is queued: the teardown mark
    /// (`closed`) alone stops the clip, and no privacy clip chain is made for it. The mark is set in the router's state
    /// directly while the device is still connected, which is how that window looks to the notice.
    @Test func aConnectionMarkedClosedAfterItsLineGetsNoClipAndNoChain() async throws {
        let run = try await PendingInputRun.make()
        defer { run.close() }
        let connection = try #require(await run.connection)
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        await run.adapter.holdHandoff()
        try await run.speak()
        await run.adapter.waitForHandoff()
        _ = run.env.router.state.withLock { $0.closed.insert(connection) }
        await run.adapter.releaseHandoff()
        #expect(try await run.seen(3) == Self.shown)
        let closed = "reason=inputPending shown=sent confirm=no_connection"
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [closed] })
        #expect(run.env.router.state.withLock { $0.privacyClips[connection] == nil })
        #expect(run.queued.count(for: connection) == 0)
        try await barrier(on: run.socket, step: "no clip for a torn-down connection")
        await run.finish()
    }
}

extension PendingInputRun {
    /// Holds `connection`'s privacy clip chain behind `latch`: a piece queued at its tail now.
    func holdClipChain(_ connection: UUID, until latch: MeetingLatch) {
        env.router.state.withLock { AmbientRightyoRouter.clipChain(connection, in: &$0).enqueue { await latch.wait() } }
    }

    /// Sets or clears the router's privacy state for `connection` directly.
    func setPrivate(_ on: Bool, _ connection: UUID) {
        env.router.state.withLock { $0.duck[connection] = on ? AmbientDuckTimer(token: UUID(), timer: nil) : nil }
    }
}
#endif
