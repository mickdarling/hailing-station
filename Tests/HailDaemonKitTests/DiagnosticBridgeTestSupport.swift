import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

let diagnosticUtilityBinding = DiagnosticReplyBridgeAdapter.utilityBinding

enum DiagnosticSyntheticError: Error { case failed }

actor DiagnosticSyntheticPublisher {
    private(set) var replies: [DiagnosticBridgeReply] = []
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var arrival: (Int, CheckedContinuation<Void, Never>)?
    private var wait = 0

    func publish(_ reply: DiagnosticBridgeReply) async throws {
        replies.append(reply)
        if let arrival, replies.count >= arrival.0 {
            self.arrival = nil
            arrival.1.resume()
        }
        try await withCheckedThrowingContinuation { waiting[reply.requestID] = $0 }
    }
    /// Waits for `count` replies, or records an issue and returns after `limit`, so a refused request fails its
    /// test instead of holding the lane until its 300 s stall stop (#745).
    func waitForCount(_ count: Int, within limit: Duration = .seconds(15)) async {
        if replies.count >= count { return }
        wait += 1
        let current = wait
        let timer = Task { [weak self] in
            try await Task.sleep(for: limit)
            await self?.giveUpWaiting(current, for: count, after: limit)
        }
        await withCheckedContinuation { arrival = (count, $0) }
        timer.cancel()
    }

    /// Only for the wait that started this timer: a late one never ends a newer wait.
    private func giveUpWaiting(_ which: Int, for count: Int, after limit: Duration) {
        guard which == wait, let arrival else { return }
        self.arrival = nil
        Issue.record("only \(replies.count) of \(count) synthetic replies within \(limit)")
        arrival.1.resume()
    }
    func complete(_ request: UUID, failing: Bool = false) {
        let continuation = waiting.removeValue(forKey: request)
        if failing { continuation?.resume(throwing: DiagnosticSyntheticError.failed) } else { continuation?.resume() }
    }
}

func diagnosticBridge(_ publisher: DiagnosticSyntheticPublisher) throws -> DiagnosticReplyBridgeAdapter {
    try DiagnosticReplyBridgeAdapter(hostID: "mac-test", publisher: publisher.publish)
}

func diagnosticContext(host: String = "mac-test", provider: String = "diagnostic-reply",
                       target: String = DiagnosticReplyBridgeAdapter.targetID,
                       session: String = diagnosticUtilityBinding)
throws -> ProviderTurnContext {
    ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: try ProviderSessionBinding(
        hostID: host, providerID: provider, targetID: target, sessionID: session
    ))
}

func diagnosticWait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
        try #require(clock.now < deadline, "synthetic diagnostic worker did not settle")
        await Task.yield()
    }
}
