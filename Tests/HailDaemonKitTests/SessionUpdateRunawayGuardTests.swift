#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #1258: real Unix socket requests; synthetic peers, no live configuration or device delivery.
@Suite(.serialized, .timeLimit(.minutes(3))) struct SessionUpdateRunawayGuardTests {
    @Test(arguments: SessionUpdatePriority.allCases)
    func sixtySubmitsThenARefusalRecordsNothing(priority: SessionUpdatePriority) async throws {
        try await withGuardSocket { context in
            let started = ContinuousClock.now
            let data = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .submit,
                target: RecipientTestRig.target, priority: priority, text: "Synthetic card"))
            for _ in 0..<60 {
                #expect(try await submit(data, socket: context.socket).update?.outcome == .delivered)
            }
            let history = try context.history()
            #expect(history.count == 60)
            let before = await context.rig.listener.sessionUpdates
            let admission = await context.endpoint.limiter
            let instant = ContinuousClock.now
            let refused = try await submit(data, socket: context.socket)
            try expectGuard(refused, reason: "runaway_guard")
            #expect(try context.history() == history, "refusal records nothing")
            #expect(await context.rig.listener.sessionUpdates == before)
            #expect(context.publisher.calls.withLock { $0 } == 60)
            #expect(context.rig.sends == 60)
            let limiter = await context.endpoint.limiter
            #expect(limiter.retryAfter(for: "local-session-update", now: instant, limitPerMinute: 60)
                == admission.retryAfter(for: "local-session-update", now: instant, limitPerMinute: 60),
                "the first refusal spends no submit admission")
            for _ in 0..<10 { try expectGuard(await submit(data, socket: context.socket), reason: "runaway_guard") }
            #expect(await context.endpoint.limiter == limiter, "repeated refusals spend nothing")
            // Controls remain available after submit admission is full.
            let status = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .status))
            #expect(try await submit(status, socket: context.socket).update?.outcome == .status)
            #expect(ContinuousClock.now - started < .seconds(60))
        }
    }

    @Test(arguments: [
        #"{"kind":"update","action":17}"#, #"{"kind":"update","action":null}"#,
        #"{"kind":"update","action":{}}"#, #"{"kind":"update","action":"unknown"}"#,
        #"{"kind":"update"}"#
    ])
    func malformedActionsSpendSubmitAdmissionBeforeStrictDecoding(frame: String) async throws {
        try await withGuardSocket { context in
            let started = ContinuousClock.now
            let data = Data(frame.utf8)
            let before = await context.rig.listener.sessionUpdates
            let history = try context.fullHistory()
            for _ in 0..<60 {
                let response = try await submit(data, socket: context.socket)
                #expect(response.code == .decodeFailure && response.update == nil)
            }
            let admission = await context.endpoint.limiter
            let instant = ContinuousClock.now
            #expect(admission.retryAfter(for: "local-session-update", now: instant, limitPerMinute: 60) != nil)
            #expect(admission.retryAfter(for: "local-session-update-control", now: instant,
                                         limitPerMinute: 1) == nil)
            // The full submit bucket refuses even an undecodable action, before strict decoding can reject it.
            try expectGuard(await submit(data, socket: context.socket), reason: "runaway_guard")
            #expect(context.publisher.calls.withLock { $0 } == 0)
            #expect(context.rig.sends == 0)
            #expect(await context.rig.listener.sessionUpdates == before)
            #expect(await context.rig.listener.sessionUpdatesQuiet == false)
            #expect(try context.fullHistory() == history, "malformed actions create no durable update record")
            #expect(ContinuousClock.now - started < .seconds(60))
        }
    }

    @Test func controlsHaveTheirOwn120RequestWindow() async throws {
        try await withGuardSocket { context in
            let started = ContinuousClock.now
            let status = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .status))
            for _ in 0..<120 {
                #expect(try await submit(status, socket: context.socket).update?.outcome == .status)
            }
            let history = try context.history()
            try expectGuard(await submit(status, socket: context.socket), reason: "control_rate_limited")
            let quiet = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .quietOn))
            try expectGuard(await submit(quiet, socket: context.socket), reason: "control_rate_limited")
            #expect(try context.history() == history)
            #expect(context.publisher.calls.withLock { $0 } == 120)
            #expect(await context.rig.listener.sessionUpdatesQuiet == false)
            let data = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .submit,
                target: RecipientTestRig.target, text: "Synthetic card"))
            #expect(try await submit(data, socket: context.socket).update?.outcome == .delivered)
            #expect(ContinuousClock.now - started < .seconds(60))
        }
    }

    @Test func disabledUpdatesStillPassAdmissionFirst() async throws {
        try await withGuardSocket { context in
            await context.rig.listener.configureTestSessionUpdatePolicy(.init(enabled: false))
            let data = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .submit,
                target: "Synthetic unknown target", text: "Synthetic card"))
            for _ in 0..<60 {
                #expect(try await submit(data, socket: context.socket).update?.outcome == .notEnabled)
            }
            let history = try context.history()
            try expectGuard(await submit(data, socket: context.socket), reason: "runaway_guard")
            #expect(try context.history() == history)
            #expect(context.publisher.calls.withLock { $0 } == 60)
        }
    }

    @Test func floodLogsOncePerReasonPerMinuteAndWindowReopens() async throws {
        try await withGuardSocket { context in
            let capture = try GuardLogCapture(directory: context.directory)
            defer { capture.restore() }
            try await flood(context)
            let first = try capture.lines()
            #expect(first.filter { $0.hasPrefix("session_update_refused reason=runaway_guard retry_after=") }
                .count == 1)
            #expect(first.filter { $0.hasPrefix("session_update_refused reason=control_rate_limited retry_after=") }
                .count == 1)
            // Real time advances; no limiter prefill, injected clock or direct submission call.
            try await Task.sleep(for: .seconds(61))
            let data = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .submit,
                target: RecipientTestRig.target, text: "Synthetic card"))
            #expect(try await submit(data, socket: context.socket).update?.outcome == .delivered)
            try await flood(context, submits: 59)
            let lines = try capture.lines()
            #expect(lines.count == 4)
            #expect(lines.filter { $0.hasPrefix("session_update_refused reason=runaway_guard retry_after=") }
                .count == 2)
            #expect(lines.filter { $0.hasPrefix("session_update_refused reason=control_rate_limited retry_after=") }
                .count == 2)
            #expect(lines.allSatisfy { $0.range(of:
                #"^session_update_refused reason=(runaway_guard|control_rate_limited) retry_after=[1-9][0-9]?$"#,
                options: .regularExpression) != nil })
        }
    }

    private func flood(_ context: GuardSocketContext, submits: Int = 60) async throws {
        let data = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .submit,
            target: RecipientTestRig.target, text: "Synthetic card"))
        let status = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .status))
        for _ in 0..<submits { _ = try await submit(data, socket: context.socket) }
        for _ in 0..<120 { _ = try await submit(status, socket: context.socket) }
        for _ in 0..<20 {
            try expectGuard(await submit(data, socket: context.socket), reason: "runaway_guard")
            try expectGuard(await submit(status, socket: context.socket), reason: "control_rate_limited")
        }
    }

    private func expectGuard(_ response: LocalReplyResponse, reason: String) throws {
        #expect(response.error == nil)
        let report = try #require(response.update)
        #expect(report.outcome == .refused && report.reason == reason)
        #expect((report.retryAfter ?? 0) > 0 && (report.retryAfter ?? 61) <= 60)
    }
}

#endif
