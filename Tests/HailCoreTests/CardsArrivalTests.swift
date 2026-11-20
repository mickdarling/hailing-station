import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CardsArrivalTests {
    @Test(arguments: ["privacy", "duck", "media"])
    func silentAndSpokenCardsDisplayWhileSpeechStaysDenied(mode: String) async throws {
        let rig = try await CardsArrivalRig.make()
        let request: Task<Void, any Error>?
        if mode == "privacy" {
            await rig.socket.holdSends()
            request = Task { try await rig.store.setPrivacy(on: true, host: rig.endpoint.id) }
            await arrivalObserved { rig.store.privacyLocal[rig.endpoint.id]?.request?.on == true }
        } else {
            request = nil
            rig.notice(mode == "duck" ? .duckMode(on: true, reason: "device") : .mediaMode(on: true, reason: "voice"))
        }
        var ingress = 0
        rig.store.onReplyFrame = { _ in ingress += 1 }
        for spoken in [false, true] {
            let descriptor = rig.descriptor()
            rig.receive(descriptor)
            #expect(!rig.store.permitsProactiveSpeech(rig.endpoint.id, generation: rig.generation,
                                                     descriptor: descriptor))
            if spoken {
                HostNoticeOrigin.$generation.withValue(rig.generation) {
                    _ = rig.store.receiveSessionUpdateSpeech(idleAudio(descriptor, sequence: 0, final: true,
                                                                      byte: 1, endpoint: rig.endpoint.id))
                }
            }
        }
        #expect(rig.store.conversation.entries.count == 2)
        #expect(rig.store.conversation.entries.allSatisfy { !$0.spoken && $0.text == "Synthetic decision." })
        #expect(rig.store.proactiveSpeechReceipts.allSatisfy { !$0.allowed })
        #expect(ingress == 0 && rig.store.replyFrames.isEmpty)
        if mode != "privacy" {
            rig.notice(mode == "duck" ? .duckMode(on: false, reason: "device") : .mediaMode(on: false, reason: "voice"))
            #expect(rig.store.proactiveSpeechReceipts.allSatisfy { !$0.allowed })
        }
        await rig.socket.releaseSends()
        try await request?.value
        await rig.store.disconnect(rig.endpoint.id)
    }

    @Test func reconnectPendingDoesNotHideReadyCardsOrAuthorizeTheirSpeech() async throws {
        let rig = try await CardsArrivalRig.make()
        let capture = FakeAudioCapture()
        let controller = AmbientListeningController(requestPermission: { true },
            makeStreamer: { AmbientAudioStreamer(capture: capture, send: $0) }, releaseSession: {}, send: { _, _ in })
        rig.store.ambientController = controller
        let binding = AmbientAudioBinding(hostID: rig.endpoint.id, targetID: CardsArrivalRig.target.id,
                                          connectionGeneration: rig.generation, selection: 0)
        await controller.turnOn(for: binding)
        controller.reconnect.drop(try #require(rig.store.snapshots[rig.endpoint.id]), store: rig.store)
        #expect(controller.reconnect.isPending)
        let descriptor = rig.descriptor()
        rig.receive(descriptor)
        #expect(rig.store.conversation.entries.count == 1)
        #expect(!rig.store.permitsProactiveSpeech(rig.endpoint.id, generation: rig.generation, descriptor: descriptor))
        #expect(rig.store.proactiveSpeechReceipts.first?.allowed == false)
        await controller.turnOff()
        await rig.store.disconnect(rig.endpoint.id)
    }

    @Test func spokenCardHasTextImmediatelyAndStillRequiresAmbientAndExactIdentity() async throws {
        let rig = try await CardsArrivalRig.make()
        let descriptor = rig.descriptor()
        rig.receive(descriptor)
        #expect(rig.store.conversation.entries.first?.text == "Synthetic decision.")
        #expect(rig.store.permitsProactiveSpeech(rig.endpoint.id, generation: rig.generation, descriptor: descriptor))
        #expect(!rig.store.permitsProactiveSpeech(rig.endpoint.id, generation: UUID(), descriptor: descriptor))
        let wrong = ReplyDescriptor(id: descriptor.id, hostID: "other", targetID: descriptor.targetID,
                                    audioStreamID: descriptor.audioStreamID, priority: .background,
                                    sessionUpdateID: descriptor.id)
        #expect(!rig.store.permitsProactiveSpeech(rig.endpoint.id, generation: rig.generation, descriptor: wrong))
        rig.store.ambientStreaming = false
        #expect(!rig.store.permitsProactiveSpeech(rig.endpoint.id, generation: rig.generation, descriptor: descriptor))
        await rig.store.disconnect(rig.endpoint.id)
    }
}
