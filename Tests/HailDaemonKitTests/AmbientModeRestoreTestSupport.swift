#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The router's wall clock, moved forward by a test instead of waiting (#735 meeting mode restore (MM-E)).
final class RestoreClock: Sendable {
    private let offset = Mutex<TimeInterval>(0)
    func now() -> Date { Date().addingTimeInterval(offset.withLock { $0 }) }
    func advance(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }
}

/// Every meeting change the hook saw, in order.
private final class RestoreHooks: Sendable {
    let list = Mutex<[MeetingChange]>([])
}

/// Synthetic devices dropping and coming back through the loopback listener (MM-E). The fake's `speaker`th child (the
/// first by default) says `phrase` as the enrolled owner; every other child says nothing. Each child records its own control lines, in
/// `control.N.txt` by launch order, so a restored child's very first line can be read on its own.
final class RestoreRig: Sendable {
    static let resumed = AmbientAckClip(pcm: Data(repeating: 9, count: 480), sampleRate: 24_000,
                                       text: "Meeting mode is still on.")
    static var clips: AmbientAckLibrary {
        AmbientAckLibrary(clips: [AmbientStopConfirmation.meetingOn: [MeetingRig.on],
                                 AmbientStopConfirmation.meetingOff: [MeetingRig.off],
                                 AmbientStopConfirmation.meetingEnded: [MeetingRig.ended],
                                 AmbientStopConfirmation.meetingResumed: [resumed]])
    }
    static let gate = "{\"media\":true}\n"
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let clock = RestoreClock()
    private let events = DuckEvents()
    private let hooks = RestoreHooks()
    private let sessions = Mutex<[URLSession]>([])
    var router: AmbientRightyoRouter { env.router }
    var changes: [MeetingChange] { hooks.list.withLock { $0 } }
    var parked: ParkedModes? { router.state.withLock { $0.parked } }

