import Testing
@testable import HailDaemonKit

@Suite struct HostExpectedBindingTests {
    @Test func exactExpectedBindingPreservesAuthorizedDelivery() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")])
        let host = try await HostSendTests().host(adapter)
        #expect(try await host.send("hello", to: "tmux:a", expectedBinding: "b1") == .delivered(["hello"]))
        #expect(await adapter.deliveries.map(\.binding) == ["b1"])
    }

    @Test func mismatchedExpectedBindingRefusesEvenWhenPolicyAllowsTheCurrentTarget() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b2")])
        let host = try await HostSendTests().host(adapter)
        await #expect(throws: HostError.denied(.rebound("tmux:a"))) {
            try await host.send("hello", to: "tmux:a", expectedBinding: "b1")
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func bindingMismatchDoesNotConsumeAValidConfirmation() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")])
        let host = try await HostSendTests().host(adapter, tier: .confirm)
        let outcome = try await host.send("hello", to: "tmux:a", expectedBinding: "b1")
        guard case .needsConfirmation(let readBack) = outcome else {
            Issue.record("confirmation was not requested")
            return
        }
        await #expect(throws: HostError.denied(.rebound("tmux:a"))) {
            try await host.send("hello", to: "tmux:a", confirmedHash: readBack.hash, expectedBinding: "other")
        }
        #expect(await adapter.deliveries.isEmpty)
        #expect(try await host.send("hello", to: "tmux:a", confirmedHash: readBack.hash, expectedBinding: "b1")
            == .delivered(["hello"]))
    }

    @Test func legacyCallerStillUsesTheExistingPolicyPath() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")])
        let host = try await HostSendTests().host(adapter)
        #expect(try await host.send("hello", to: "tmux:a") == .delivered(["hello"]))
        await host.engageLockdown(reason: "synthetic test")
        await #expect(throws: HostError.denied(.lockdown)) {
            try await host.send("hello", to: "tmux:a", expectedBinding: "b1")
        }
        #expect(await adapter.deliveries.count == 1)
    }
}
