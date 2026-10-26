import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct ReplySegmentsHostSessionTests {
    @Test(arguments: [false, true])
    func unadvertisedYieldUsesExistingAuthorizationRefusal(personal: Bool) async throws {
        let (host, adapter) = try await sessionHost()
        let authorizer: any HostSessionAuthorizing = personal
            ? PersonalTerminalAuthorizer() : ConnectionProbeAuthorizer()
        let session = HostSession(host: host, authorizer: authorizer)
        let hello = await session.receive(helloFrame())
        guard case .hello(let info) = try onlyControl(hello) else {
            Issue.record("expected hello")
            return
        }
        #expect(info.capabilities.contains(ReplySegments.capability))
        let reply = UUID()
        await session.seedReplySegmentsTestState(reply: reply)
        let result = await session.receive(sessionFrame(payload: .control(.replyYield(reply: reply, segment: 1))))
        #expect(try onlyControl(result) == .error(code: .unauthorized, message: "terminal action is not authorized"))
        #expect(result.disposition == .keepOpen)
        #expect(await session.state == .ready(version: 1))
        #expect(await session.selectedTarget == "tmux:synthetic")
        #expect(await session.repliesInFlight == [reply])
        #expect(await session.stoppedReplies.isEmpty)
        #expect(await adapter.deliveries.isEmpty)
        let pong = await session.receive(sessionFrame(payload: .control(.ping(nonce: "after"))))
        #expect(try onlyControl(pong) == .pong(nonce: "after"))
    }

    @Test(arguments: [false, true])
    func capablePeerCanYieldUnderEitherBuiltInAuthorizer(personal: Bool) async throws {
        let (host, _) = try await sessionHost()
        let authorizer: any HostSessionAuthorizing = personal
            ? PersonalTerminalAuthorizer() : ConnectionProbeAuthorizer()
        let session = HostSession(host: host, authorizer: authorizer)
        _ = await session.receive(helloFrame(capabilities: [ReplySegments.capability]))
        let reply = UUID()
        await session.seedReplySegmentsTestState(reply: reply)
        let result = await session.receive(sessionFrame(payload: .control(.replyYield(reply: reply, segment: 99))))
        #expect(result.frames.isEmpty)
        #expect(await session.repliesInFlight.isEmpty)
        #expect(await session.stoppedReplies == [reply])
    }

    @Test func customAuthorizerStillCanDenyACapablePeer() async throws {
        let (host, _) = try await sessionHost()
        let session = HostSession(host: host, authorizer: ReplySegmentsDenyingAuthorizer())
        _ = await session.receive(helloFrame(capabilities: [ReplySegments.capability]))
        let reply = UUID()
        await session.seedReplySegmentsTestState(reply: reply)
        let result = await session.receive(sessionFrame(payload: .control(.replyYield(reply: reply, segment: 1))))
        #expect(try onlyControl(result) == .error(code: .unauthorized, message: "terminal action is not authorized"))
        #expect(result.disposition == .keepOpen)
        #expect(await session.repliesInFlight == [reply])
    }

    @Test func yieldBeforeHelloIsUnauthorizedWithoutChangingState() async throws {
        let (host, _) = try await sessionHost()
        let session = HostSession(host: host)
        let result = await session.receive(sessionFrame(payload: .control(.replyYield(reply: UUID(), segment: 1))))
        #expect(try onlyControl(result) == .error(code: .unauthorized, message: "terminal action is not authorized"))
        #expect(result.disposition == .keepOpen)
        #expect(await session.state == .awaitingHello)
        #expect(await session.receive(helloFrame()).disposition == .keepOpen)
    }

    @Test func segmentTrackingIsBoundedAndClearedOnEndStopDismissAndTeardown() async throws {
        let rig = try await RecipientTestRig.make()
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame(capabilities: [ReplySegments.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        var replies: [ReplyDescriptor] = []
        for _ in 0..<(HostSession.playbackStopLimit + 2) {
            let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                        audioStreamID: UUID())
            #expect(await session.enqueueRequestlessReply(segmentAudio(reply, sequence: 0), enqueue: { true }))
            replies.append(reply)
        }
        #expect(await session.segmentedReplies.count == HostSession.playbackStopLimit)
        #expect(await session.segmentedReplies == Set(replies.dropFirst(2).map(\.id)))
        let ended = replies[2], stopped = replies[3], yielded = replies[4]
        let final = recipientAudio(ended, sequence: 1, final: true)
        #expect(await session.enqueueRequestlessReply(final, enqueue: { true }))
        await session.stopHeldReply(stopped.id)
        _ = await session.receive(sessionFrame(payload: .control(.replyYield(reply: yielded.id, segment: 1))))
        #expect(await session.segmentedReplies.count == HostSession.playbackStopLimit - 3)
        #expect(!(await session.segmentedReplies.contains(ended.id)))
        #expect(!(await session.segmentedReplies.contains(stopped.id)))
        #expect(!(await session.segmentedReplies.contains(yielded.id)))
        _ = await session.stopReplyPlayback()
        #expect(await session.segmentedReplies.isEmpty)
        #expect(await session.repliesInFlight.isEmpty)
        let last = try #require(replies.last)
        let next = ReplyDescriptor(id: UUID(), hostID: last.hostID, targetID: last.targetID, audioStreamID: UUID())
        #expect(await session.enqueueRequestlessReply(segmentAudio(next, sequence: 0), enqueue: { true }))
        await session.endSegmentTracking()
        #expect(await session.segmentedReplies.isEmpty)
        // Existing in-flight ids stay available to a concurrent dismiss; only the new markers end here.
        #expect(await session.repliesInFlight == [next.id])
    }
}

private extension HostSession {
    func seedReplySegmentsTestState(reply: UUID) {
        selectedTarget = "tmux:synthetic"
        repliesInFlight = [reply]
    }
}

private struct ReplySegmentsDenyingAuthorizer: HostSessionAuthorizing {
    let capabilities = ["ping"]
    func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        if case .control(.replyYield) = frame.payload { return .deny }
        return await ConnectionProbeAuthorizer().authorize(frame)
    }
}
