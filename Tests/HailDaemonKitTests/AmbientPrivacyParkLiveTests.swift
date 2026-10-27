#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The router a hook set before it existed reaches (#941 tests).
final class RouterBox: Sendable {
    let value = Mutex<AmbientRightyoRouter?>(nil)
}

/// #941 review round 1, P1: haild has no keepalive, so after a silent drop the phone's old private connection can still
/// be open when it reconnects and starts listening. Privacy held by any other live connection counts as a source, like
/// a park. Ported from the reviewer's probe. Real loopback listener and fake RightyO; synthetic only, waits bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkLiveTests {
    /// A rig whose first connection (`name`, `kind`) went private by the owner's voice and is still open.
    static func privateStillOpen(name: String = "test", kind: String? = "phone") async throws
    -> (RestoreRig, (URLSessionWebSocketTask, UUID)) {
        let rig = try await RestoreRig(phrase: "stop recording")
        let (socket, stale) = try await rig.start(name: name, kind: kind)
        try #require(await eventually { rig.router.duckMode(connection: stale) }, "first connection holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        return (rig, (socket, stale))
    }

    /// A normal start on the reconnected connection takes listening over from the still-open private one: private.
    @Test func aReconnectBeforeTheOldConnectionIsTornDownStartsPrivate() async throws {
        let (rig, (_, stale)) = try await Self.privateStillOpen()
        defer { rig.close() }
        let (socket, fresh) = try await rig.start()
        #expect(fresh != stale && rig.router.duckMode(connection: stale))
        #expect(rig.router.duckMode(connection: fresh), "fresh stream after reconnect must be private")
        #expect(await eventually {
            rig.details("ambient_privacy_restored").first?.hasPrefix("source=live from=\(stale)") == true
        }, "live restore log marker")
        try await AmbientPrivacyParkTests.expectHeardOnlyPrivately(rig, on: socket, spawn: 2)
    }

    /// A resume start never takes listening over (#373): while the old private stream is still active it is refused
    /// and no child is made, so nothing goes public.
    @Test func aResumeWhileTheOldStreamIsActiveStartsNothing() async throws {
        let (rig, (_, stale)) = try await Self.privateStillOpen()
        defer { rig.close() }
        let (socket, _) = try await rig.connect()
        try await recipientSocketSend(RestoreRig.segment(UUID(), 0, fill: 0x11, resume: true), on: socket)
        try await Self.untilPong(on: socket)
        #expect(rig.router.activeConnection() == stale)
        #expect((try? rig.fake.recorded("argv.2.txt")) == nil, "no child made for the refused resume")
        await rig.finish()
    }

    /// Once the old connection's stream has ended (the connection still open and private), a resume start is let in,
    /// and starts private.
    @Test func aResumeAfterTheOldStreamEndedStartsPrivate() async throws {
        let (rig, (old, stale)) = try await Self.privateStillOpen()
        defer { rig.close() }
        let stream = try #require(rig.router.activeStream)
        try await recipientSocketSend(audio(stream, 1, final: true), on: old)
        let router = rig.router
        #expect(await eventually { router.activeStream == nil }, "old stream ended marker")
        let (socket, fresh) = try await rig.start(resume: true)
        #expect(router.duckMode(connection: fresh) && router.duckMode(connection: stale))
        try await AmbientPrivacyParkTests.expectHeardOnlyPrivately(rig, on: socket, spawn: 2)
    }

    /// A child made public is not admitted once another connection takes privacy before it registers (the
    /// `admitsPrivacy` call site, M13): the start is refused and nothing listens.
    @Test func aChildMadePublicIsNotAdmittedOncePrivacyIsHeldElsewhere() async throws {
        let box = RouterBox(), elsewhere = UUID()
        let rig = try await RestoreRig(phrase: nil, childMade: { _ in
            box.value.withLock { $0 }?.state.withLock {
                $0.duck[elsewhere] = AmbientDuckTimer(token: UUID(), timer: nil)
            }
        })
        defer { rig.close() }
        box.value.withLock { $0 = rig.router }
        let (socket, connection) = try await rig.connect()
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        #expect(await eventually { rig.details("ambient_refused") == ["private"] }, "refused private marker")
        #expect(rig.router.activePipeline == nil && !rig.router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.heard(1).isEmpty)
    }

    /// Reads frames until a ping's pong, so a refusal sent first is read past.
    static func untilPong(on socket: URLSessionWebSocketTask) async throws {
        let nonce = UUID().uuidString
        try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
        for _ in 0..<4 {
            let payload = try await receiveFrame(on: socket, step: "until pong").payload
            guard payload != .control(.pong(nonce: nonce)) else { return }
        }
        Issue.record("no pong within four frames")
    }
}
#endif
