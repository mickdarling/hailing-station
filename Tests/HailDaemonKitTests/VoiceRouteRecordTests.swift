#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Voice routing on a contextual adapter (#636, second-key review on #688): a routed tap mints a request record for
/// the route, so the widened `recordOwner`, commit and `replyCandidate` checks run; and a selection change or the
/// route vanishing mid-handoff leaves no reply authority and sends nothing elsewhere. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRouteRecordTests {
    static let other = "recipient:other"

    static func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: RecipientTestRig.target, routes: [
            .init(target: RecipientTestRig.target, name: "Reply Desk"), .init(target: other, name: "Other")
        ])
    }

    /// A negotiated session with the routes, selecting the rig's default route.
    static func session(_ rig: RecipientTestRig) async throws -> HostSession {
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer().naming(try routes()),
                                  hostName: "mac-test", now: rig.clock.now, requestClock: rig.clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        return session
    }

    static func tap(_ text: String) -> Frame {
        sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: text)))
    }

    static func reply(_ context: ProviderTurnContext) -> Frame {
        recipientText(ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: context.binding.targetID,
                                      requestID: context.id))
    }

    @Test func aRoutedTapMintsTheRoutesRecordAndOnlyItsReplyIsAccepted() async throws {
        let rig = try await RecipientTestRig.make()
        let (asker, bystander) = (try await Self.session(rig), try await Self.session(rig))
        #expect(await asker.receive(Self.tap("Other, check the build")).frames.isEmpty)
        let context = try #require(await rig.adapter.contexts.last)
        let askerConnection = await asker.connectionID
        #expect(context.binding.targetID == Self.other && context.connectionID == askerConnection)
        #expect(await asker.acceptsHostReply(Self.reply(context)))
        #expect(!(await bystander.acceptsHostReply(Self.reply(context))))
        // A reply naming the record but claiming the selected route is not this request's reply.
        let wrongTarget = recipientText(ReplyDescriptor(id: UUID(), hostID: "mac-test",
                                                        targetID: RecipientTestRig.target, requestID: context.id))
        #expect(!(await asker.acceptsHostReply(wrongTarget)))
    }

    /// The owner reselects while the routed handoff is suspended: nothing lands elsewhere and no claim survives.
    @Test(arguments: [false, true])
    func aSelectionChangeMidHandoffLeavesNoReplyAuthority(_ awayAndBack: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let session = try await Self.session(rig)
        await rig.adapter.holdHandoff()
        let sending = Task { await session.receive(Self.tap("Other, check the build")) }
        await rig.adapter.waitForHandoff()
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.other))))
        if awayAndBack {
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        }
        await rig.adapter.releaseHandoff()
        let result = await sending.value
        guard case .error(let code, _) = try onlyControl(result) else { throw TestSupportError.expectedOneControl }
        #expect(code == .notAllowed)
        let context = try #require(await rig.adapter.contexts.last)
        #expect(!(await session.acceptsHostReply(Self.reply(context))))
        #expect(await rig.adapter.contexts.allSatisfy { $0.binding.targetID == Self.other })
        #expect(await rig.adapter.legacy.isEmpty)
    }

    /// The route goes away while its handoff is suspended: refused, with no reply authority, and never sent to the
    /// selected route instead.
    @Test func aRouteThatVanishesMidHandoffFallsBackNowhere() async throws {
        let rig = try await RecipientTestRig.make()
        let session = try await Self.session(rig)
        await rig.adapter.holdHandoff()
        await rig.adapter.failHandoff()
        let sending = Task { await session.receive(Self.tap("Other, check the build")) }
        await rig.adapter.waitForHandoff()
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "reply-binding")])
        await rig.adapter.releaseHandoff()
        let result = await sending.value
        guard case .error = try onlyControl(result) else { throw TestSupportError.expectedOneControl }
        let contexts = await rig.adapter.contexts
        #expect(contexts.count == 1 && contexts.allSatisfy { $0.binding.targetID == Self.other })
        #expect(!(await session.acceptsHostReply(Self.reply(try #require(contexts.last)))))
        #expect(await rig.adapter.legacy.isEmpty)
    }
}
#endif
