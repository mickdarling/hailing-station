import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

/// #430: a committed provider-owned request answers for as long as its turn runs, not just two minutes. Its end starts
/// the ordinary `lifetime` for the final frames. Synthetic adapter and clock only; no live provider.
@Suite struct ProviderTurnRequestLifetimeTests {
    private static let minute: Int64 = 60_000

    @Test func aRunningProviderTurnStillAnswersAfterTwoMinutes() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(2 * Self.minute + 1_000)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        rig.clock.advance(60 * Self.minute)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        #expect(await session.acceptsHostReply(frame))
    }

    @Test func anEndedTurnKeepsTwoMinutesForItsFinalFrames() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(30 * Self.minute)
        await session.providerTurnEnded(context)
        rig.clock.advance(2 * Self.minute - 1_000)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        // A second end report never restarts the grace.
        await session.providerTurnEnded(context)
        rig.clock.advance(2_000)
        #expect(await session.replyPublicationStatus(frame) == .absent)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test func aTurnWhoseEndIsNeverReportedStopsAtTheSafetyBound() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(6 * 60 * Self.minute - 1_000)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        rig.clock.advance(2_000)
        #expect(await session.replyPublicationStatus(frame) == .absent)
    }

    @Test func aLateEndReportCannotReviveAnExpiredTurn() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(6 * 60 * Self.minute + 1_000)
        await session.providerTurnEnded(context)
        #expect(await session.replyPublicationStatus(frame) == .absent)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test(arguments: ["selection", "policy"])
    func aLongRunningTurnIsStillRevoked(change: String) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(30 * Self.minute)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        if change == "selection" {
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        } else {
            _ = try await rig.host.deny(RecipientTestRig.target)
        }
        #expect(await session.replyPublicationStatus(frame) == .absent)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test func theListenerEndsOnlyTheExactTurnItIsGiven() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host, hostName: "mac-test")
        await listener.installLifetimePeer(session)
        // Same request id, but another utterance or connection: not this turn, so it keeps running.
        let otherUtterance = ProviderTurnContext(id: context.id, utteranceID: UUID(),
                                                 connectionID: context.connectionID, binding: context.binding)
        let otherConnection = ProviderTurnContext(id: context.id, utteranceID: context.utteranceID,
                                                  connectionID: UUID(), binding: context.binding)
        await listener.providerTurnEnded(otherUtterance)
        await listener.providerTurnEnded(otherConnection)
        rig.clock.advance(2 * Self.minute + 1_000)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        await listener.providerTurnEnded(context)
        rig.clock.advance(2 * Self.minute + 1_000)
        #expect(await session.replyPublicationStatus(frame) == .absent)
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func aHandoffThatNeverCommittedKeepsTheOrdinaryTwoMinutes() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        await session.markUncommitted(context.id)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(2 * Self.minute - 1_000)
        #expect(await session.replyPublicationStatus(frame) == .pending)
        rig.clock.advance(2_000)
        #expect(await session.replyPublicationStatus(frame) == .absent)
    }

    @Test func endedTurnsFreeTheirCapacitySlotsAndRunningOnesKeepThem() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        var contexts: [ProviderTurnContext] = []
        for _ in 0..<HostReplyRequest.capacity { contexts.append(try await rig.submit(on: session)) }
        rig.clock.advance(10 * Self.minute)
        // Every slot is held by a running turn: a new input is refused rather than evicting one.
        let refused = await session.receive(
            sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input")))
        )
        #expect(try onlyControl(refused) == .error(code: .rateLimited, message: "target action was refused"))
        await session.providerTurnEnded(contexts[0])
        rig.clock.advance(2 * Self.minute + 1_000)
        let next = try await rig.submit(on: session)
        #expect(await session.replyPublicationStatus(recipientText(recipientDescriptor(next))) == .ready)
        #expect(await session.replyPublicationStatus(recipientText(recipientDescriptor(contexts[1]))) == .ready)
        #expect(await session.replyPublicationStatus(recipientText(recipientDescriptor(contexts[0]))) == .absent)
    }
}

private extension HostSession {
    func markUncommitted(_ id: UUID) { replyRequests[id]?.committed = false }
}

private extension WebSocketListener {
    func installLifetimePeer(_ session: HostSession) {
        readyResult = .success(0)
        let id = UUID()
        peers[id] = WebSocketPeer(id: id, connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
                                  session: session, queue: DispatchQueue(label: "synthetic.lifetime"),
                                  helloTimeout: .seconds(1), log: { _ in }, onEnd: { _ in })
    }
}
