#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #1258: real owner-only Unix socket admission, synthetic device transport and reply publication.
@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionUpdateSocketBudgetTests {
    @Test(arguments: SessionUpdatePriority.allCases)
    func sixtyUpdatesDoNotSpendTheReplyBudget(priority: SessionUpdatePriority) async throws {
        try await withSocket { rig, socket in
            let started = ContinuousClock.now
            let request = LocalSessionUpdateRequest(action: .submit, target: RecipientTestRig.target,
                                                    priority: priority, text: "Synthetic card")
            for _ in 0..<60 {
                let response = try await submit(JSONEncoder().encode(request), socket: socket)
                #expect(response.error == nil && response.update?.outcome == .delivered)
            }
            #expect(rig.sends == 60)
            #expect(await rig.listener.sessionUpdates.sent.isEmpty)
            // All 120 replies still fit after the update burst: updates must not spend their bucket either.
            try await fillReplyBudget(socket: socket)
            #expect(ContinuousClock.now - started < .seconds(60), "exercise a single admission window")
        }
    }

    @Test(arguments: SessionUpdatePriority.allCases)
    func exhaustedReplyBudgetCannotBlockAnyUpdateAction(priority: SessionUpdatePriority) async throws {
        try await withSocket { rig, socket in
            let started = ContinuousClock.now
            try await fillReplyBudget(socket: socket)
            let requests: [LocalSessionUpdateRequest] = [
                .init(action: .submit, target: RecipientTestRig.target, priority: priority, text: "Synthetic card"),
                .init(action: .status), .init(action: .quietOn)
            ]
            for request in requests {
                let response = try await submit(JSONEncoder().encode(request), socket: socket)
                #expect(response.error == nil && response.update != nil)
                switch request.action {
                case .submit: #expect(response.update?.outcome == .delivered)
                case .status: #expect(response.update?.outcome == .status)
                case .quietOn: #expect(response.update?.quiet == true)
                }
            }
            #expect(rig.sends == 1)
            #expect(ContinuousClock.now - started < .seconds(60), "reply exhaustion has not expired")
        }
    }

    @Test func reply121IsStillRateLimited() async throws {
        try await withSocket { _, socket in
            let started = ContinuousClock.now
            try await fillReplyBudget(socket: socket)
            let response = try await submit(replyData(), socket: socket)
            #expect(response == LocalReplyResponse(delivered: 0, error: "rate limited"))
            #expect(ContinuousClock.now - started < .seconds(60), "reply exhaustion has not expired")
        }
    }

    @Test func oversizedUpdatesStillFailBeforeDispatch() async throws {
        try await withSocket { rig, socket in
            let request = LocalSessionUpdateRequest(action: .submit, target: RecipientTestRig.target,
                text: String(repeating: "x", count: PayloadLimits.defaultMaxFrameBytes))
            let response = try await submit(JSONEncoder().encode(request), socket: socket)
            #expect(response == LocalReplyResponse(delivered: 0, error: "frame too large"))
            #expect(rig.sends == 0)
        }
    }

    private func replyData() throws -> Data {
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target)
        return try FrameCoding.encode(Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
                                             payload: .text(TextPayload(text: "Synthetic reply", reply: reply))))
    }

    private func fillReplyBudget(socket: String) async throws {
        let frame = try replyData()
        for _ in 0..<LocalReplyEndpoint.maxFramesPerMinute {
            let response = try await submit(frame, socket: socket)
            try #require(response == LocalReplyResponse(delivered: 1))
        }
    }

    private func withSocket(_ body: (SilentUpdateRig, String) async throws -> Void) async throws {
        let rig = try await SilentUpdateRig.make()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-ub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/replies.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket,
            destination: BudgetTestPublisher(listener: rig.listener),
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        do {
            try await endpoint.start()
            try await body(rig, socket.path)
        } catch {
            await endpoint.stop()
            await rig.listener.stop()
            throw error
        }
        await endpoint.stop()
        await rig.listener.stop()
    }
}

/// Keep reply publication deterministic while updates use the real listener's policy and synthetic device peer.
private struct BudgetTestPublisher: HostReplyPublishing {
    let listener: WebSocketListener
    func publish(_ frame: Frame) async throws -> Int { 1 }
    func sessionUpdate(_ request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        await listener.sessionUpdate(request)
    }
}
#endif
