import Foundation
import HailCore
import HailDaemonKit
import Testing
@testable import haild
@testable import HailCoaching

@Suite(.serialized) @MainActor struct CoachingTransportRegressionTests {
    @Test func explicitHostedTextProviderOptionsReachOnlyExistingOwnedChildArgv() async throws {
        let rig = try CoachingTransportRig(tail: "", hosted: true)
        try await rig.run()
        let arguments = try String(contentsOf: rig.argumentsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--coaching-provider") && arguments.contains("jev"))
        #expect(arguments.contains("--coaching-allow-hosted-text") && arguments.contains("--coaching-max-requests"))
        #expect(arguments.contains("20") && arguments.contains("--coaching-advice-catalog"))
        #expect(!arguments.contains("--allow-hosted") && !arguments.contains("--use-jev"))
        #expect(rig.driver.status == .active && rig.player.played == 0)
        try await rig.join()
    }
    @Test func supportedDescriptiveVoiceNeverGrantsActivityOrRetiresOwner() async throws {
        let rig = try CoachingTransportRig(tail: """
        printf '{"schema_version":1,"type":"owner_voice","session_id":"%s",\
        "sequence":2,"emitted_at_ms":0,"state":"recognized"}\\n' "$session"
        """)
        try await rig.run()
        #expect(rig.driver.status == .active && rig.capture.stops == 0)
        #expect(rig.flagsCalls == 0 && rig.transport?.finalCount == 0 && rig.player.played == 0)
        try await rig.join()
    }

    @Test(arguments: ["heartbeat", "buffer", "ticket"])
    func delayedCallbacksCannotReviveTheExpiredOwnedFixture(effect: String) async throws {
        // Both timer deliveries are deliberately withheld. Original-deadline effect checks must suffice.
        let rig = try CoachingTransportRig(tail: "", deferExpiry: true)
        try rig.driver.enable(participantAwareness: true)
        let lease = try #require(rig.audio?.session.qualification)
        let heartbeat = try #require(rig.heartbeat)
        #expect(rig.driver.status == .active)
        try await Task.sleep(until: lease.expiresAt.advanced(by: .milliseconds(100)), clock: .continuous)
        switch effect {
        case "heartbeat": heartbeat()
        case "buffer": try rig.capture.send(tone: true)
        default:
            #expect(throws: CoachingSafetyError.staleQualification) {
                try rig.audio?.session.ticket(requestID: UUID())
            }
        }
        // Buffer delivery and owned child joining are asynchronous; property snapshots are not authority.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while rig.driver.status != .off, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.audio?.session.qualification == nil && rig.capture.stops > 0)
        #expect(rig.driver.status == .off && rig.player.played == 0)
        #expect(rig.counts.qualifications == 1 && rig.counts.buffers == 0)
        heartbeat() // Even duplicate old callbacks cannot mint a fresh lease after retirement.
        #expect(rig.driver.status == .off && rig.counts.qualifications == 1)
    }

    @Test func renewalInsideActivityCallbackHoldsOldFinalWithoutRetiringRenewedOwner() async throws {
        let rig = try CoachingTransportRig(tail: CoachingTransportRig.final, renew: true)
        var failure: (any Error)?
        do {
            try await rig.run()
            let original = try #require(rig.original) // Receipt stays bounded by the original live lease.
            while rig.transport?.finalCount == 0, ContinuousClock.now < original.expiresAt {
                let next = min(original.expiresAt, ContinuousClock.now.advanced(by: .milliseconds(10)))
                try await Task.sleep(until: next, clock: .continuous)
            }
            #expect(rig.flagsCalls == 1 && rig.transport?.finalCount == 1)
            #expect(rig.driver.status == .active && rig.capture.stops == 0 && rig.player.played == 0)
            #expect(rig.audio?.session.qualification != rig.original)
        } catch { failure = error }
        let cleanup = Task { try await rig.join() } // Independent cancellation; join the same owned fixture.
        try await cleanup.value
        if let failure { throw failure }
    }

    @Test func callbackOffCannotPublishActivityOrPlayback() async throws {
        let rig = try CoachingTransportRig(tail: CoachingTransportRig.final, off: true)
        try await rig.run()
        #expect(rig.flagsCalls == 1 && rig.driver.status != .active && rig.player.played == 0)
        try await rig.join()
    }

    @Test func actionWrongSequenceAndDuplicateFinalStillRetire() async throws {
        let action = """
        printf '{"schema_version":1,"type":"request","session_id":"%s","sequence":2,"emitted_at_ms":0}\\n' "$session"
        """
        for tail in [action, CoachingTransportRig.final.replacingOccurrences(of: "\"sequence\":2",
                                                                             with: "\"sequence\":9"),
                     CoachingTransportRig.final + "\n" + CoachingTransportRig.final.replacingOccurrences(
                        of: "\"sequence\":2", with: "\"sequence\":3")] {
            let rig = try CoachingTransportRig(tail: tail)
            try await rig.run()
            #expect(rig.driver.status != .active && rig.player.played == 0)
            try await rig.join()
        }
    }

    @Test func convertedVoiceAndValidatedNewFinalRevokeSpeechWithoutClosingCapture() async throws {
        for tail in ["", CoachingTransportRig.final] {
            let rig = try CoachingTransportRig(tail: tail)
            try await rig.run()
            #expect(rig.contextRevocations == (tail.isEmpty ? 1 : 2))
            #expect(rig.driver.status == .active && rig.capture.stops == 0)
            try await rig.join()
        }
    }

    @Test func profileIntegersRejectBooleanAndFloatingScalarsBeforeChildStart() throws {
        for field in ["version", "priority", "cooldown_ms"] {
            for value in ["true", "false", "1.0", "1.5"] {
                let original = field == "version" ? "1" : "0"
                let data = Data(CoachingTransportRig.profile.replacingOccurrences(
                    of: "\"\(field)\":\(original)", with: "\"\(field)\":\(value)").utf8)
                #expect(throws: CoachingChildError.invalidControl) {
                    try CoachingChildCodec.profile(data, listenerID: "coach")
                }
            }
        }
    }
}
