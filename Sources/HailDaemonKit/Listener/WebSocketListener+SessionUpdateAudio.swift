#if os(macOS)
import Foundation
import HailProtocol
import Synchronization

extension WebSocketListener {
    /// Source configuration only; this neither creates output directories nor starts a child or listening stream.
    public func configureSessionUpdateSpeech(_ renderer: any SessionUpdateSpeechRendering) {
        sessionUpdateFence.configure(renderer)
    }

    public var sessionUpdateSpeechStatus: String { sessionUpdateFence.speechStatus }
}

private final class SessionUpdateAudioProgress: Sendable {
    private struct State { var sequence = 0, bytes = 0; var final = false }
    private let state = Mutex(State())
    func reserve(_ bytes: Data, final: Bool) throws -> Int {
        try state.withLock { value in
            guard !value.final, bytes.count <= 24_000, bytes.count.isMultiple(of: 2),
                  value.bytes + bytes.count <= 60 * 48_000, value.sequence < 121,
                  !bytes.isEmpty || final else { throw SessionUpdateSpeechError.invalidAudio }
            defer { value.sequence += 1; value.bytes += bytes.count; value.final = final }
            return value.sequence
        }
    }
}

struct SessionUpdateSpeechDelivery: Sendable {
    let admission: SessionUpdateAdmission
    let lastInput: LastInputLedger.Entry?
    let privacyRevision: UInt64
    let hold: PrivateReplyHold
    let ambient: (any AmbientListenerWiring)?
    let fence: SessionUpdateFence
}

extension WebSocketPeer {
    /// Card delivery is distinct from speech. The renderer is asynchronous and joins cleanup; each audio frame
    /// retains the card's exact connection/selection/policy/binding/privacy epoch. No generic reply routing runs.
    func speakSessionUpdate(
        _ update: SessionUpdate, delivery: SessionUpdateSpeechDelivery, renderer: any SessionUpdateSpeechRendering
    ) async {
        let (admission, lastInput) = (delivery.admission, delivery.lastInput)
        let (hold, ambient, fence) = (delivery.hold, delivery.ambient, delivery.fence)
        let privacyRevision = delivery.privacyRevision
        let stream = UUID(), progress = SessionUpdateAudioProgress()
        let descriptor = ReplyDescriptor(id: update.id, hostID: admission.frame.source, targetID: update.session,
            audioStreamID: stream, priority: .background, interruption: .enqueue, sessionUpdateID: update.id)
        guard fence.remember(.init(update: update.id, connection: session.connectionID,
            privacyRevision: privacyRevision, frame: admission.frame)) else { return }
        do {
            // Re-check before spawning; the frame's final enqueue repeats the same proof after every await.
            guard !Task.isCancelled, !ended, await session.peerCapabilities.contains(SessionUpdateCard.audioCapability),
                  await session.enqueueSessionUpdate(admission, lastInput: lastInput, enqueue: {
                      fence.enqueue {
                          let admit: @Sendable () -> Bool = {
                              hold.unlessAnyHeld(expectedRevision: privacyRevision) { true }
                          }
                          return ambient?.withSessionUpdatePermission(connection: self.session.connectionID,
                                                                     enqueue: admit) ?? admit()
                      }
                  }) else { return }
            try await renderer.render(update.spoken) { bytes, final in
                let sequence = try progress.reserve(bytes, final: final)
                var frame = admission.frame
                frame.id = UUID()
                frame.payload = .audio(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                    sequence: sequence, streamID: stream, isFinal: final, bytes: bytes, reply: descriptor))
                guard await self.enqueueSessionUpdateAudio(frame, delivery: delivery) else {
                    throw SessionUpdateSpeechError.publicationRefused
                }
                if sequence == 0 {
                    var echo = frame
                    echo.payload = .text(TextPayload(text: update.spoken, reply: descriptor))
                    ambient?.observeReply(echo)
                }
            }
        } catch {
            // The card remains delivered. A renderer/publication error is never hearing proof or retry authority.
        }
    }

    private func enqueueSessionUpdateAudio(
        _ frame: Frame, delivery: SessionUpdateSpeechDelivery
    ) async -> Bool {
        let (admission, lastInput) = (delivery.admission, delivery.lastInput)
        let (hold, ambient, fence) = (delivery.hold, delivery.ambient, delivery.fence)
        let privacyRevision = delivery.privacyRevision
        guard !Task.isCancelled, !ended,
              let prepared = await prepareReplyPublication(frame, onLateSuccess: { ambient?.observeReply(frame) }),
              await session.enqueueSessionUpdate(admission, lastInput: lastInput, enqueue: {
                  fence.enqueue {
                      let enqueue: @Sendable () -> Bool = {
                          hold.unlessAnyHeld(expectedRevision: privacyRevision) { prepared.enqueue() }
                      }
                      return ambient?.withSessionUpdatePermission(connection: self.session.connectionID,
                                                                 enqueue: enqueue) ?? enqueue()
                  }
              }) else { return false }
        guard replySendSucceeded(await prepared.result()) else { return false }
        ambient?.observeReply(frame)
        return true
    }
}
#endif
