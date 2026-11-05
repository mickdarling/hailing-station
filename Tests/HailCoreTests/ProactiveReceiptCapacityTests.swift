import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ProactiveReceiptCapacityTests {
    @Test(arguments: [true, false])
    func privatePressureCannotReviveARetiredOrInitiallyDeniedUpdate(_ acceptedBeforePrivacy: Bool) async throws {
        try await withRig { rig in
            let original = rig.reply()
            if acceptedBeforePrivacy {
                rig.record(original)
                #expect(rig.permits(original))
                #expect(rig.entry(original)?.spoken == false, "retire the card before its first audio arrives")
            }
            rig.privacy(true)
            if !acceptedBeforePrivacy { rig.record(original) }
            let visibleBeforePressure = rig.store.conversation.entries.count
            for _ in 0..<ConversationLog.limit { rig.record(rig.reply()) }
            #expect(rig.store.conversation.entries.count == visibleBeforePressure, "private cards are dropped")
            #expect(rig.store.proactiveSpeechReceipts.count == ConversationLog.limit)
            #expect(rig.store.proactiveSpeechReceipts.contains { $0.update == original.id && !$0.allowed })
            rig.privacy(false)
            rig.record(original)
            #expect(rig.store.conversation.entries.count == 1)
            #expect(rig.entry(original)?.text == "Synthetic build finished.")
            assertNoSpeech(original, rig: rig)
            rig.ordinaryReply()
            #expect(rig.player.scheduled.map(\.bytes.first) == [2])
            #expect(rig.player.cancelCount == 0)
            try #require(!rig.player.scheduled.isEmpty)
            rig.player.completeReply()
        }
    }

    @Test func capacityDeclinesNewSpeechWithoutHidingItsCardOrDisablingKnownAndOrdinaryAudio() async throws {
        try await withRig { rig in
            let known = rig.reply()
            for _ in 1..<ConversationLog.limit { rig.record(rig.reply()) }
            rig.record(known)
            #expect(rig.store.proactiveSpeechReceipts.count == ConversationLog.limit)
            #expect(rig.permits(known))
            let overflow = rig.reply()
            rig.record(overflow)
            #expect(rig.entry(overflow)?.text == "Synthetic build finished.")
            assertNoSpeech(overflow, rig: rig)
            #expect(rig.permits(known), "pressure cannot evict a valid retained receipt")
            rig.ordinaryReply()
            rig.offerAudio(known, byte: 3)
            #expect(rig.player.scheduled.map(\.bytes.first) == [2])
            try #require(rig.player.scheduled.count == 1)
            rig.player.completeReply()
            #expect(rig.player.scheduled.map(\.bytes.first) == [2, 3])
            #expect(rig.entry(known)?.spoken == true && rig.entry(overflow)?.spoken == false)
            #expect(rig.player.cancelCount == 0)
            try #require(rig.player.scheduled.count == 2)
            rig.player.completeReply()
            checkCapacitySurvivesPolicyEdges(overflow, known: known, rig: rig)
        }
    }

    private func assertNoSpeech(_ descriptor: ReplyDescriptor, rig: ProactiveReceiptCapacityRig) {
        #expect(!rig.permits(descriptor))
        rig.offerAudio(descriptor)
        #expect(rig.player.scheduled.isEmpty && rig.playback.queue.isEmpty)
        #expect(rig.entry(descriptor)?.spoken == false)
        #expect(rig.store.replyFrames.isEmpty, "marked audio must not fall through as an ordinary reply")
    }

    private func checkCapacitySurvivesPolicyEdges(
        _ overflow: ReplyDescriptor, known: ReplyDescriptor, rig: ProactiveReceiptCapacityRig
    ) {
        rig.privacy(true)
        rig.privacy(false)
        rig.store.ambientStreaming = false
        rig.store.ambientStreaming = true
        rig.record(overflow)
        rig.record(known)
        #expect(!rig.permits(overflow) && !rig.permits(known))
        #expect(rig.store.proactiveSpeechReceipts.count == ConversationLog.limit)
        #expect(rig.store.proactiveSpeechReceipts.allSatisfy { !$0.allowed })
        #expect(rig.entry(overflow) != nil && rig.entry(known) != nil)
    }

    private func withRig(operation: (ProactiveReceiptCapacityRig) throws -> Void) async throws {
        let rig = try await ProactiveReceiptCapacityRig.make()
        do {
            try operation(rig)
            await rig.store.disconnect(rig.endpoint)
        } catch {
            await rig.store.disconnect(rig.endpoint)
            throw error
        }
        #expect(rig.store.proactiveSpeechReceipts.count <= ConversationLog.limit)
    }
}
