import Testing

@Suite(.timeLimit(.minutes(1))) struct LocalDispatchPreflightWaitTests {
    @Test func missingArrivalRecordsDeadlineAndRemovesWaiter() async {
        let signal = SelectionPreflightSignal<Void>()
        await withKnownIssue("Deliberately missing listing arrival") {
            await #expect(throws: SelectionPreflightWaitError.deadline("synthetic arrival")) {
                try await signal.wait("synthetic arrival", timeout: .milliseconds(10))
            }
        } matching: { Self.waitIssue($0, containing: "synthetic arrival") }
        #expect(!signal.hasWaiter)
        signal.finish(.success(()))
        await withKnownIssue("A late arrival cannot erase the deadline") {
            await #expect(throws: SelectionPreflightWaitError.deadline("synthetic arrival")) {
                try await signal.wait("late arrival")
            }
        } matching: { Self.waitIssue($0, containing: "synthetic arrival") }
    }

    @Test(arguments: [false, true])
    func dispatchReturningBeforeListingReleasesArrival(beforeRegistration: Bool) async throws {
        let listing = SelectionPreflightListing()
        defer { listing.close() }
        listing.arm()
        let dispatch = Task {
            defer { listing.dispatchFinished() }
            if !beforeRegistration { try await waitForWaiter(listing.arrival) }
        }
        defer { dispatch.cancel() }
        if beforeRegistration {
            try await selectionPreflightStep("dispatch before arrival registration") { try await dispatch.value }
        }
        await withKnownIssue("Deliberate dispatch exit before listing") {
            await #expect(throws: SelectionPreflightWaitError.dispatchEndedBeforeListing) {
                try await listing.arrival.wait("early dispatch")
            }
        } matching: { Self.waitIssue($0, containing: "dispatchEndedBeforeListing") }
        try await selectionPreflightStep("early dispatch completion") { try await dispatch.value }
        #expect(!listing.arrival.hasWaiter)
    }

    @Test(arguments: [false, true]) func cancellationRemovesPendingWaiter(beforeRegistration: Bool) async throws {
        let signal = SelectionPreflightSignal<Void>()
        let waiting = Task {
            if beforeRegistration { withUnsafeCurrentTask { $0?.cancel() } }
            try await signal.wait("cancelled arrival")
        }
        defer { waiting.cancel() }
        if !beforeRegistration { try await waitForWaiter(signal) }
        waiting.cancel()
        let result = try await selectionPreflightStep("cancelled waiter completion") { await waiting.result }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!signal.hasWaiter)
        signal.finish(.success(()))
    }

    @Test func closeReleasesPendingArrivalAndListing() async throws {
        let listing = SelectionPreflightListing()
        defer { listing.close() }
        let arrival = Task { try await listing.arrival.wait("closed arrival") }
        defer { arrival.cancel() }
        try await waitForWaiter(listing.arrival)
        listing.close()
        let result = try await selectionPreflightStep("closed arrival completion") { await arrival.result }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!listing.arrival.hasWaiter)

        let blocked = SelectionPreflightListing()
        defer { blocked.close() }
        blocked.arm()
        let listingWork = Task { try await blocked.pauseIfArmed() }
        defer { listingWork.cancel() }
        try await blocked.arrival.wait("blocked listing arrival")
        blocked.close()
        try await selectionPreflightStep("closed listing completion") { try await listingWork.value }
        // Closing also disarms future listings and is idempotent.
        blocked.close()
        try await selectionPreflightStep("listing after close") { try await blocked.pauseIfArmed() }
    }

    @Test func stepDeadlineCancelsSuspendedWork() async {
        let signal = SelectionPreflightSignal<Void>()
        defer { signal.finish(.failure(CancellationError())) }
        await withKnownIssue("Deliberately suspended step") {
            await #expect(throws: SelectionPreflightWaitError.deadline("synthetic step")) {
                try await selectionPreflightStep("synthetic step", timeout: .milliseconds(10)) {
                    try await signal.wait("suspended work")
                }
            }
        } matching: { Self.waitIssue($0, containing: "synthetic step") }
    }

    @Test func policyLoadCleanupReleasesPendingEntry() async throws {
        let loading = SelectionPreflightLoadGate()
        defer { loading.fire() }
        let waiting = Task { try await loading.waitUntilSuspended() }
        defer { waiting.cancel() }
        try await selectionPreflightStep("policy entry waiter installation") {
            while !loading.hasEntryWaiter { try await Task.sleep(for: .milliseconds(1)) }
        }
        loading.fire()
        let result = try await selectionPreflightStep("closed policy entry") { await waiting.result }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!loading.hasEntryWaiter)
    }

    private static func waitIssue(_ issue: Issue, containing text: String) -> Bool {
        guard case .unconditional = issue.kind else { return false }
        return issue.comments.contains {
            $0.rawValue.contains("Selection preflight wait failed:") && $0.rawValue.contains(text)
        }
    }

    private func waitForWaiter(_ signal: SelectionPreflightSignal<Void>) async throws {
        try await selectionPreflightStep("waiter installation") {
            while !signal.hasWaiter { try await Task.sleep(for: .milliseconds(1)) }
        }
    }
}
