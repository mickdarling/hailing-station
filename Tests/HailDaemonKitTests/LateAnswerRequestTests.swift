import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #430: an agent that works for more than two minutes still answers the device that asked, for up to 30 minutes,
/// and only that device, on the same selection, under a current permit. Synthetic adapter and clock only.
@Suite struct LateAnswerRequestTests {
    private static let minute: Int64 = 60_000

    @Test func anUnansweredRequestStillReachesTheAskingDeviceAfterTwoMinutes() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(10 * Self.minute)
        #expect(await session.answersLate(frame))
        #expect(await session.replyPublicationStatus(frame) == .ready)
        #expect(await session.acceptsHostReply(frame))
    }

    @Test func theLateAnswerBoundStillEndsTheRequest() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(30 * Self.minute - 1_000)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        rig.clock.advance(2_000)
        #expect(await session.replyPublicationStatus(frame) == .absent)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test func anotherDeviceNeverReceivesTheLateAnswer() async throws {
        let rig = try await RecipientTestRig.make()
        let asking = await rig.session()
        let other = await rig.session()
        let context = try await rig.submit(on: asking)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(10 * Self.minute)
        #expect(await other.replyPublicationStatus(frame) == .absent)
        #expect(!(await other.acceptsHostReply(frame)))
    }

    @Test(arguments: ["selection", "policy"])
    func aLateAnswerIsStillRevoked(change: String) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let frame = recipientText(recipientDescriptor(context))
        rig.clock.advance(10 * Self.minute)
        if change == "selection" {
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        } else {
            _ = try await rig.host.deny(RecipientTestRig.target)
        }
        #expect(await session.replyPublicationStatus(frame) == .absent)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test func aStartedAnswerThatStallsExpiresAsBefore() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let descriptor = recipientDescriptor(context, audio: true)
        rig.clock.advance(Self.minute)
        #expect(await session.acceptsHostReply(recipientText(descriptor)))
        // Past the lifetime and the stream's idle gap: the late-answer bound covers only an answer not yet started.
        rig.clock.advance(Self.minute + 1_000)
        #expect(!(await session.answersLate(recipientAudio(descriptor, sequence: 0))))
        #expect(!(await session.acceptsHostReply(recipientAudio(descriptor, sequence: 0))))
    }

    @Test func atCapacityTheOldestLateRequestGivesWay() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        var contexts: [ProviderTurnContext] = []
        for _ in 0..<HostReplyRequest.capacity {
            contexts.append(try await rig.submit(on: session))
            rig.clock.advance(1)
        }
        rig.clock.advance(5 * Self.minute)
        let next = try await rig.submit(on: session)
        #expect(await session.replyPublicationStatus(recipientText(recipientDescriptor(next))) == .ready)
        #expect(await session.replyPublicationStatus(recipientText(recipientDescriptor(contexts[0]))) == .absent)
        #expect(await session.replyPublicationStatus(recipientText(recipientDescriptor(contexts[1]))) == .ready)
    }

    @Test func atCapacityRequestsInsideTheirLifetimeAreStillRefused() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        for _ in 0..<HostReplyRequest.capacity { _ = try await rig.submit(on: session) }
        rig.clock.advance(Self.minute)
        let refused = await session.receive(
            sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input")))
        )
        #expect(try onlyControl(refused) == .error(code: .rateLimited, message: "target action was refused"))
    }
}