    init(phrase: String? = "meeting mode", speaker: Int = 1,
         timeout: TimeInterval = AmbientRightyoRouter.defaultMeetingTimeout,
         mediaTimeout: TimeInterval = AmbientRightyoRouter.defaultMediaTimeout) async throws {
        let first = phrase == nil ? "/usr/bin/sed -n -e 1p events.jsonl | /usr/bin/sed -e \"s/formed-demo/$7/g\""
            : "/usr/bin/sed -e '$d' -e \"s/formed-demo/$7/g\" events.jsonl"
        fake = try FakeRightyo("""
        SPAWN=1
        while ! /bin/mkdir "spawn.$SPAWN" 2>/dev/null; do SPAWN=$((SPAWN + 1)); done
        \(FakeRightyo.ackingControl(append: true).replacingOccurrences(of: "control.txt", with: "control.$SPAWN.txt"))
        if [ "$SPAWN" = \(speaker) ]; then
        \(first)
        else
        /usr/bin/sed -n -e 1p events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"
        fi
        \(FakeRightyo.ackingTail)
        """)
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        try Self.prepare(fake, phrase: phrase ?? "archive the project")
        let events = events, hooks = hooks, clock = clock
        env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: Self.clips,
                                   replyControl: true, mediaTimeout: mediaTimeout, startDeadline: 30, ackDeadline: 30,
                                   meeting: .init(timeout: timeout, onChange: { change in
            hooks.list.withLock { $0.append(change) }
        }, now: { clock.now() }), onEvent: { event in events.list.withLock { $0.append(event) } })
    }

    private static func prepare(_ fake: FakeRightyo, phrase: String) throws {
        var lines = try fake.recorded("events.jsonl").split(separator: "\n").map {
            $0.replacingOccurrences(of: "Rightyo, archive the project.", with: "Rightyo, \(phrase).")
        }
        lines[0] = lines[0].replacingOccurrences(of: "\"phase\": \"started\"",
            with: "\"addressing\": {\"names\": [\"Rightyo\"]}, \"duck\": {\"version\": 3}, \"phase\": \"started\"")
        try (lines.joined(separator: "\n") + "\n").write(to: fake.directory.appendingPathComponent("events.jsonl"),
                                                         atomically: true, encoding: .utf8)
    }

    /// A negotiated device with these Hello claims, selecting the rig's target, and its connection id. The default
    /// claims carry a class, so two default devices match (an absent class never does).
    func connect(name: String = "test", kind: String? = "phone") async throws -> (URLSessionWebSocketTask, UUID) {
        let before = await Self.connections(of: env.listener)
        let (session, socket) = try recipientSocket(port: env.port)
        sessions.withLock { $0.append(session) }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: ["probe"], deviceName: name, deviceKind: kind
        )))), on: socket)
        _ = try await receiveFrame(on: socket, step: "restore device hello")
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await barrier(on: socket, step: "restore device selection")
        let after = await Self.connections(of: env.listener)
        return (socket, try #require(after.subtracting(before).first))
    }

    /// Connects a device and starts its stream, waiting until its child is the active one.
    func start(name: String = "test", kind: String? = "phone") async throws -> (URLSessionWebSocketTask, UUID) {
        let (socket, connection) = try await connect(name: name, kind: kind)
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        let router = router
        #expect(await eventually { router.activeConnection() == connection }, "restore start marker")
        return (socket, connection)
    }

    /// Drops a device's connection, as a lost network does, and waits for its teardown.
    func drop(_ socket: URLSessionWebSocketTask, _ connection: UUID) async {
        socket.cancel(with: .goingAway, reason: nil)
        let (listener, router) = (env.listener, router)
        #expect(await eventually { await !Self.connections(of: listener).contains(connection) }, "restore drop marker")
        #expect(await eventually { router.state.withLock { $0.latest[connection] == nil } },
                "restore teardown marker")
    }

    /// The connection ids of the listener's current peers, each read on its own session's actor.
    static func connections(of listener: WebSocketListener) async -> Set<UUID> {
        var ids = Set<UUID>()
        for peer in await listener.peers.values { ids.insert(await peer.session.connectionID) }
        return ids
    }

    /// The `remaining=` seconds a log detail names, if any.
    static func remaining(in detail: String?) -> Int? {
        detail?.split(separator: " ").first { $0.hasPrefix("remaining=") }.flatMap { Int($0.dropFirst(10)) }
    }

    /// Waits (bounded) for every hook and meeting log queued so far on the router-wide hook chain, and every clip
    /// queued so far on each of `clips`' own chains: a sentinel behind each. Only after it is a hook count, or a log's
    /// absence, evidence rather than a race with the chain.
    func drainMeetingChanges(clips connections: [UUID] = []) async {
        let hooks = MeetingLatch(), clips = connections.map { _ in MeetingLatch() }
        router.meetingChanges.enqueue { hooks.open() }
        for (connection, latch) in zip(connections, clips) {
            router.enqueuePrivacyClip(connection) { _ in { latch.open() } }
        }
        #expect(await eventually { hooks.isOpen && clips.allSatisfy { $0.isOpen } }, "restore chains drained marker")
    }

    func control(_ spawn: Int) -> String? { try? fake.recorded("control.\(spawn).txt") }
    func details(_ name: String) -> [String] {
        events.list.withLock { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
    }
    /// The next confirmation's words on `socket`, skipping its audio.
    func confirmation(on socket: URLSessionWebSocketTask, within: Duration = .seconds(15)) async throws -> String? {
        for _ in 0..<6 {
            let frame = try await receiveFrame(on: socket, step: "restore confirmation", within: within)
            if case .text(let words) = frame.payload { return words.text }
        }
        Issue.record("no confirmation text within six frames")
        return nil
    }
    /// The one audio frame that follows a confirmation's words, so a barrier after it sees only its pong.
    func clipAudio(on socket: URLSessionWebSocketTask) async throws {
        let frame = try await receiveFrame(on: socket, step: "restore confirmation audio")
        if case .audio = frame.payload {} else { Issue.record("expected the confirmation's audio") }
    }

    /// Stops the listener, which ends every stream and reaps every child, so each control file is complete.
    func finish() async {
        await bounded("restore listener stop") { [listener = env.listener] in
            await listener.stop(reason: "synthetic test complete")
        }
        await boundedSettle(router, step: "restore rig settle")
    }
    func close() {
        sessions.withLock { $0.forEach { $0.invalidateAndCancel() } }
        fake.cleanUp()
    }
}
#endif
