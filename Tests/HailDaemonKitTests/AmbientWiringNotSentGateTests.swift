#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #909 review round 2: each check on "Nothing was sent." on its own. The connection's privacy clip chain is held by a
/// latch piece, so the clip is queued at one moment and plays at another; privacy is set in the router's state
/// directly, as an entry a child took would. And a connection torn down before its notice gets no clip and leaves no
/// privacy clip chain behind. Synthetic only. Named `AmbientWiring…` so it runs in the serial timing lane.
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
        // The line is shown just before the clip is queued; this leaves it queued, not private, behind the latch.
        try await Task.sleep(for: .milliseconds(300))
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
        try await Task.sleep(for: .milliseconds(300))
        run.setPrivate(false, connection)
        latch.open()
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.suppressed] })
        try await barrier(on: run.socket, step: "no clip after privacy ended")
        await run.finish()
    }

    /// The device drops while the notice waits for its acknowledgement: no line, no clip, and no privacy clip chain is
    /// made again for the connection `stop(connection:)` already cleared.
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
        latch.open()
        let gone = "reason=inputPending shown=no_connection confirm=no_connection"
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [gone] })
        #expect(run.env.router.state.withLock { $0.privacyClips[connection] == nil })
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
