#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension AmbientRequestRefusalTests {
    /// No sockets: exercise the listener's actual completion callback, holding its notice until later dispatch
    /// evidence has replaced the guard hits. Exactly one sanitized log must survive, even with no connected device.
    @Test(arguments: [LocalDispatchRefusal.confirmationRequired, .capacityExceeded])
    func refusalLogsCaptureOnlyTheirOwnRuleTokens(_ refusal: LocalDispatchRefusal) async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
                                             authorizer: PersonalTerminalAuthorizer(),
                                             hostName: "mac-test")
        let log = AmbientEventDetails()
        let router = AmbientRightyoRouter(configuration: .init(
            executable: URL(fileURLWithPath: "/synthetic/rightyo"),
            config: URL(fileURLWithPath: "/synthetic/config"), target: RecipientTestRig.target,
            binding: "reply-binding"
        ), log: { log.record($0) })
        let latch = MeetingLatch(), notices = AmbientRefusalNotices()
        defer { latch.open() }
        notices.chain.enqueue { await latch.wait() }
        let callbacks = router.heardRequests(on: UUID(), listener: listener, notices: notices)
        let evidence = RightyoGuardRefusal()
        evidence.record(["sudo", "SYNTHETIC_PRIVATE_RULE"], patterns: DangerousPatternGuard.defaults)
        await RightyoGuardRefusal.$current.withValue(evidence) { await callbacks.finish(UUID(), refusal) }
        evidence.hits.withLock { $0 = ["force push"] }
        latch.open()
        #expect(await eventually { log.details("ambient_request_refused").count == 1 })
        let token = refusal == .confirmationRequired
            ? "reason=confirmation_required rules=sudo+custom" : "reason=capacity_exceeded rules=none"
        #expect(log.details("ambient_request_refused")
                == ["\(token) shown=no_connection confirm=no_connection"])
        #expect(log.allDetails.allSatisfy { !$0.contains("SYNTHETIC") && !$0.contains(RecipientTestRig.target) })
        await listener.stop(reason: "synthetic test complete")
    }
}
#endif
