#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #904 (#967 second key, P2-1): a `set_privacy` on still in flight when its connection is torn down arms nothing. The
/// gate refuses a pre-arm for a connection it already ended, and, behind it, an arming whose `duck_mode` notice finds
/// the device gone is undone, only while it is still that arming. Real loopback listener, the real `gate.end` and
/// `stop`, and fake RightyO; every device claim is synthetic, every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyPreArmTeardownTests {
    /// A never-streamed device torn down through the real path: its transport drops, the listener ends it at the gate
    /// (`gate.end`) and the router (`stop`). Its input route, noted before, is the marker that `stop` has run.
    static func tornDown(_ rig: RestoreRig) async throws -> UUID {
        let (socket, connection) = try await rig.connect(capabilities: [DuckMode.capability])
        try await recipientSocketSend(sessionFrame(payload: .control(.ambientInput(route: "usb_audio"))), on: socket)
        let router = rig.router
        #expect(await eventually { router.state.withLock { $0.inputRoutes[connection] != nil } }, "route marker")
        socket.cancel(with: .goingAway, reason: nil)
        #expect(await eventually { router.state.withLock { $0.inputRoutes[connection] == nil } }, "stop ran marker")
        return connection
    }

    /// Whether any privacy is held for a fresh start anywhere: a live holder, a park or the overflow.
    static func anySource(_ router: AmbientRightyoRouter) -> Bool {
        router.state.withLock { AmbientRightyoRouter.privacySource(except: UUID(), in: $0) != nil }
    }

    /// The late `set_privacy` on reaches the gate after the real teardown: refused as `ended`, so nothing is armed, no
    /// reply is held, the dead connection is no privacy source, and another device's fresh start is public.
    @Test func aPreArmAfterTeardownArmsNothing() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let dead = try await Self.tornDown(rig)
        let router = rig.router
        await rig.env.gate.setPrivacy(true, connection: dead)
        #expect(!router.duckMode(connection: dead))
        #expect(await !rig.env.listener.replyHold.holds(dead))
        #expect(!Self.anySource(router))
        #expect(rig.details("ambient_privacy_prearmed") == ["refused=ended"])
        let (_, other) = try await rig.start(name: "other", kind: "pad")
        #expect(!router.duckMode(connection: other))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 1))
        await rig.finish()
    }

    /// The router's backstop, reached past the gate: an arming with no source for a connection already gone is undone
    /// once its notice finds no connection: no privacy, no reply hold, no source; logged.
    @Test func anArmingForAGoneDeviceIsUndone() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let dead = try await Self.tornDown(rig)
        let router = rig.router, listener = rig.env.listener
        router.ambientPrivacyPreArm(connection: dead)
        #expect(rig.details("ambient_privacy_prearmed") == ["source=none"])
        #expect(await eventually { rig.details("ambient_privacy_disarmed") == ["reason=no_connection"] },
                "disarmed marker")
        #expect(!router.duckMode(connection: dead) && !Self.anySource(router))
        #expect(await eventually { await !listener.replyHold.holds(dead) }, "hold released marker")
        let (_, other) = try await rig.start(name: "other", kind: "pad")
        #expect(!router.duckMode(connection: other))
        await rig.finish()
    }

    /// A restore's arming (from a live source) for a gone device is undone with the source it recorded, while one that
    /// was armed again meanwhile (a newer token) is left as it is.
    @Test func onlyTheArmingTheNoticeWasForIsUndone() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let dead = try await Self.tornDown(rig)
        let (router, holder, rearmed, newer) = (rig.router, UUID(), UUID(), UUID())
        router.state.withLock { $0.duck[holder] = AmbientDuckTimer(token: UUID(), timer: nil) }
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        router.mediaNotices.enqueue { for await _ in held { break } }
        router.ambientPrivacyPreArm(connection: dead)
        router.ambientPrivacyPreArm(connection: rearmed)
        #expect(rig.details("ambient_privacy_prearmed") == ["source=live", "source=live"])
        #expect(router.state.withLock { $0.privacySources[dead]?.connection } == holder)
        router.state.withLock { $0.duck[rearmed] = AmbientDuckTimer(token: newer, timer: nil) }
        release.yield()
        release.finish()
        let drained = MeetingLatch()
        router.mediaNotices.enqueue { drained.open() }
        #expect(await eventually { drained.isOpen }, "both notices done marker")
        #expect(rig.details("ambient_privacy_disarmed") == ["reason=no_connection"])
        #expect(!router.duckMode(connection: dead))
        #expect(router.state.withLock { $0.privacySources[dead] == nil })
        #expect(await eventually { await !rig.env.listener.replyHold.holds(dead) }, "hold released marker")
        #expect(router.duckArming(connection: rearmed) == newer && router.duckMode(connection: holder))
        await rig.finish()
    }
}
#endif
