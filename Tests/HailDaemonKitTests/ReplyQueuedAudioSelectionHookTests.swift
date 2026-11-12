#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension ReplyQueuedAudioSelectionTests {
    @Test(arguments: [false, true])
    func pendingStopsKeepRetiringCoveredAndRequestTargets(returnToOriginal: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let routes = try VoiceRoutes(defaultTarget: "selected:one", routes: [
            .init(target: "selected:one", name: "Selected"), .init(target: "covered:one", name: "Covered")
        ])
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer().naming(routes), hostName: "mac-test")
        let port = try await listener.start()
        let timeouts = [VoiceStopConfirmationHold(), VoiceStopConfirmationHold()]
        defer { timeouts.forEach { $0.release() } }
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: port, selecting: [RecipientTestRig.target])
            defer { pair.close() }
            let owner = try await pair.submitInput(on: 0, rig: rig)
            let peer = try #require(await listener.peers.values.first)
            let session = await peer.session, queue = listener.replyAudioQueue
            // No ambient child has registered. This is also the privacy-restore-before-register boundary.
            await session.seedSelectionHookTarget("selected:one")
            let first = try queue.ticket()
            let stop1 = try heldHookStop(queue, connection: owner.connectionID, timeout: timeouts[0])
            let between = try queue.ticket()
            let stop2 = try heldHookStop(queue, connection: owner.connectionID, timeout: timeouts[1])
            let fresh = try queue.ticket()
            try await pair.select("recipient:other", on: 0)
            if returnToOriginal { try await pair.select(RecipientTestRig.target, on: 0) }
            // Resolution must use the updated pending records, not these original Stop value copies or U.
            queue.resolve(stop1, targets: ["recipient:other"])
            for target in ["selected:one", "covered:one", RecipientTestRig.target] {
                expectHookOutcome(queue, first, target: target, stopped: true)
            }
            queue.resolve(stop2, targets: ["recipient:other"])
            for target in ["selected:one", "covered:one", RecipientTestRig.target] {
                expectHookOutcome(queue, between, target: target, stopped: true)
                expectHookOutcome(queue, fresh, target: target, stopped: false)
            }
            expectHookOutcome(queue, first, target: "recipient:other", stopped: false)
            expectHookOutcome(queue, between, target: "recipient:other", stopped: false)
            try await pair.boundedBarrier(step: "hook and both resolutions complete")
        } catch {
            await listener.stop(reason: "synthetic failure")
            throw error
        }
        await listener.stop(reason: "synthetic complete")
    }

    @Test func longLivedStreamOpeningGenerationDoesNotRaiseFloor() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            try await rig.pair.select("recipient:other", on: 0)
            try await rig.pair.select(RecipientTestRig.target, on: 0)
            let old = try queue.ticket()
            let connection = try #require(rig.env.router.activeConnection())
            #expect(await listener.stopReplyPlayback(connection: connection, markQueuedAudio: true) == "stopped")
            #expect(try await receiveFrame(on: rig.socket, step: "long-lived stream stop")
                .payload == .control(.stopPlayback))
            expectHookOutcome(queue, old, target: RecipientTestRig.target, stopped: true)
            expectHookOutcome(queue, old, target: "recipient:other", stopped: false)
            let fresh = try queue.ticket()
            expectHookOutcome(queue, fresh, target: RecipientTestRig.target, stopped: false)
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func lateRouterRegistrationCannotReplaceSessionSelectionMirror() async throws {
        let fake = try FakeRightyo("exit 0")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2))
        let queue = env.listener.replyAudioQueue, connection = UUID()
        let timeout = VoiceStopConfirmationHold()
        defer { timeout.release(); fake.cleanUp() }
        do {
            queue.register(connection)
            queue.selectionWillChange(connection, retiring: [],
                to: .init(target: RecipientTestRig.target, generation: UUID()))
            let pipeline = try RightyoAmbientPipeline(configuration: .init(
                executable: fake.executable, config: fake.config, target: "recipient:other", binding: "synthetic",
                connection: connection, allowSynthetic: true), dispatcher: RecordingAmbientDispatcher())
            _ = env.router.state.withLock {
                env.router.register(pipeline, stream: UUID(), connection: connection, target: "recipient:other",
                    selection: UUID(), in: &$0)
            }
            let old = try queue.ticket()
            let stop = try heldHookStop(queue, connection: connection, timeout: timeout)
            queue.resolve(stop, targets: [])
            expectHookOutcome(queue, old, target: RecipientTestRig.target, stopped: true)
            expectHookOutcome(queue, old, target: "recipient:other", stopped: false)
            expectHookOutcome(queue, try queue.ticket(), target: RecipientTestRig.target, stopped: false)
        } catch {
            await env.listener.stop(reason: "synthetic failure")
            throw error
        }
        await env.listener.stop(reason: "synthetic complete")
    }

    private func heldHookStop(
        _ queue: ReplyAudioQueue, connection: UUID, timeout: VoiceStopConfirmationHold
    ) throws -> ReplyAudioQueue.Stop {
        let captured = ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            queue.captureStop(connection)
        })
        return try #require(captured)
    }

    private func expectHookOutcome(
        _ queue: ReplyAudioQueue, _ ticket: LocalReplyAudioTicket, target: String, stopped: Bool
    ) {
        switch queue.enqueue(ticket, connection: nil, target: target, { true }) {
        case .stopped: #expect(stopped)
        case .sent(let sent): #expect(!stopped && sent)
        case .pending: Issue.record("all relevant stops should be resolved")
        }
    }
}

extension HostSession {
    fileprivate func seedSelectionHookTarget(_ target: String) { selectedTarget = target }
}
#endif
