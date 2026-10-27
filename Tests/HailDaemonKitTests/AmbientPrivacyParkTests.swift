#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #941: privacy parked across a transport drop fails closed. Another device's start or one long after the drop still
/// starts private, and only the owner's own privacy-off (voice exit or the app's switch) clears the park. Real loopback
/// listener and fake RightyO; every device claim and all PCM are synthetic, every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkTests {
    /// A rig whose first connection went private and then dropped, leaving its privacy parked.
    static func privacyDropped() async throws -> RestoreRig {
        let rig = try await RestoreRig(phrase: "stop recording")
        let (first, dropped) = try await rig.start()
        try #require(await eventually { rig.router.duckMode(connection: dropped) }, "first connection holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        await rig.drop(first, dropped)
        #expect(rig.router.state.withLock { $0.parkedPrivacy?.connection } == dropped)
        return rig
    }

    /// The bytes of one synthetic segment (`audio(_:_:)`).
    static var segmentBytes: Int {
        if case .audio(let segment) = audio(UUID(), 1).payload { segment.bytes.count } else { -1 }
    }

    /// Sends the started child a second synthetic segment once it hears audio (its private `started` confirmed), then
    /// ends the rig, so the `spawn`th child's audio file is complete. The child was launched start-private, and at most
    /// that second segment reached it: the first, sent with the start before its private proof, was dropped (#735
    /// S-8). A confirmed-private child hears the stream in RAM only, to hear the way back in.
    static func expectHeardOnlyPrivately(_ rig: RestoreRig, on socket: URLSessionWebSocketTask,
                                         spawn: Int) async throws {
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "fresh child started")
        let stream = try #require(rig.router.activeStream)
        try await recipientSocketSend(audio(stream, 1), on: socket)
        try await barrier(on: socket, step: "parked privacy stream audio processed")
        await rig.finish()
        let heard = (try? Data(contentsOf: rig.fake.directory.appendingPathComponent("audio.\(spawn).raw"))) ?? Data()
        #expect(heard.count <= segmentBytes, "no PCM reaches RightyO before its private proof")
        #expect((try? rig.fake.recorded("argv.\(spawn).txt"))?.contains("--start-private") == true)
    }

    static func launchedPublic(_ rig: RestoreRig, spawn: Int) async -> Bool {
        await eventually { (try? rig.fake.recorded("argv.\(spawn).txt"))?.contains("--start-private") == false }
    }

    /// Another device's claims never make a start public: it is restored private, and the claims are only logged.
    @Test(arguments: [false, true])
    func anotherDeviceStillStartsPrivate(resume: Bool) async throws {
        let rig = try await Self.privacyDropped()
        defer { rig.close() }
        let (socket, connection) = try await rig.start(name: "other", kind: "watch", resume: resume)
        #expect(rig.router.duckMode(connection: connection))
        #expect(await eventually {
            rig.details("ambient_privacy_restored").first?.contains("device_match=false") == true
        },
                "unmatched restore log marker")
        #expect(rig.router.state.withLock { $0.parkedPrivacy } != nil, "an unmatched start leaves the park held")
        try await Self.expectHeardOnlyPrivately(rig, on: socket, spawn: 2)
    }

    /// The same claims are logged as a match; the start is private either way.
    @Test func theSameDeviceIsLoggedAsAMatch() async throws {
        let rig = try await Self.privacyDropped()
        defer { rig.close() }
        let (socket, connection) = try await rig.start()
        #expect(rig.router.duckMode(connection: connection))
        #expect(await eventually {
            rig.details("ambient_privacy_restored").first?.contains("device_match=true") == true
        },
                "matched restore log marker")
        #expect(rig.details("ambient_privacy_parked") == ["replaced=false"])
        try await Self.expectHeardOnlyPrivately(rig, on: socket, spawn: 2)
    }

    /// Past every mode's bound (hours after the drop) the start is still private: an old park never yields public.
    @Test(arguments: [false, true])
    func anOldParkStillStartsPrivate(resume: Bool) async throws {
        let rig = try await Self.privacyDropped()
        defer { rig.close() }
        rig.clock.advance(5 * 3600)
        let (socket, connection) = try await rig.start(resume: resume)
        #expect(rig.router.duckMode(connection: connection))
        #expect(await eventually { rig.details("ambient_privacy_restored").first?.contains("age=18000") == true },
                "old restore log marker")
        try await Self.expectHeardOnlyPrivately(rig, on: socket, spawn: 2)
    }

    /// The owner's voice exit on the restored connection clears the park: the next start, anywhere, is public.
    @Test func theOwnersVoiceOffClearsThePark() async throws {
        let rig = try await Self.privacyDropped()
        defer { rig.close() }
        let (_, restored) = try await rig.start()
        let router = rig.router
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        #expect(router.setDuck(false, connection: restored, reason: "voice") == 1)
        #expect(router.state.withLock { $0.parkedPrivacy } == nil)
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=off mode=privacy"] },
                "privacy park cleared log marker")
        let (_, next) = try await rig.start(name: "other", kind: "watch")
        #expect(!router.duckMode(connection: next))
        #expect(await Self.launchedPublic(rig, spawn: 3))
        await rig.finish()
    }

    /// The app's switch is the owner's off too (reason `device`), and clears the park the same way.
    @Test func theOwnersSwitchOffClearsThePark() async throws {
        let rig = try await Self.privacyDropped()
        defer { rig.close() }
        let (_, restored) = try await rig.start()
        let router = rig.router
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        router.ambientPrivacy(false, connection: restored)
        #expect(!router.duckMode(connection: restored) && router.state.withLock { $0.parkedPrivacy } == nil)
        let (_, next) = try await rig.start()
        #expect(!router.duckMode(connection: next))
        #expect(await Self.launchedPublic(rig, spawn: 3))
        await rig.finish()
    }

    /// Only the owner's off on a private connection clears it: an off by anything else, or an off where privacy was
    /// not on, leaves it held, and the next start is still private.
    @Test func noOtherOffClearsThePark() async throws {
        let rig = try await Self.privacyDropped()
        defer { rig.close() }
        let (_, restored) = try await rig.start()
        let router = rig.router
        #expect(router.setDuck(false, connection: UUID(), reason: "voice") == 0)
        #expect(router.state.withLock { $0.parkedPrivacy } != nil, "an off where privacy was not on keeps the park")
        _ = router.setDuck(false, connection: restored, reason: "timeout")
        #expect(!router.duckMode(connection: restored))
        #expect(router.state.withLock { $0.parkedPrivacy } != nil, "a non-owner off keeps the park")
        let (socket, next) = try await rig.start(name: "other", kind: "watch")
        #expect(router.duckMode(connection: next))
        #expect(rig.details("ambient_park_discarded").isEmpty)
        try await Self.expectHeardOnlyPrivately(rig, on: socket, spawn: 3)
    }

    /// A restored connection that drops again parks its privacy again, so a third connection is private too.
    @Test func aRestoredConnectionDroppingAgainParksAgain() async throws {
        let rig = try await Self.privacyDropped()
        defer { rig.close() }
        let (again, restored) = try await rig.start()
        await rig.drop(again, restored)
        #expect(rig.router.state.withLock { $0.parkedPrivacy?.connection } == restored)
        #expect(await eventually { rig.details("ambient_privacy_parked") == ["replaced=false", "replaced=true"] },
                "parked again log marker")
        let (socket, next) = try await rig.start(resume: true)
        #expect(rig.router.duckMode(connection: next))
        try await Self.expectHeardOnlyPrivately(rig, on: socket, spawn: 3)
    }
}
#endif
