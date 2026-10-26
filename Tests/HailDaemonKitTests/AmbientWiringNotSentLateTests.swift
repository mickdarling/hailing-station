#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #909 second key, round 1: the voice-route refusal's "Nothing was sent." (#636) is gated on privacy like the
/// pending-input one, and a privacy clip chain made for a connection after its teardown does not outlive the notice.
/// The connection's privacy clip chain is held by a latch piece and the router's `notSentQueued` hook says when the clip
/// is queued; privacy and the late chain are set in the router's state directly. Synthetic only. Named `AmbientWiring…`
/// so it runs in the serial timing lane.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringNotSentLateTests {
    static let routeLine = PendingInputSeen.control(.error(code: .voiceRouteRefused,
                                                           message: "voice route: nothing to send to Deck"))

    /// A route refusal's clip queued while not private, privacy on before it plays: suppressed, the line still shown.
    @Test func aRouteRefusalsClipIsSuppressedWhenPrivacyComesOnBeforeItPlays() async throws {
        let run = try await PendingInputRun.make(script: PendingInputRun.routeThenTarget,
                                                 fixture: "enrolled-formed-request.jsonl",
                                                 routes: try AmbientVoiceRouteRefusalTests.routes())
        defer { run.close() }
        let latch = MeetingLatch()
        defer { latch.open() }
        let connection = try #require(await run.connection)
        run.holdClipChain(connection, until: latch)
        try await run.speak()
        #expect(try await run.seen(1) == [Self.routeLine])
        #expect(await eventually { run.queued.count(for: connection) == 1 })
        run.setPrivate(true, connection)
        latch.open()
        let suppressed = "reason=nothing_to_say shown=sent confirm=suppressed_privacy"
        #expect(await eventually { run.log.details("ambient_voice_route_refused") == [suppressed] })
        try await barrier(on: run.socket, step: "no route-refusal clip once private")
        await run.finish()
    }

    /// The device drops after its line is shown and its clip queued, and a chain is made for it again after its
    /// teardown, as one taken in the moment after `stop(connection:)` would be: once the clip has run (`no_connection`),
    /// that entry is dropped, not left for the daemon's life.
    @Test func aChainMadeAfterTeardownIsDroppedOnceTheClipHasRun() async throws {
        let run = try await PendingInputRun.make()
        defer { run.close() }
        let latch = MeetingLatch()
        defer { latch.open() }
        let connection = try #require(await run.connection)
        run.holdClipChain(connection, until: latch)
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(try await run.seen(3) == Array(AmbientWiringInputPendingTests.told.prefix(3)))
        #expect(await eventually { run.queued.count(for: connection) == 1 })
        run.pair.close()
        #expect(await eventually { await run.env.listener.peers.isEmpty })
        #expect(run.env.router.state.withLock { $0.privacyClips[connection] == nil }, "teardown dropped the chain")
        _ = run.env.router.state.withLock { AmbientRightyoRouter.clipChain(connection, in: &$0) }
        latch.open()
        let gone = "reason=inputPending shown=sent confirm=confirmnotsent/0:no_connection"
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [gone] })
        #expect(run.env.router.state.withLock { $0.privacyClips[connection] == nil })
        await run.finish()
    }
}
#endif
