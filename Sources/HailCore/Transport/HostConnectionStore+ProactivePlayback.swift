import Foundation
import HailProtocol
import Observation

struct SessionUpdateSpeechReceipt {
    let endpoint: HostEndpoint.Identifier
    let update: UUID
    let generation: UUID
    let source: String
    let target: String
    var allowed: Bool
}

extension HostConnectionStore {
    func permitsSessionUpdate(_ event: HostReplyEvent) -> Bool {
        guard let snapshot = snapshots[event.endpointID], snapshot.state == .ready,
              snapshot.capabilities.contains(SessionUpdateCard.capability),
              HostNoticeOrigin.generation == snapshot.connectionGeneration,
              duckMode[event.endpointID]?.isOn() != true,
              privacyLocal[event.endpointID]?.request?.on != true,
              ambientController?.reconnect.isPending != true,
              let target = event.frame.target,
              snapshot.targets.contains(where: { $0.id == target && $0.alive }) else { return false }
        return true
    }

    func recordSessionUpdateSpeech(_ event: HostReplyEvent, allowed: Bool) {
        guard case .control(.sessionUpdate(let update, _, _, _, _)) = event.frame.payload,
              let generation = HostNoticeOrigin.generation,
              snapshots[event.endpointID]?.connectionGeneration == generation,
              let target = event.frame.target else { return }
        let speechAllowed = allowed && ambientStreaming && mediaMode[event.endpointID]?.on != true
        if let index = proactiveSpeechReceipts.firstIndex(where: {
            $0.endpoint == event.endpointID && $0.update == update
        }) {
            // A duplicate or reconnect never renews a retired audio permit.
            let old = proactiveSpeechReceipts[index]
            proactiveSpeechReceipts[index].allowed = old.allowed && speechAllowed && old.generation == generation
                && old.target == target && old.source == event.frame.source
        } else {
            proactiveSpeechReceipts.append(.init(endpoint: event.endpointID, update: update, generation: generation,
                source: event.frame.source, target: target, allowed: speechAllowed))
            if proactiveSpeechReceipts.count > ConversationLog.limit { proactiveSpeechReceipts.removeFirst() }
        }
        proactivePolicyRevision &+= 1
    }

    /// The explicit marker makes unknown, suppressed or evicted receipts fail closed rather than ordinary audio.
    func permitsProactiveSpeech(
        _ endpoint: HostEndpoint.Identifier, generation: UUID, descriptor: ReplyDescriptor
    ) -> Bool {
        guard let update = descriptor.sessionUpdateID,
              let snapshot = snapshots[endpoint], snapshot.state == .ready,
              snapshot.connectionGeneration == generation,
              snapshot.capabilities.contains(SessionUpdateCard.audioCapability), ambientStreaming,
              duckMode[endpoint]?.isOn() != true, privacyLocal[endpoint]?.request?.on != true,
              mediaMode[endpoint]?.on != true, ambientController?.reconnect.isPending != true,
              snapshot.targets.contains(where: { $0.id == descriptor.targetID && $0.alive }),
              proactiveSpeechReceipts.contains(where: {
                  $0.endpoint == endpoint && $0.update == update && $0.generation == generation && $0.allowed
                      && $0.source == descriptor.hostID && $0.target == descriptor.targetID
              }) else { return false }
        return true
    }

    /// A card supplies the transcript. Marked speech text cannot create a second reply or satisfy an old request.
    func receiveSessionUpdateSpeech(_ event: HostReplyEvent) -> Bool {
        if case .control(.sessionUpdateCancel(let update)) = event.frame.payload {
            revokeSessionUpdateSpeech(update, event: event)
            return true
        }
        let descriptor: ReplyDescriptor?
        switch event.frame.payload {
        case .text(let text): descriptor = text.reply
        case .audio(let audio): descriptor = audio.reply
        default: descriptor = nil
        }
        guard let descriptor, descriptor.sessionUpdateID != nil else { return false }
        guard case .audio = event.frame.payload, let generation = HostNoticeOrigin.generation,
              permitsProactiveSpeech(event.endpointID, generation: generation, descriptor: descriptor) else {
            return true
        }
        conversation.noteSessionUpdateAudio(endpoint: event.endpointID, update: descriptor.id)
        onReplyFrame?(event)
        return true
    }

    private func revokeSessionUpdateSpeech(_ update: UUID, event: HostReplyEvent) {
        guard let snapshot = snapshots[event.endpointID], snapshot.state == .ready,
              snapshot.capabilities.contains(SessionUpdateCard.audioCapability),
              HostNoticeOrigin.generation == snapshot.connectionGeneration,
              let index = proactiveSpeechReceipts.firstIndex(where: {
                  $0.endpoint == event.endpointID && $0.update == update
                      && $0.generation == snapshot.connectionGeneration
                      && $0.source == event.frame.source && $0.target == event.frame.target
              }) else { return }
        proactiveSpeechReceipts[index].allowed = false
        proactivePolicyRevision &+= 1
    }

    /// Record the edge synchronously. An on/off burst cannot coalesce into a new permit for old audio.
    func revokeProactiveSpeech(_ endpoint: HostEndpoint.Identifier?) {
        for index in proactiveSpeechReceipts.indices where endpoint == nil
            || proactiveSpeechReceipts[index].endpoint == endpoint {
            proactiveSpeechReceipts[index].allowed = false
        }
        proactivePolicyRevision &+= 1
    }

    /// Installs exact receipt authorization and event-based policy retirement; no capture or host feature is enabled.
    public func wireProactivePlayback(_ playback: ReplyPlaybackController) {
        playback.proactive.authorize = { [weak self] endpoint, generation, descriptor in
            self?.permitsProactiveSpeech(endpoint, generation: generation, descriptor: descriptor) == true
        }
        observeProactivePolicy(playback)
    }

    private func observeProactivePolicy(_ playback: ReplyPlaybackController) {
        withObservationTracking {
            _ = (snapshots, duckMode, privacyLocal, mediaMode, ambientStreaming, proactivePolicyRevision)
        } onChange: { [weak self, weak playback] in
            Task { @MainActor in
                guard let self, let playback else { return }
                self.retireInvalidSpeechReceipts()
                playback.recheckProactivePlayback()
                self.observeProactivePolicy(playback)
            }
        }
    }

    private func retireInvalidSpeechReceipts() {
        for index in proactiveSpeechReceipts.indices {
            let receipt = proactiveSpeechReceipts[index]
            let snapshot = snapshots[receipt.endpoint]
            if snapshot?.state != .ready || snapshot?.connectionGeneration != receipt.generation
                || duckMode[receipt.endpoint]?.isOn() == true
                || privacyLocal[receipt.endpoint]?.request?.on == true
                || mediaMode[receipt.endpoint]?.on == true || !ambientStreaming
                || snapshot?.targets.contains(where: { $0.id == receipt.target && $0.alive }) != true {
                proactiveSpeechReceipts[index].allowed = false
            }
        }
    }
}
