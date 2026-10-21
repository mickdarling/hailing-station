#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #658: a preempted runner once refused the fixed `recipient:reply` with "(shell)" or "(delete)", because target
/// validation counted an expired 20 ms guard budget as a hit (#208). The target block is now matched without the
/// budget, so a clock that expires every deadline lets it through at startup and at every stream start. Delivered
/// text still fails closed on a timeout (`guardTimeoutStillRefusesARightyoDeliveryButNotABenignTarget`).
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientTargetGuardBudgetTests {
    @Test func anExpiredGuardBudgetNoLongerRefusesTheFixedTargetAtStartup() async throws {
        let rig = try await RecipientTestRig.make()
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let options = ConnectionProbeDaemon.AmbientOptions(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target
        )
        _ = try await GuardBudgetClock.$current.withValue(.expiring()) {
            try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: { _ in })
        }
    }

    /// Every stream start validates the target again (`start` → `makePipeline` → the consumer). The router handles a
    /// start synchronously on its caller, so an expiring clock bound here reaches that check; a start arriving from a
    /// socket runs in a task the suite's clock never reaches, which is why the check itself must not read the clock.
    @Test func anExpiredGuardBudgetNoLongerRefusesTheFixedTargetAtStreamStart() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2), events: events)
        let stream = UUID()
        GuardBudgetClock.$current.withValue(.expiring()) {
            env.router.ambientAudio(.started(stream: stream, connection: UUID()))
        }
        #expect(env.router.activeStream == stream)
        #expect(!events.all.contains("ambient_refused"))
        env.router.ambientAudio(.ended(stream: stream, reason: .final))
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
