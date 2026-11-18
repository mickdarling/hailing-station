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

private struct GuardSocketContext {
    let rig: SilentUpdateRig
    let endpoint: LocalReplyEndpoint
    let publisher: GuardTestPublisher
    let directory: URL
    var socket: String { directory.appendingPathComponent("c/replies.sock").path }
    func history() throws -> [String] {
        try AuditHistory(directory: directory.appendingPathComponent("audit")).today()
            .filter { $0.contains("local-update") }
    }
}

private func withGuardSocket(_ body: (GuardSocketContext) async throws -> Void) async throws {
    let rig = try await SilentUpdateRig.make()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hs-rg-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let publisher = GuardTestPublisher(listener: rig.listener)
    let endpoint = try LocalReplyEndpoint(socketURL: directory.appendingPathComponent("c/replies.sock"),
        destination: publisher, audit: AuditLog(directory: directory.appendingPathComponent("audit")))
    do {
        try await endpoint.start()
        try await body(.init(rig: rig, endpoint: endpoint, publisher: publisher, directory: directory))
    } catch {
        await endpoint.stop()
        await rig.listener.stop()
        throw error
    }
    await endpoint.stop()
    await rig.listener.stop()
}

private final class GuardTestPublisher: HostReplyPublishing {
    let listener: WebSocketListener
    let calls = Mutex(0)
    init(listener: WebSocketListener) { self.listener = listener }
    func publish(_ frame: Frame) async throws -> Int { 1 }
    func sessionUpdate(_ request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        calls.withLock { $0 += 1 }
        return await listener.sessionUpdate(request)
    }
}

/// Serial socket tests capture the actual content-free stderr lines.
private final class GuardLogCapture {
    let url: URL
    let handle: FileHandle
    var original: Int32
    init(directory: URL) throws {
        url = directory.appendingPathComponent("refusals.log")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        original = dup(STDERR_FILENO)
        _ = dup2(handle.fileDescriptor, STDERR_FILENO)
    }
    func restore() {
        guard original >= 0 else { return }
        _ = dup2(original, STDERR_FILENO)
        close(original)
        original = -1
        try? handle.close()
    }
    func lines() throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("session_update_refused ") }
    }
    deinit { restore() }
}
#endif
