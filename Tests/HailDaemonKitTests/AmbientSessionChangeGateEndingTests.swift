#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Gate refusals and real shutdown escalation with authored events, synthetic holds and loopback transport.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientSessionChangeGateEndingTests {
    @Test(arguments: [false, true])
    func gateRefusalRevokesAHeldNoticeAndReportsOnlyItsOwnEnding(malformed: Bool) async throws {
        let ack = ClipGate()
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests,
            capabilities: AmbientSessionChangeNoticeTests.capabilities, acknowledgementHold: ack.acknowledgement)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            try await rig.rebind()
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            try #require(await eventually { ack.reached == 1 })
            let attempt = try #require((try await rig.pendingSessionChanges()).first)
            if !malformed { _ = try await rig.base.host.deny(ConfiguredAmbientRig.target) }
            var segment = ambientSegment(stream: stream, sequence: 1)
            if malformed { segment.bytes = Data([0]) }
            try await recipientSocketSend(sessionFrame(target: ConfiguredAmbientRig.target, payload: .audio(segment)),
                                          on: rig.pair.sockets[0])
            let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "gate refusal owns the ending")
            if malformed {
                guard case .control(.error(let code, _, _)) = stop.payload else {
                    throw TestSupportError.expectedOneControl
                }
                #expect(code == .malformed)
            } else {
                #expect(stop.payload == .control(.error(code: .notAllowed, message: "ambient target_policy_changed")))
            }
            #expect(!attempt.isOpen)
            #expect(await rig.gate.activeStream == nil)
            ack.open()
            await boundedSettle(rig.router)
            #expect(rig.router.liveRuns == 0)
            #expect(!rig.router.isLatest(stream: stream, connection: rig.connection))
            #expect(await rig.base.adapter.deliveries.isEmpty)
            try await barrier(on: rig.pair.sockets[0], step: "revoked notice and cleanup send nothing after refusal")
        } catch {
            ack.open()
            await rig.cleanUp()
            throw error
        }
        ack.open()
        await rig.cleanUp()
    }

    @Test func productionShutdownTimingsReleaseTheSlotAndGateWithinTheTotalBound() async throws {
        let ack = ClipGate()
        let timing = RightyoChildProcess.Timing()
        let rig = try await ConfiguredAmbientRig.make(behavior: Self.ignoresEOFAndTERM,
            capabilities: AmbientSessionChangeNoticeTests.capabilities, acknowledgementHold: ack.acknowledgement,
            noticeTimeout: AmbientRightyoRouter.sessionChangeNoticeDeadline, timing: timing)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            try await rig.rebind()
            let began = ContinuousClock.now
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            try #require(await eventually { ack.reached == 1 })
            let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "production shutdown releases stream")
            #expect(stop.payload == .control(AmbientSessionChangeNoticeTests.stopped))
            // stop() bounds EOF + TERM + process-group settling, not just the five seconds until SIGKILL.
            let total = AmbientRightyoRouter.sessionChangeNoticeDeadline + timing.eofGrace + 3 * timing.termGrace + 1
            #expect(total == 12)
            #expect(began.duration(to: .now) < .seconds(total))
            #expect(began.duration(to: .now) >= .seconds(timing.eofGrace))
            #expect(rig.router.liveRuns == 0)
            #expect(await rig.gate.activeStream == nil)
            ack.open()
            try await barrier(on: rig.pair.sockets[0], step: "expired notice stays silent after SIGKILL")
            #expect(await rig.base.adapter.deliveries.isEmpty)
            // A new owner-approved start can use the released capacity and gate.
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

    static let ignoresEOFAndTERM = #"""
        trap '' TERM
        /usr/bin/sed -n -e '1,3p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        while [ ! -f go1 ]; do /bin/sleep 0.02; done
        /usr/bin/sed -n -e '4,6p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        while :; do /bin/sleep 0.02; done
        """#
}
#endif
