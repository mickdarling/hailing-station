import Foundation
import Testing
@testable import HailCore

@Suite("Owned fresh speech promotion and cue revocation") @MainActor
struct CoachingSpeechConsumerTests {
    @Test func promotionPreservesOriginalExpiryAndOnlyItsOwnedResultCanPlayAcrossRenewal() throws {
        let rig = CoachingTestHarness(), consumer = try coachingConsumer(rig)
        var lease = try rig.begin()
        try consumer.register(lease)
        let original = try consumer.admit(coachingWireData(lease))
        let speech = try consumer.prepareSpeech(original)
        #expect(speech.ticket.qualification == original.ticket.qualification)
        #expect(speech.ticket.expiresAt == rig.time.instant.advanced(by: .seconds(18)))
        #expect(throws: (any Error).self) { try consumer.prepareSpeech(original) }
        #expect(throws: (any Error).self) { try consumer.prepareSpeech(speech) }
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.schedule(coachingPCM, for: original) }
        for _ in 0..<17 {
            rig.time.advance(.seconds(1)); lease = try rig.session.renew(lease); try consumer.register(lease)
            try consumer.schedule(coachingPCM, for: speech)
            rig.player.completions.last?()
        }
        rig.time.advance(.seconds(1))
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.schedule(coachingPCM, for: speech) }
        consumer.stop()
    }

    @Test func expiredUnpromotedReceiptAndForeignConsumerCannotGainSpeechTime() throws {
        let rig = CoachingTestHarness(), consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        let original = try consumer.admit(coachingWireData(lease, ttl: 100))
        let foreign = try coachingConsumer(rig)
        try foreign.register(lease)
        #expect(throws: CoachingWireError.staleAdvice) { try foreign.prepareSpeech(original) }
        rig.time.advance(.milliseconds(100))
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.prepareSpeech(original) }
        consumer.stop()
    }

    @Test func cueRevocationKeepsCaptureAndReplayFenceButOldSpeechCannotResume() throws {
        let rig = CoachingTestHarness(), consumer = try coachingConsumer(rig)
        let lease = try rig.begin(), request = UUID()
        try consumer.register(lease)
        let original = try consumer.admit(coachingWireData(lease, requestID: request))
        let speech = try consumer.prepareSpeech(original)
        try consumer.schedule(coachingPCM, for: speech)
        consumer.interruptSpeech()
        #expect(rig.session.qualification == lease && rig.capture.stopCount == 0)
        #expect(rig.session.pendingPlayback.isEmpty)
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.resume(speech) }
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.prepareSpeech(original) }
        #expect(throws: CoachingWireError.replay) { try consumer.admit(coachingWireData(lease, requestID: request)) }
        let fresh = try consumer.prepareSpeech(consumer.admit(coachingWireData(lease)))
        try consumer.schedule(coachingPCM, for: fresh)
        consumer.stop()
    }

    @Test(arguments: [0, 1, 2], [2, 3, 4])
    func interruptionInsideFinalConsumptionValidationCannotPublishRevokedAdvice(
        operation: Int, observation: Int
    ) throws {
        let rig = CoachingTestHarness(), consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        let speech = try consumer.prepareSpeech(consumer.admit(coachingWireData(lease)))
        var observations = 0
        rig.onObserve = {
            observations += 1
            if observations == (operation == 0 ? observation : min(observation, 3)) { consumer.interruptSpeech() }
        }
        #expect(throws: (any Error).self) {
            switch operation {
            case 0: try consumer.schedule(coachingPCM, for: speech)
            case 1: try consumer.resume(speech)
            default: try consumer.setMuted(false, for: speech)
            }
        }
        #expect(rig.player.scheduled.isEmpty && rig.player.resumed == 0 && rig.player.mutes.isEmpty)
        #expect(rig.capture.stopCount == 0 && rig.session.pendingPlayback.isEmpty)
        rig.onObserve = nil
        consumer.stop()
    }

    @Test func interruptionDuringAdmissionOrPromotionCannotPublishOldAuthority() throws {
        for promoting in [false, true] {
            let rig = CoachingTestHarness(), consumer = try coachingConsumer(rig)
            let lease = try rig.begin()
            try consumer.register(lease)
            let original = try consumer.admit(coachingWireData(lease))
            var interrupted = false
            rig.onObserve = {
                guard !interrupted else { return }
                interrupted = true
                consumer.interruptSpeech()
            }
            #expect(throws: (any Error).self) {
                if promoting {
                    _ = try consumer.prepareSpeech(original)
                } else {
                    _ = try consumer.admit(coachingWireData(lease))
                }
            }
            #expect(rig.capture.stopCount == 0 && rig.session.qualification != nil)
            rig.onObserve = nil
            consumer.stop()
        }
    }
}
