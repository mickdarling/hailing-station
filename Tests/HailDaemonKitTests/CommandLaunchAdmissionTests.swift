#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct CommandLaunchAdmissionTests {
    @Test func launchEvidenceDistinguishesRefusalFailureAndExecution() async throws {
        let runner = ProcessCommandRunner()
        let refused = CommandLaunch { _ in throw DeliveryAdmissionError.unsupported }
        await #expect(throws: DeliveryAdmissionError.unsupported) {
            try await runner.run("/usr/bin/true", [], launch: refused)
        }
        #expect(refused.evidence == .refused)
        let failed = CommandLaunch { try $0() }
        await #expect(throws: (any Error).self) {
            try await runner.run("/nonexistent/synthetic-executable", [], launch: failed)
        }
        #expect(failed.evidence == .failedBeforeExecution)
        let after = CommandLaunch { operation in
            try operation()
            throw HostError.denied(.notAllowed("synthetic"))
        }
        await #expect(throws: HostError.denied(.notAllowed("synthetic"))) {
            try await runner.run("/usr/bin/true", [], launch: after)
        }
        #expect(after.evidence == .possiblyExecuted)
    }

    @Test func operationErrorsReturnAfterHeldPredicateEvaluation() async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let id = try await rig.hold()
        let entry = try #require(await rig.host.heldRequests.entries[id])
        let current = Mutex(true)
        let scope = stageOrderHeldScope(entry, recorder: DeliveryStageRecorder(),
                                        selected: { current.withLock { $0 } })
        let authority = RetainedDeliveryStages().composed(policy: entry.policy, held: scope)
        let launch = CommandLaunch { try authority.admit($0) }
        let error = HostError.denied(.notAllowed(FinalDeliveryRig.target))
        #expect(throws: error) {
            try launch.perform {
                current.withLock { $0 = false }
                throw error
            }
        }
        #expect(launch.evidence == .failedBeforeExecution)
        await rig.listener.stop()
    }

    @Test func submissionTicketAllowsOnlyItsFixedCompletionBudget() throws {
        let control = TmuxDeliveryControl(target: "codex", authority: nil)
        let session = TmuxAdapter.Session(id: "$2", created: "1758230001", paneID: "%2", panePID: "502", name: "codex")
        let ticket = TmuxSubmissionTicket(delivery: control.id, executable: "synthetic", base: ["-L", "fixture"],
                                           session: session, buffer: "hail-fixed", payload: "synthetic input")
        try control.prepare(ticket)
        let other = TmuxDeliveryControl(target: "codex", authority: nil)
        #expect(throws: DeliveryAdmissionError.invalidGate) { try other.prepare(ticket) }
        #expect(throws: DeliveryAdmissionError.invalidGate) {
            try ticket.complete(executable: "synthetic", base: ["-L", "fixture"], pane: "%2") {}
        }
        try ticket.admit {}
        #expect(throws: DeliveryAdmissionError.invalidGate) { try ticket.admit {} }
        #expect(throws: DeliveryAdmissionError.invalidGate) {
            try ticket.complete(executable: "synthetic", base: ["-L", "other"], pane: "%2") {}
        }
        #expect(throws: DeliveryAdmissionError.invalidGate) {
            try ticket.complete(executable: "synthetic", base: ["-L", "fixture"], pane: "%3") {}
        }
        var enters = 0
        for _ in 0..<2 {
            try ticket.complete(executable: "synthetic", base: ["-L", "fixture"], pane: "%2") { enters += 1 }
        }
        #expect(throws: DeliveryAdmissionError.invalidGate) {
            try ticket.complete(executable: "synthetic", base: ["-L", "fixture"], pane: "%2") { enters += 1 }
        }
        #expect(enters == 2)
        #expect(ticket.payload == "synthetic input")
        #expect(ticket.buffer == "hail-fixed")
        #expect(ticket.binding == SlowTmuxCommandFixture.binding)
    }

    @Test func productionLaunchGateHoldMeasurements() async throws {
        let runner = ProcessCommandRunner()
        var samples: [Double] = []
        for _ in 0..<60 {
            let elapsed = Mutex(Duration.zero)
            let launch = CommandLaunch { operation in
                let start = ContinuousClock.now
                try operation()
                elapsed.withLock { $0 = start.duration(to: .now) }
            }
            let result = try await runner.run("/usr/bin/true", [], launch: launch)
            #expect(result.exitCode == 0)
            let value = elapsed.withLock { $0.components }
            samples.append(Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15)
        }
        samples.sort()
        let median = (samples[29] + samples[30]) / 2
        let message = "Process.run gate hold ms n=60 min=\(samples[0]) median=\(median) p95=\(samples[56]) max=\(samples[59])"
        print(message)
    }
}
#endif
