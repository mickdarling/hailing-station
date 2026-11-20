#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyMuteMixedPathsTests {
    @Test func preservedAudioWaitsAfterStopSendUntilMuteFlagIsSent() async throws {
        try await ReplyMuteSilencesTests().withMuteRig { env, socket, session, _ in
            let reply = recipientDescriptor(try await env.rig.submit(on: session), audio: true)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = VoiceStopConfirmationHold(), completed = Mutex(false)
            defer { release.release() }
            let muting = Task {
                await ReplyAudioEnqueueTesting.$afterStopSend.withValue({
                    entered.release(); await release.wait()
                }, operation: { await env.listener.muteReplyPlayback(connection: session.connectionID) })
            }
            await entered.wait()
            #expect(try await receiveFrame(on: socket, step: "stop before mute").payload == .control(.stopPlayback))
            let audio = recipientAudio(reply, sequence: 0, final: true)
            let publishing = Task {
                await ReplyAudioEnqueueTesting.$waitingForControl.withValue({ waiting.release() }, operation: {
                    let result = try? await env.listener.publish(audio)
                    completed.withLock { $0 = true }
                    waiting.release()
                    return result
                })
            }
            await waiting.wait()
            #expect(!completed.withLock { $0 }, "Preserved audio must still wait after stop reaches the wire")
            try await barrier(on: socket, step: "no preserved PCM before mute flag")
            release.release()
            #expect(await muting.value.mute == "sent")
            #expect(await publishing.value == 1)
            #expect(try await receiveFrame(on: socket, step: "mute precedes preserved audio").payload
                == .control(.setReplyMute(muted: true)))
            #expect(try await receiveFrame(on: socket, step: "silent preserved audio") == audio)
        }
    }

    @Test(arguments: [false, true])
    func overlappingMuteAndStopCannotReviveAuthority(muteFirst: Bool) async throws {
        try await ReplyMuteSilencesTests().withMuteRig { env, socket, session, _ in
            let earlier = try await env.rig.submit(on: session)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = VoiceStopConfirmationHold(), completed = Mutex(false)
            defer { release.release() }
            let first = Task {
                await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                    entered.release(); await release.wait()
                }, operation: {
                    if muteFirst {
                        _ = await env.listener.muteReplyPlayback(connection: session.connectionID)
                    } else {
                        _ = await env.listener.stopReplyPlayback(
                            connection: session.connectionID, markQueuedAudio: true)
                    }
                })
            }
            await entered.wait()
            let between = try await env.rig.submit(on: session)
            let publishing = publishWaiting(recipientText(recipientDescriptor(between)), listener: env.listener,
                                            waiting: waiting, completed: { completed.withLock { $0 = true } })
            await waiting.wait()
            #expect(!completed.withLock { $0 })
            if muteFirst {
                _ = await env.listener.stopReplyPlayback(connection: session.connectionID, markQueuedAudio: true)
            } else { _ = await env.listener.muteReplyPlayback(connection: session.connectionID) }
            release.release()
            await first.value
            #expect(await publishing.value == (muteFirst ? nil : 1))
            _ = try await AmbientPrivacySwitchTests.untilPong(socket, step: "overlapping controls drained")
            #expect(await session.replyRequests[earlier.id] == nil)
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await env.listener.publish(recipientText(recipientDescriptor(earlier)))
            }
            #expect((await session.replyRequests[between.id] != nil) == !muteFirst)
            let later = recipientText(recipientDescriptor(try await env.rig.submit(on: session)))
            #expect(try await env.listener.publish(later) == 1)
            #expect(try await receiveFrame(on: socket, step: "all control waiters released") == later)
        }
    }

    private func publishWaiting(
        _ frame: Frame, listener: WebSocketListener, waiting: VoiceStopConfirmationHold,
        completed: @escaping @Sendable () -> Void
    ) -> Task<Int?, Never> {
        Task {
            await ReplyAudioEnqueueTesting.$waitingForControl.withValue({ waiting.release() }, operation: {
                let result = try? await listener.publish(frame)
                completed()
                waiting.release()
                return result
            })
        }
    }

    @Test func privacyWhileMutedRetractsPendingAuthorityThroughExitAndUnmute() async throws {
        let notifications = ReplyMutePrivacyNotifications()
        let rig = try await DuckRig(script: AmbientPrivacyReplyTests.quiet,
            capabilities: [DuckMode.capability, PlaybackStop.capability, ReplyMute.capability],
            onEvent: { notifications.record($0) })
        defer { rig.close() }
        do {
            await notifications.started.wait()
            try #require(rig.connection() != nil)
            let connection = try #require(rig.connection()), listener = rig.env.listener
            let peer = try #require(await listener.peers.values.first)
            let session = await peer.session
            // The fixture's ambient handoff follows its admitted duck-v3 started line.
            let ambient = await rig.env.rig.adapter.contextEvents.stream.first { _ in true }
            try #require(ambient != nil)
            let requestID = try await replyMuteTypedRequest(on: rig, session: session)
            let request = try #require(await session.replyRequests[requestID]).context
            #expect(await listener.muteReplyPlayback(connection: connection).mute == "sent")
            _ = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "muted")
            #expect(await session.replyRequests[request.id] != nil)
            #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1)
            await notifications.dropped.wait()
            try #require(await session.replyRequests[request.id] == nil)
            #expect(rig.env.router.setDuck(false, connection: connection, reason: "voice") == 1)
            await notifications.released.wait()
            try #require(await !listener.replyHold.holds(connection))
            #expect(await listener.setReplyMute(false, connection: connection) == "sent")
            _ = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "privacy exit and unmute drained")
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await listener.publish(recipientText(recipientDescriptor(request)))
            }
            let laterID = try await replyMuteTypedRequest(on: rig, session: session)
            let laterContext = try #require(await session.replyRequests[laterID]).context
            let later = recipientText(recipientDescriptor(laterContext))
            #expect(try await listener.publish(later) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "fresh authority after privacy") == later)
        } catch { await rig.env.listener.stop(reason: "synthetic failure"); throw error }
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        await notifications.ended.wait()
        await rig.env.listener.stop(reason: "synthetic complete")
    }
}
#endif
