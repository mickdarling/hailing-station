#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Reply control (rightyo#124): the phone's own playback reports, from its admitted diagnostics, reach that
/// connection's RightyO child on fd 3; nothing reaches it when reply control is off.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringReplyControlTests {
    /// Copies fd 3 (when present) to control.txt and drains stdin until EOF.
    static let script = """
        if [ "$#" -ge 2 ] && [ "${@: -2:1}" = "--control-fd" ]; then /bin/cat <&3 > control.txt & fi
        /bin/cat > /dev/null
        wait
        """

    static func playback(_ names: [DiagnosticEventName]) throws -> [DiagnosticEvent] {
        try names.enumerated().map { try DiagnosticEvent($0.element, timestamp: Int64(1_000 + $0.offset)) }
    }

    func run(replyControl: Bool, events: [DiagnosticEventName]) async throws -> String? {
        let fake = try FakeRightyo(Self.script)
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), replyControl: replyControl)
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        try await pair.barrier()
        let id = try #require(env.connected.all.first)
        let connection = try #require(await env.listener.peers[id]?.session.connectionID)
        #expect(await eventually { env.router.liveRuns == 1 })
        env.router.replyPlayback(try Self.playback(events), connection: connection)
        // Another connection's reports never reach this stream.
        env.router.replyPlayback(try Self.playback([.replyPlaybackStart]), connection: UUID())
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        try await pair.barrier()
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        return try? fake.recorded("control.txt")
    }

    @Test func theLastPlaybackReportReachesTheStreamsChild() async throws {
        let recorded = try await run(replyControl: true, events: [.routeChange, .replyPlaybackStart, .replyPlaybackEnd])
        #expect(recorded == "{\"reply\":\"ended\"}\n")
    }

    @Test func aPlaybackErrorEndsTheReplyAndOtherEventsReportNothing() async throws {
        #expect(try await run(replyControl: true, events: [.replyPlaybackStart, .replyPlaybackError])
                == "{\"reply\":\"ended\"}\n")
        #expect(try await run(replyControl: true, events: [.routeChange, .captureState]) == "")
    }

    @Test func withoutReplyControlTheChildGetsNoDescriptorAndNoReports() async throws {
        #expect(try await run(replyControl: false, events: [.replyPlaybackStart]) == nil)
    }

    @Test func theDiagnosticLogShowsTheObserverOnlyAdmittedEvents() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hail-observe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let log = DiagnosticLog(directory: scratch.appendingPathComponent("diagnostics"),
                                sessionRate: .init(capacity: 2, perSecond: 0.001))
        let seen = ObservedBatches()
        await log.observe { events, session in seen.add(events.count, session) }
        let session = UUID()
        _ = await log.record(try Self.playback([.replyPlaybackStart, .replyPlaybackEnd, .replyPlaybackStart]),
                             session: session, device: "d")
        _ = await log.record(try Self.playback([.replyPlaybackEnd]), session: session, device: "d")
        #expect(seen.all.map(\.0) == [2])
        #expect(seen.all.map(\.1) == [session])
    }
}

final class ObservedBatches: Sendable {
    private let batches = Mutex<[(Int, UUID)]>([])
    var all: [(Int, UUID)] { batches.withLock { $0 } }
    func add(_ count: Int, _ session: UUID) { batches.withLock { $0.append((count, session)) } }
}
#endif
