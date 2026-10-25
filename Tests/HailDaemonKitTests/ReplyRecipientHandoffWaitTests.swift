#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct ReplyRecipientHandoffWaitTests {
    private static func handoffIssue(_ issue: Issue) -> Bool {
        issue.comments.contains { $0.rawValue.contains("#896: waitForHandoff") }
    }

    @Test func missingHandoffRecordsAnIssueAndReturns() async {
        let adapter = RecipientContextAdapter()
        await withKnownIssue {
            await adapter.waitForHandoff(within: .milliseconds(10))
        } matching: { Self.handoffIssue($0) && $0.comments.contains { $0.rawValue.contains("timed out") } }
        #expect(await adapter.handoffWaiterCount == 0)
    }

    @Test(arguments: [false, true]) func cancellationReturnsBeforeTheDeadline(beforeRegistration: Bool) async {
        let adapter = RecipientContextAdapter()
        await withKnownIssue {
            let waiter = Task {
                if beforeRegistration { withUnsafeCurrentTask { $0?.cancel() } }
                await adapter.waitForHandoff()
            }
            if !beforeRegistration {
                #expect(await eventually { await adapter.handoffWaiterCount == 1 })
                waiter.cancel()
            }
            await bounded("cancelled handoff waiter", within: .seconds(2)) { await waiter.value }
        } matching: { Self.handoffIssue($0) && $0.comments.contains { $0.rawValue.contains("cancelled") } }
        #expect(await adapter.handoffWaiterCount == 0)
    }

    @Test(arguments: [false, true]) func aSecondWaiterSurvivesTheFirstWaitersExit(cancel: Bool) async throws {
        let adapter = RecipientContextAdapter()
        await adapter.holdHandoff()
        let second = Task { await adapter.waitForHandoff() }
        await withKnownIssue {
            let first = Task { await adapter.waitForHandoff(within: cancel ? .seconds(20) : .milliseconds(200)) }
            #expect(await eventually { await adapter.handoffWaiterCount == 2 })
            if cancel { first.cancel() }
            await bounded("first handoff waiter", within: .seconds(2)) { await first.value }
        } matching: { Self.handoffIssue($0) }
        #expect(await adapter.handoffWaiterCount == 1)
        let delivery = try await deliver(to: adapter)
        await bounded("second handoff waiter", within: .seconds(2)) { await second.value }
        await adapter.releaseHandoff()
        try await delivery.value
        #expect(await adapter.handoffWaiterCount == 0)
    }

    @Test func arrivalResumesAllWaitersAndLaterWaitsReturnImmediately() async throws {
        let adapter = RecipientContextAdapter()
        await adapter.holdHandoff()
        let first = Task { await adapter.waitForHandoff() }
        let second = Task { await adapter.waitForHandoff() }
        #expect(await eventually { await adapter.handoffWaiterCount == 2 })
        let delivery = try await deliver(to: adapter)
        await bounded("both handoff waiters", within: .seconds(2)) {
            await first.value
            await second.value
        }
        await adapter.waitForHandoff(within: .zero)
        await adapter.releaseHandoff()
        try await delivery.value
        #expect(await adapter.handoffWaiterCount == 0)
    }

    private func deliver(to adapter: RecipientContextAdapter) async throws -> Task<Void, any Error> {
        let binding = try ProviderSessionBinding(
            hostID: "mac-test", providerID: "recipient", targetID: "recipient:reply", sessionID: "reply-binding"
        )
        let context = ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: binding)
        let delivery = Task {
            try await adapter.deliver("synthetic", to: "reply", binding: "reply-binding", context: context)
        }
        #expect(await eventually { await adapter.handoffWaiterCount == 0 })
        return delivery
    }
}
#endif
