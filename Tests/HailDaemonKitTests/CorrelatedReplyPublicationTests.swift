import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// Synthetic adapters and never-started transport only; no live target, renderer, microphone or device.
@Suite struct CorrelatedReplyPublicationTests {
    @Test(arguments: [false, true])
    func retiredTransportCannotAdvertisePendingOrReadyRecipient(committed: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        if !committed { await session.setSyntheticPending(context.id) }
        let frame = recipientText(recipientDescriptor(context))
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let peer = WebSocketPeer(id: UUID(), connection: connection, session: session,
                                 queue: DispatchQueue(label: "synthetic.retired-publication"),
                                 helloTimeout: .seconds(1), log: { _ in }, onEnd: { _ in })
        let ticket = try #require(await peer.prepareReplyPublication(frame))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ticket.result()
        }
        #expect(!(await cancelled.value))
        // Never started: no Network state callback can update the peer actor's ended flag.
        #expect(!(await peer.ended))
        #expect(await session.replyPublicationStatus(frame) == (committed ? .ready : .pending))
        #expect(await peer.replyPublicationStatus(frame) == .absent)
        #expect(await session.syntheticFrameCount(context.id) == 0)
        #expect(!ticket.enqueue())
    }

    @Test(arguments: [false, true])
    func pendingRefusalMakesNoPublicationAndRequiresSuccessfulCommit(failing: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        await rig.adapter.holdHandoff()
        if failing { await rig.adapter.failHandoff() }
        let task = Task {
            await session.receive(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ))
        }
        await rig.adapter.waitForHandoff()
        let context = try #require(await rig.adapter.contexts.last)
        let frame = recipientText(recipientDescriptor(context))
        let listener = try syntheticListener(rig: rig)
        await listener.installSyntheticPeers([session])
        #expect(await session.replyPublicationStatus(frame) == .pending)
        await #expect(throws: LocalReplyRefusal.requestPending) { try await listener.publish(frame) }
        #expect(await session.syntheticFrameCount(context.id) == 0)
        await rig.adapter.releaseHandoff()
        let result = await task.value
        #expect(result.frames.isEmpty == !failing)
        #expect(await session.replyPublicationStatus(frame) == (failing ? .absent : .ready))
        if failing {
            await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(frame) }
        } else {
            // Retrying the same frame after committed dispatch consumes media exactly once.
            #expect(await session.acceptsHostReply(frame))
            #expect(await session.replyPublicationStatus(frame) == .absent)
            #expect(!(await session.acceptsHostReply(frame)))
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test(arguments: [false, true])
    func ambiguousOwnersAreRefusedBeforeAnyPublication(onePending: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let first = await rig.session()
        let second = await rig.session()
        let context = try await rig.submit(on: first)
        await second.copySyntheticRequest(from: first, id: context.id, committed: !onePending)
        let frame = recipientText(recipientDescriptor(context))
        let listener = try syntheticListener(rig: rig)
        await listener.installSyntheticPeers([first, second])
        await #expect(throws: LocalReplyRefusal.notUniqueRecipient) { try await listener.publish(frame) }
        #expect(await first.syntheticFrameCount(context.id) == 0)
        #expect(await second.syntheticFrameCount(context.id) == 0)
        #expect(await first.replyPublicationStatus(frame) == .ready)
        #expect(await second.replyPublicationStatus(frame) == (onePending ? .pending : .ready))
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func invalidPendingFramesNeverReceiveRetryPermission() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        await session.setSyntheticPending(context.id)
        let descriptor = recipientDescriptor(context, audio: true)
        var wrongVersion = recipientText(descriptor)
        wrongVersion.version += 1
        var unknown = descriptor
        unknown.requestID = UUID()
        for frame in [wrongVersion, recipientText(unknown), recipientAudio(descriptor, sequence: 1)] {
            #expect(await session.replyPublicationStatus(frame) == .absent)
        }
        #expect(await session.syntheticFrameCount(context.id) == 0)
        #expect(await session.replyPublicationStatus(recipientText(descriptor)) == .pending)
        rig.clock.advance(120_000)
        #expect(await session.replyPublicationStatus(recipientText(descriptor)) == .absent)
    }

    @Test(arguments: ["selection", "reconnect", "policy", "binding"])
    func staleRequestsNeverReceivePendingPermission(change: String) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        await session.setSyntheticPending(context.id)
        let frame = recipientText(recipientDescriptor(context))
        switch change {
        case "selection":
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        case "reconnect":
            #expect(await rig.session().replyPublicationStatus(frame) == .absent)
            return
        case "policy": _ = try await rig.host.deny(RecipientTestRig.target)
        default: await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement")])
        }
        #expect(await session.replyPublicationStatus(frame) == .absent)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test func statusSnapshotCannotAuthorizeAfterRevocation() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let frame = recipientText(recipientDescriptor(try await rig.submit(on: session)))
        #expect(await session.replyPublicationStatus(frame) == .ready)
        _ = try await rig.host.deny(RecipientTestRig.target)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test func expiryAfterReadySnapshotReturnsNonRetryablePublicationFailure() async throws {
        let rig = try await RecipientTestRig.make()
        let clock = PublicationExpiryClock()
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test",
                                  requestClock: clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let frame = recipientText(recipientDescriptor(try await rig.submit(on: session)))
        let listener = try syntheticListener(rig: rig)
        await listener.installSyntheticPeers([session])
        // Status performs two time reads. Actual enqueue then observes expiration, without a sleep
        // or a blocked cooperative executor, and must not downgrade this later refusal to pending.
        clock.expireAfter(reads: 2)
        await #expect(throws: LocalReplyRefusal.publicationFailed) { try await listener.publish(frame) }
        #expect(await session.replyPublicationStatus(frame) == .absent)
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func responseCodeIsAdditiveAndLegacyAbsenceMeansNoRetryPermission() throws {
        let legacy = Data(#"{"delivered":0,"error":"legacy refusal"}"#.utf8)
        #expect(try JSONDecoder().decode(LocalReplyResponse.self, from: legacy).code == nil)
        let response = LocalReplyResponse(delivered: 0, error: LocalReplyRefusal.requestPending.message,
                                          code: .requestPending)
        #expect(try JSONDecoder().decode(LocalReplyResponse.self, from: JSONEncoder().encode(response)) == response)
    }
}

private func syntheticListener(rig: RecipientTestRig) throws -> WebSocketListener {
    try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host, hostName: "mac-test")
}

private extension WebSocketListener {
    func installSyntheticPeers(_ sessions: [HostSession]) {
        readyResult = .success(0)
        for session in sessions {
            let id = UUID()
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            peers[id] = WebSocketPeer(id: id, connection: connection, session: session,
                                     queue: DispatchQueue(label: "synthetic.publication"),
                                     helloTimeout: .seconds(1), log: { _ in }, onEnd: { _ in })
        }
    }
}

private extension HostSession {
    func syntheticFrameCount(_ id: UUID) -> Int? { replyRequests[id]?.frames.count }
    func setSyntheticPending(_ id: UUID) { replyRequests[id]?.committed = false }
    func copySyntheticRequest(from other: HostSession, id: UUID, committed: Bool) async {
        guard let original = await other.replyRequests[id] else { return }
        let context = ProviderTurnContext(id: id, utteranceID: original.context.utteranceID,
                                          connectionID: connectionID, binding: original.context.binding)
        replyRequests[id] = HostReplyRequest(context: context, generation: selectionGeneration,
                                            createdAt: original.createdAt, policyPermit: original.policyPermit,
                                            bindingLease: original.bindingLease, committed: committed)
    }
}
