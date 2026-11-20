#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Fixed daemon notices over loopback transport and authored child events; no target output or device playback.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientSessionChangeNoticeTests {
    static let notice = ControlPayload.error(code: .voiceRouteRefused,
        message: "The voice target's session changed. Reconnecting.")
    static let stopped = ControlPayload.error(code: .notAllowed, message: "ambient stopped: target session changed")
    static let capabilities = ["probe", RequestRefusals.capability]

    @Test func repeatedUnapprovedRestartsGetOneNoticeThenOneStopAndNeverStartAChild() async throws {
        let rig = try await ConfiguredAmbientRig.make(capabilities: Self.capabilities)
        do {
            try await rig.rebind()
            #expect(rig.base.host.targetPolicy.snapshot(for: ConfiguredAmbientRig.target).binding == "s")
            for _ in 0..<4 {
                try await sendStart(rig, resume: true)
                try await noticeThenStop(rig)
                try await barrier(on: rig.pair.sockets[0], step: "no host retry or duplicate refusal")
                #expect(rig.sink.events.isEmpty)
                #expect(rig.router.liveRuns == 0)
                #expect(await rig.gate.activeStream == nil)
                #expect(await rig.base.adapter.deliveries.isEmpty)
            }
            // Owner approval alone does not start anything: only the device's next fresh admission can recover.
            _ = try await rig.base.host.allow(ConfiguredAmbientRig.target, tier: .open)
            try await barrier(on: rig.pair.sockets[0], step: "approval does not restart the host")
            #expect(rig.sink.events.isEmpty)
            try await sendStart(rig, resume: true, final: true)
            #expect(await eventually { await rig.base.adapter.deliveries.count == 1 })
            await boundedSettle(rig.router)
            #expect(await rig.base.adapter.deliveries.map(\.binding) == ["replacement"])
            #expect(try rig.scope().binding == "replacement")
            try await barrier(on: rig.pair.sockets[0], step: "approved restart has no refusal")
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test(arguments: [false, true])
    func midstreamMismatchWaitsForTheNoticeBeforeStoppingAndNeverReplays(reload: Bool) async throws {
        let ack = ClipGate()
        let rig = try await ConfiguredAmbientRig.make(
            behavior: RightyoAmbientPendingInputTests.twoRequests, capabilities: Self.capabilities,
            acknowledgementHold: ack.acknowledgement
        )
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            if reload {
                #expect(await rig.router.reload() == .reloaded)
                try #require(await eventually { rig.router.liveRuns == 1 })
            }
            let ended = rig.events.details("ambient_ended").count
            try await rig.rebind()
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            try #require(await eventually { ack.reached == 1 })
            try await barrier(on: rig.pair.sockets[0], step: "notice and stop both wait behind acknowledgement")
            #expect(rig.events.details("ambient_ended").count == ended)
            #expect(await rig.gate.activeStream == stream)
            ack.open()
            // The acknowledgement cannot acquire the rebound target's voice authority. Only the fixed notice goes out.
            try await noticeThenStop(rig)
            await boundedSettle(rig.router)
            #expect(await rig.gate.activeStream == nil)
            #expect(await rig.base.adapter.deliveries.isEmpty)
            #expect(rig.events.details("ambient_ended").last == "dispatch bindingMismatch")
            #expect(rig.events.details("ambient_delivery_refused")
                    == ["reason=bindingMismatch shown=sent confirm=suppressed_effects"])
            try await recover(rig, old: stream)
        } catch {
            ack.open()
            await rig.cleanUp()
            throw error
        }
        ack.open()
        await rig.cleanUp()
    }

    @Test func bindingMismatchUsesTheNoticeChainWithoutTargetAuthorityOrTargetVoice() async throws {
        let rig = try await ConfiguredAmbientRig.make(capabilities: Self.capabilities)
        let latch = MeetingLatch(), notices = AmbientRefusalNotices(), entered = Mutex(false)
        do {
            try await rig.rebind()
            _ = try await rig.base.host.deny(ConfiguredAmbientRig.target)
            notices.chain.enqueue {
                entered.withLock { $0 = true }
                await latch.wait()
            }
            let refused = rig.router.deliveryRefused(on: rig.connection, target: ConfiguredAmbientRig.target,
                                                     listener: rig.listener, notices: notices)
            let completion = refused(nil, .bindingMismatch)
            try #require(await eventually { entered.withLock { $0 } })
            try await barrier(on: rig.pair.sockets[0], step: "binding mismatch wording waits on request-refusal chain")
            latch.open()
            await bounded("fixed notice reaches transport") { await completion.value }
            let frame = try await receiveFrame(on: rig.pair.sockets[0], step: "fixed notice without binding grant")
            #expect(frame.payload == .control(Self.notice))
            try await barrier(on: rig.pair.sockets[0], step: "notice grants no target voice or stream restart")
            #expect(await rig.base.adapter.deliveries.isEmpty)
            #expect(!rig.base.host.targetPolicy.snapshot(for: ConfiguredAmbientRig.target).wasGranted)
            #expect(rig.router.liveRuns == 0)
        } catch {
            latch.open()
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test func aSelectedNonConfiguredTargetsMismatchKeepsItsExistingTerminalError() async throws {
        // Gate injection exercises the router's alternate selected-target seam, as its stream-target tests do.
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests,
            capabilities: Self.capabilities, routerTarget: VoiceRouteRig.deck)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            try await rig.rebind()
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            let frame = try await receiveFrame(on: rig.pair.sockets[0], step: "existing selected-target stop")
            #expect(frame.payload == .control(.error(code: .notAllowed,
                message: "ambient stopped: dispatch bindingMismatch")))
            await boundedSettle(rig.router)
            #expect(rig.events.details("ambient_delivery_refused").isEmpty)
            #expect(await rig.base.adapter.deliveries.isEmpty)
            try await barrier(on: rig.pair.sockets[0], step: "no configured-target notice for selected target")
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }
}

