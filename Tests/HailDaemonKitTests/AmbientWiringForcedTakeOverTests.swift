#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #366: take-overs faster than retired children stop by themselves. With every child slot taken, a new start forces
/// the oldest retired child out (EOF, SIGTERM, SIGKILL within about a second) and then gets its own child, in the
/// gate's order. Each fake child copies stdin to its own file, then ignores EOF and SIGTERM, so only SIGKILL ends it.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringForcedTakeOverTests {
    static let stubborn = "/bin/cat > \"audio-$$.bin\"\ntrap '' TERM\nexec /bin/sleep 60"

    private struct Device {
        let session: URLSession
        let socket: URLSessionWebSocketTask
        func close() {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
    }

    private func connect(port: UInt16, kind: String) async throws -> Device {
        let (session, socket) = try recipientSocket(port: port)
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [AmbientTakeOver.capability], deviceName: "test", deviceKind: kind
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
        return Device(session: session, socket: socket)
    }

    private func audioFiles(_ fake: FakeRightyo) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(atPath: fake.directory.path).filter { $0.hasPrefix("audio-") }
            .map { try Data(contentsOf: fake.directory.appendingPathComponent($0)) }
    }

    @Test func fastPingPongWithoutWaitingLeavesTheNewestDeviceListening() async throws {
        let fake = try FakeRightyo(Self.stubborn)
        defer { fake.cleanUp() }
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2), events: events)
        let phone = try await connect(port: env.port, kind: "phone")
        let pad = try await connect(port: env.port, kind: "pad")
        defer { [phone, pad].forEach { $0.close() } }
        let streams = (0..<4).map { _ in UUID() }
        for (round, stream) in streams.enumerated() {
            let (device, from) = round.isMultiple(of: 2) ? (phone, "pad") : (pad, "phone")
            try await recipientSocketSend(audio(stream, 0), on: device.socket)
            if round > 0 {
                #expect(try await recipientSocketReceive(on: device.socket).payload
                    == .control(.ambientMovedHere(from: from)))
            }
        }
        try await recipientSocketSend(audio(streams[3], 1), on: pad.socket)
        try await recipientSocketSend(audio(streams[3], 2), on: pad.socket)
        // The newest device listens, and its child hears every segment, in order, including those sent while the
        // oldest retired child was being forced out.
        #expect(await eventually { env.router.activeStream == streams[3] })
        #expect(await eventually { (try? audioFiles(fake).contains { $0.count == 3 * 3_200 }) == true })
        #expect(await env.gate.activeStream == streams[3])
        #expect(events.all.contains("ambient_retired_forced"))
        #expect(!events.all.contains("ambient_refused"))
        // The phone's forced-out children fail, but it moved: it is told nothing more (no stale "ambient stopped").
        try await recipientSocketBarrier(on: phone.socket)
        try await recipientSocketSend(audio(streams[3], 3, final: true), on: pad.socket)
        try await recipientSocketBarrier(on: pad.socket)
        #expect(try audioFiles(fake).contains { $0.count == 4 * 3_200 })
        #expect(await eventually { env.router.liveRuns == 0 })
        await env.listener.stop(reason: "synthetic test complete")
    }

    /// Router events driven directly, as the gate sends them: two retired children that ignore EOF and SIGTERM, then
    /// a third start. Their own stop would take 10 s; the forced one ends within about a second.
    private func fillWithRetiredChildren(_ router: AmbientRightyoRouter) {
        for _ in 0..<2 {
            let stream = UUID()
            router.ambientAudio(.started(stream: stream, connection: UUID()))
            router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: Data(count: 3_200)))
            router.ambientAudio(.ended(stream: stream, reason: .superseded))
        }
    }

    @Test func aRetiredChildThatIgnoresEOFIsKilledWithinTheGrace() async throws {
        let fake = try FakeRightyo(Self.stubborn)
        defer { fake.cleanUp() }
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 5, termGrace: 5), events: events)
        fillWithRetiredChildren(env.router)
        let newest = UUID(), started = ContinuousClock.now
        env.router.ambientAudio(.started(stream: newest, connection: UUID()))
        env.router.ambientAudio(.segment(stream: newest, sequence: 0, bytes: Data(repeating: 7, count: 3_200)))
        #expect(await eventually { env.router.activeStream == newest })
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(events.all.filter { $0 == "ambient_retired_forced" }.count == 1)
        env.router.ambientAudio(.ended(stream: newest, reason: .final))
        await env.listener.stop(reason: "synthetic test complete")
        #expect(env.router.liveRuns == 0)
        #expect(try audioFiles(fake).contains(Data(repeating: 7, count: 3_200)))
    }

    @Test func shutdownDuringAForcedStopDrainsEverything() async throws {
        let fake = try FakeRightyo(Self.stubborn)
        defer { fake.cleanUp() }
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 5, termGrace: 5), events: events)
        fillWithRetiredChildren(env.router)
        env.router.ambientAudio(.started(stream: UUID(), connection: UUID()))
        #expect(await eventually { events.all.contains("ambient_retired_forced") })
        let started = ContinuousClock.now
        await env.listener.stop(reason: "synthetic stop during a forced stop")
        #expect(env.router.liveRuns == 0)
        #expect(env.router.activeStream == nil)
        #expect(ContinuousClock.now - started < .seconds(30))
        await env.router.settle()
    }
}
#endif
