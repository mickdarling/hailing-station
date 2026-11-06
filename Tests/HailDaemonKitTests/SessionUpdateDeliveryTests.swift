import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// Invented notices through a synthetic transport. No renderer, provider or physical device is contacted.
@Suite(.serialized) struct SessionUpdateDeliveryTests {
    private func session(_ rig: RecipientTestRig, capable: Bool = true) async -> HostSession {
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame(capabilities: capable ? [SessionUpdateCard.capability] : []))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        return session
    }

    private func update() throws -> SessionUpdate {
        try #require(SessionUpdate(session: RecipientTestRig.target, priority: .action, spoken: "Synthetic done",
                                   card: "Synthetic detail", submitted: .now))
    }

    @Test func exactTargetAndRegistryLabelTravelTogether() async throws {
        let rig = try await RecipientTestRig.make(), session = await session(rig)
        let update = try update()
        let prepared = try #require(await session.prepareSessionUpdate(update, lastInput: nil))
        #expect(prepared.frame.target == RecipientTestRig.target && prepared.frame.source == "haild")
        #expect(prepared.frame.payload == .control(.sessionUpdate(update: update.id, session: "reply",
            priority: "action", text: "Synthetic done", card: "Synthetic detail")))
        #expect(await session.enqueueSessionUpdate(prepared, lastInput: nil, enqueue: { true }))
    }

    @Test func capabilityAndSelectionAreRequired() async throws {
        let rig = try await RecipientTestRig.make(), legacy = await session(rig, capable: false)
        #expect(await legacy.prepareSessionUpdate(try update(), lastInput: nil) == nil)
        let capable = await session(rig)
        _ = await capable.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        #expect(await capable.prepareSessionUpdate(try update(), lastInput: nil) == nil)
    }

    @Test func oldPreparationCannotSurviveReselectionPolicyOrBindingRetirement() async throws {
        let rig = try await RecipientTestRig.make(), session = await session(rig)
        let update = try update()
        let selection = try #require(await session.prepareSessionUpdate(update, lastInput: nil))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        #expect(await !session.enqueueSessionUpdate(selection, lastInput: nil, enqueue: { true }))
        let binding = try #require(await session.prepareSessionUpdate(update, lastInput: nil))
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement")])
        #expect(await !session.enqueueSessionUpdate(binding, lastInput: nil, enqueue: { true }))
        // The original policy still names the old binding, so even a new preparation fails closed.
        #expect(await session.prepareSessionUpdate(update, lastInput: nil) == nil)
    }

    @Test func policyRevocationBetweenPreparationAndEnqueueRefusesWithoutHandoff() async throws {
        let rig = try await RecipientTestRig.make(), session = await session(rig)
        let admission = try #require(await session.prepareSessionUpdate(try update(), lastInput: nil))
        _ = try await rig.host.deny(RecipientTestRig.target)
        let called = Mutex(false)
        #expect(await !session.enqueueSessionUpdate(admission, lastInput: nil, enqueue: {
            called.withLock { $0 = true }; return true
        }))
        #expect(!called.withLock { $0 })
    }

    @Test func finalQuietLifetimeAndGlobalPrivacyFencesRefuseTransport() async throws {
        let rig = try await RecipientTestRig.make(), session = await session(rig)
        let calls = Mutex(0)
        let peer = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: session, queue: DispatchQueue(label: "synthetic.update"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { completion in
                calls.withLock { $0 += 1 }; completion(nil)
            })
        let hold = PrivateReplyHold(), fence = SessionUpdateFence(), foreign = UUID()
        hold.set(true, connection: foreign)
        let audience = SessionUpdateAudienceLease(lastInput: nil, privacyRevision: hold.entryRevision)
        #expect(await !peer.deliverSessionUpdate(try update(), audience: audience, hold: hold,
                                                ambient: nil, fence: fence))
        hold.set(false, connection: foreign)
        fence.quiet()
        #expect(await !peer.deliverSessionUpdate(try update(), audience: audience, hold: hold,
                                                ambient: nil, fence: fence))
        #expect(calls.withLock { $0 } == 0)
        #expect(await peer.deliverSessionUpdate(try update(), audience: audience, hold: hold, ambient: nil,
                                               fence: SessionUpdateFence()))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func onOffPrivacyPairStillInvalidatesHeldWork() {
        let hold = PrivateReplyHold(), connection = UUID(), before = hold.entryRevision
        hold.set(true, connection: connection)
        hold.set(false, connection: connection)
        #expect(!hold.anyHeld && hold.entryRevision != before)
    }

    @Test func connectedActionsDeliverAndInfoWaitsForARealDrain() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        let action = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                           priority: .action, text: "Synthetic finished"))
        #expect(action.outcome == .delivered && action.held == 0)
        let info = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                         text: "Synthetic information"))
        #expect(info.outcome == .held && info.held == 1)
        #expect(await rig.listener.drainSessionUpdates(.interaction, connection: rig.connectionID).count == 1)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.stop()
    }

    @Test func privacyEntryFollowedByExitPurgesAnOldHeldUpdate() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        _ = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                  text: "Old synthetic information"))
        let hold = await rig.listener.replyHold
        hold.set(true, connection: rig.connectionID)
        let dropped = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                             text: "Private synthetic information"))
        #expect(dropped.outcome == .dropped && dropped.reason == "private" && dropped.held == 0)
        hold.set(false, connection: rig.connectionID)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        await rig.listener.stop()
    }

    @Test func anOffOnPairBetweenTurnsDoesNotResurrectOldUpdates() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        _ = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                  text: "Old synthetic information"))
        let hold = await rig.listener.replyHold
        hold.set(true, connection: rig.connectionID)
        hold.set(false, connection: rig.connectionID)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.stop()
    }
}

