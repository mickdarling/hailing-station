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

    func publish(_ reply: DiagnosticBridgeReply) async throws {
        replies.append(reply)
        if let arrival, replies.count >= arrival.0 {
            self.arrival = nil
            arrival.1.resume()
        }
        try await withCheckedThrowingContinuation { waiting[reply.requestID] = $0 }
    }
    func waitForCount(_ count: Int) async {
        if replies.count >= count { return }
        await withCheckedContinuation { arrival = (count, $0) }
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
