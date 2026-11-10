#if os(macOS)
import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// Authored child events, synthetic send completions and loopback transport only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientSessionChangeDeadlineTests {
    @Test func stalledSendEndsAndFreesItsRunWithoutAnAcknowledgementCompletion() async throws {
        let transport = ReplyTransportLifecycle()
        let entered = Mutex(false)
        let completion = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
        let ticket = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { callback in
            completion.withLock { $0 = callback }
        }, stallGrace: .seconds(30))
        defer { completion.withLock { $0 }?(nil) }
        #expect(ticket.enqueue())
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests,
            capabilities: AmbientSessionChangeNoticeTests.capabilities,
            acknowledgementHold: .init { entered.withLock { $0 = true }; _ = await ticket.result() })
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            try await rig.rebind()
            let began = ContinuousClock.now
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            try #require(await eventually { entered.withLock { $0 } })
            let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "deadline ends stalled acknowledgement")
            #expect(stop.payload == .control(AmbientSessionChangeNoticeTests.stopped))
            #expect(began.duration(to: .now) < .seconds(3))
            #expect(await eventually { rig.router.liveRuns == 0 })
            #expect(await rig.gate.activeStream == nil)
            #expect(await ticket.result() == .abandoned)
            #expect(await rig.base.adapter.deliveries.isEmpty)
            try await barrier(on: rig.pair.sockets[0], step: "no late notice or second ending")
        } catch {
            transport.retire()
            await rig.cleanUp()
            throw error
        }
        transport.retire()
        await rig.cleanUp()
    }

    @Test func childExitAndContinuedMicrophoneCannotOvertakeTheClaimedNotice() async throws {
        let ack = ClipGate()
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests,
            capabilities: AmbientSessionChangeNoticeTests.capabilities, acknowledgementHold: ack.acknowledgement)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            try await rig.rebind()
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            try #require(await eventually { rig.router.state.withLock { $0.runs.values.contains { $0.ending } } })
            let pipeline = try #require(rig.router.state.withLock { $0.active?.pipeline })
            await pipeline.stop(grace: 0.01)
            rig.router.inputClosed(stream, pipeline: pipeline)
            for sequence in 1...4 { #expect(await rig.segment(stream, sequence).frames.isEmpty) }
            #expect(await rig.router.reload() == .busy)
            try await barrier(on: rig.pair.sockets[0], step: "no input-closed ending while notice is held")
            ack.open()
            let notice = try await receiveFrame(on: rig.pair.sockets[0], step: "notice precedes the only ending")
            let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "only ending after child exit")
            #expect(notice.payload == .control(AmbientSessionChangeNoticeTests.notice))
            #expect(stop.payload == .control(AmbientSessionChangeNoticeTests.stopped))
            #expect(await eventually { rig.router.liveRuns == 0 })
            #expect(rig.events.details("ambient_input_closed").isEmpty)
            try await barrier(on: rig.pair.sockets[0], step: "exactly one ending after continued microphone")
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            ack.open()
            await rig.cleanUp()
            throw error
        }
        ack.open()
        await rig.cleanUp()
    }

    @Test func fourStalledRunsReleaseCapacityAndExpiredNoticesStaySilent() async throws {
        let ack = ClipGate()
        let rig = try await ConfiguredAmbientRig.make(behavior: Self.exitingRequest,
            capabilities: AmbientSessionChangeNoticeTests.capabilities, acknowledgementHold: ack.acknowledgement)
        do {
            let first = UUID()
            #expect(await rig.segment(first).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == first })
            let scope = try rig.scope()
            try await rig.rebind()
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            try #require(await eventually { ack.reached == 1 })
            #expect(await rig.segment(first, 1, final: true).frames.isEmpty)
            for count in 2...4 {
                try #require(await eventually {
                    rig.router.state.withLock { $0.runs.values.allSatisfy { $0.reaped } }
                })
                rig.router.ambientAudio(.started(stream: UUID(), connection: rig.connection, scope: scope))
                try #require(await eventually { ack.reached == count })
            }
            #expect(rig.router.liveRuns == AmbientRightyoRouter.maxRuns)
            #expect(await eventually { rig.router.liveRuns == 0 })
            // These starts deliberately inject router scopes to fill all slots without changing owner grants.
            // Only the session's original stream owns the gate, so drain any eligible ending before the barrier.
            let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "latest stalled run ending")
            #expect(stop.payload == .control(AmbientSessionChangeNoticeTests.stopped))
            ack.open()
            try await barrier(on: rig.pair.sockets[0], step: "expired notice tasks remain silent after release")
            try await rig.rebind("replacement", allow: true)
            try rewriteFake(rig.fake, ambientEchoAtEOF)
            #expect(await rig.segment(UUID(), final: true).frames.isEmpty)
            #expect(await eventually { await rig.base.adapter.deliveries.count == 1 })
            #expect(await rig.base.adapter.deliveries.map(\.binding) == ["replacement"])
        } catch {
            ack.open()
            await rig.cleanUp()
            throw error
        }
        ack.open()
        await rig.cleanUp()
    }
}

extension AmbientSessionChangeDeadlineTests {
    @Test(arguments: [false, true])
    func teardownOrCancellationRevokesAPendingNotice(cancel: Bool) async throws {
        let ack = ClipGate()
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests,
            capabilities: AmbientSessionChangeNoticeTests.capabilities, acknowledgementHold: ack.acknowledgement)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            try await rig.rebind()
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            try #require(await eventually { rig.router.state.withLock { $0.runs.values.contains { $0.ending } } })
            let attempt = try #require(rig.router.state.withLock { $0.runs.values.first?.sessionChange })
            if cancel {
                rig.router.state.withLock { $0.runs.values.first?.task }?.cancel()
            } else {
                rig.router.stop(connection: rig.connection)
            }
            #expect(await eventually { rig.router.liveRuns == 0 })
            #expect(!attempt.isOpen)
            #expect(await eventually { await rig.gate.activeStream == nil })
            if !cancel {
                let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "teardown terminates stream")
                #expect(stop.payload == .control(AmbientSessionChangeNoticeTests.stopped))
            }
            ack.open()
            if !cancel {
                try await barrier(on: rig.pair.sockets[0], step: "revoked notice remains silent after teardown")
            }
            #expect(!rig.events.details("ambient_delivery_refused").contains { $0.contains("shown=sent") })
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            ack.open()
            await rig.cleanUp()
            throw error
        }
        ack.open()
        await rig.cleanUp()
    }

    @Test func anExpiredNoticePermitCannotPostAfterAnActorHop() async throws {
        let rig = try await ConfiguredAmbientRig.make(capabilities: AmbientSessionChangeNoticeTests.capabilities)
        do {
            let peer = try #require(await rig.listener.peers.values.first)
            let attempt = AmbientSessionChangeWait()
            let frame = sessionFrame(target: ConfiguredAmbientRig.target,
                                     payload: .control(AmbientSessionChangeNoticeTests.notice))
            // Model expiry after frame preparation, before peer.post gets its actor turn.
            attempt.finish()
            let posted = await AmbientSessionChangeWait.$current.withValue(attempt) { await peer.post(frame) }
            #expect(!posted)
            try await barrier(on: rig.pair.sockets[0], step: "revoked transport permit suppresses a late notice")
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    static let exitingRequest = #"""
        /usr/bin/sed -n -e '1,3p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        while [ ! -f go1 ]; do /bin/sleep 0.02; done
        /usr/bin/sed -n -e '4,6p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        """#
}
#endif