/// Reusable never-started listener/session fixture for connected progress composition tests.
struct SessionUpdateListenerRig {
    let hostRig: RecipientTestRig
    let session: HostSession
    let connectionID: UUID
    let listener: WebSocketListener
    let peer: WebSocketPeer

    static func make(
        ambient: (any AmbientListenerWiring)? = nil,
        audio: Bool = false,
        send: @escaping WebSocketPeer.ReplySender = { $0(nil) }
    ) async throws -> Self {
        let hostRig = try await RecipientTestRig.make()
        let session = HostSession(host: hostRig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame(capabilities:
            [SessionUpdateCard.capability] + (audio ? [SessionUpdateCard.audioCapability] : [])))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: hostRig.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test", ambient: ambient)
        let peer = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: session, queue: DispatchQueue(label: "synthetic.update.listener"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: send)
        let connectionID = await session.connectionID
        let generation = await session.selectionGeneration
        await listener.enableSessionUpdates()
        await listener.installSessionUpdateTestPeer(peer, connectionID: connectionID, generation: generation)
        return Self(hostRig: hostRig, session: session, connectionID: connectionID, listener: listener, peer: peer)
    }
}

extension WebSocketListener {
    func installSessionUpdateTestPeer(_ peer: WebSocketPeer, connectionID: UUID, generation: UUID) {
        readyResult = .success(0)
        peers[UUID()] = peer
        lastInput.record(.init(connection: connectionID, generation: generation, at: .now),
                         for: RecipientTestRig.target)
    }
}

@Suite struct SessionUpdateAcknowledgementTests {
    @Test func successfulHandoffAcknowledgesOnlyItsUpdateAndPrivacyKeepsBudget() throws {
        let fixture = SessionUpdateQueueTests()
        var queue = fixture.enabled { $0.perSessionLimit = 2 }
        let first = try fixture.update(), second = try fixture.update(at: 1)
        _ = queue.submit(first, audience: .init(), now: fixture.at(0))
        _ = queue.submit(second, audience: .init(), now: fixture.at(1))
        var offered = queue
        #expect(offered.drain(.interaction, audience: .init(), now: fixture.at(2)).count == 2)
        #expect(queue.held == [first, second], "offering work is not delivery")
        queue.acknowledge(first.id)
        #expect(queue.held == [second])
        queue.acknowledge(first.id)
        #expect(queue.held == [second], "an old completion cannot consume a different update")
        queue.discardHeld()
        #expect(queue.held.isEmpty)
        #expect(queue.retryAfter(session: first.session, now: fixture.at(3)) != nil,
                "privacy cannot reset a session's rate budget")
    }
}
