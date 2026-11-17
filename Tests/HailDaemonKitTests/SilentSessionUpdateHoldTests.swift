import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateHoldTests {
    @Test(arguments: ["quiet", "privacy", "meeting"])
    func holdsRetainCardsAndClearDrainsImmediately(_ mode: String) async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router)
        await set(mode, on: true, rig: rig, router: router)
        #expect(await rig.submit().outcome == .held && rig.sends == 0)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 1)
        await set(mode, on: false, rig: rig, router: router)
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 1 && rig.drains.contains("trigger=hold_cleared count=1"))
        await rig.listener.stop()
    }

    @Test func mediaModeDoesNotHoldSilentInfo() async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router)
        _ = router.setMedia(true, connection: rig.connection, reason: "synthetic")
        #expect(router.mediaMode(connection: rig.connection))
        #expect(await rig.submit().outcome == .delivered && rig.sends == 1)
        await rig.listener.stop()
    }

    @Test(arguments: ["quiet", "privacy", "meeting"])
    func holdAtFinalPeerHopRefusesSendAndClearDuringReplyWaitsForTerminal(_ mode: String) async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router), reply = UUID()
        let report = await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
            await set(mode, on: true, rig: rig, router: router)
        }, operation: { await rig.submit() })
        #expect(report.outcome == .held && rig.sends == 0)
        try await rig.send(rig.frame(reply, text: true))
        await set(mode, on: false, rig: rig, router: router)
        // Join a real drain at the cleared hold while the stream still owns the transport.
        await rig.listener.drainSilentSessionUpdates(.holdCleared)
        #expect(rig.sends == 1)
        try await rig.send(rig.frame(reply, final: true))
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 3)
        await rig.listener.stop()
    }

    private func makeRouter() -> AmbientRightyoRouter {
        AmbientRightyoRouter(configuration: .init(executable: URL(fileURLWithPath: "/bin/false"),
            config: URL(fileURLWithPath: "/dev/null"), target: RecipientTestRig.target, binding: "reply-binding"))
    }

    private func set(_ mode: String, on: Bool, rig: SilentUpdateRig, router: AmbientRightyoRouter) async {
        switch mode {
        case "quiet":
            if on { _ = await rig.listener.sessionUpdate(.init(action: .quietOn)) } else {
                await rig.listener.setSyntheticQuiet(false)
            }
        case "meeting": _ = router.setMeeting(on: on, connection: rig.connection, reason: "synthetic")
        default:
            let hold = await rig.listener.replyHold
            hold.set(on, connection: rig.connection)
            // Exercise the real router's privacy transition notifier without launching a reporting child.
            router.state.withLock { state in
                state.duck[rig.connection] = on ? AmbientDuckTimer(token: UUID(), timer: nil) : nil
            }
        }
    }
}