private extension AmbientSessionChangeNoticeTests {
    func recover(_ rig: ConfiguredAmbientRig, old stream: UUID) async throws {
        _ = try await rig.base.host.allow(ConfiguredAmbientRig.target, tier: .open)
        try RightyoAmbientPendingInputTests.release(rig.fake, "go2")
        #expect(!((await rig.segment(stream, 1)).frames.isEmpty))
        #expect(await rig.base.adapter.deliveries.isEmpty)
        try rewriteFake(rig.fake, ambientEchoAtEOF)
        try await sendStart(rig, resume: true, final: true)
        let words = try await receiveFrame(on: rig.pair.sockets[0], step: "approved target acknowledgement text")
        let pcm = try await receiveFrame(on: rig.pair.sockets[0], step: "approved target acknowledgement audio")
        guard case .text(let text) = words.payload else { throw TestSupportError.expectedOneControl }
        #expect(text.text == PendingInputRun.ack.text)
        guard case .audio(let audio) = pcm.payload else { throw TestSupportError.expectedOneControl }
        #expect(audio.bytes == PendingInputRun.ack.pcm)
        #expect(await eventually { await rig.base.adapter.deliveries.count == 1 })
        await boundedSettle(rig.router)
        #expect(await rig.base.adapter.deliveries.map(\.binding) == ["replacement"])
    }

    func sendStart(_ rig: ConfiguredAmbientRig, resume: Bool, final: Bool = false) async throws {
        var segment = ambientSegment(stream: UUID(), sequence: 0, isFinal: final)
        segment.isResume = resume
        try await recipientSocketSend(sessionFrame(target: ConfiguredAmbientRig.target, payload: .audio(segment)),
                                      on: rig.pair.sockets[0])
    }

    func noticeThenStop(_ rig: ConfiguredAmbientRig) async throws {
        let notice = try await receiveFrame(on: rig.pair.sockets[0], step: "session-change notice first")
        let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "session-change ending error second")
        #expect(notice.payload == .control(Self.notice))
        #expect(stop.payload == .control(Self.stopped))
    }
}
#endif
