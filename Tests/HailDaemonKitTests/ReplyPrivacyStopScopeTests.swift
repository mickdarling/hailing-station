import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyPrivacyStopScopeTests {
    @Test func delayedPrivacyAnnouncementMustNotRetractPostExitRequest() async throws {
        let rig = try await DuckRig(script: AmbientPrivacyConfirmAfterAckTests.heldSwitch(),
            clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability, PlaybackStop.capability])
        let entered = VoiceStopConfirmationHold(), hold = VoiceStopConfirmationHold()
        defer { hold.release(); rig.close() }
        do {
            try #require(await eventually { rig.details("ambient_duck_confirmed").count == 1 })
            let listener = rig.env.listener, connection = try #require(rig.connection())
            ReplyAudioEnqueueTesting.$afterPrivacyDecision.withValue({
                entered.release(); await hold.wait()
            }, operation: {
                rig.env.router.ambientPrivacy(true, connection: connection)
            })
            AmbientPrivacyAckGateTests.go(rig.fake)
            await entered.wait()
            rig.env.router.ambientPrivacy(false, connection: connection)
            try #require(await eventually { await !listener.replyHold.holds(connection) })
            let peer = try #require(await listener.peers.values.first)
            let session = await peer.session
            #expect(await session.connectionID == connection)
            let context = try await rig.env.rig.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            #expect(await session.replyPublicationStatus(recipientText(reply)) == .ready)
            hold.release()
            try #require(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
            _ = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "delayed privacy stop complete")
            let retained = await session.replyRequests[context.id] != nil
            let status = await session.replyPublicationStatus(recipientText(reply))
            let delivered = try? await listener.publish(recipientText(reply))
            if delivered == 1 { _ = try await receiveFrame(on: rig.socket, step: "post-exit reply") }
            #expect(retained)
            #expect(status == .ready)
            #expect(delivered == 1)
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
