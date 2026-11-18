import Foundation
import OSLog

private let updateLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "local-update")

extension LocalReplyEndpoint {
    /// Only the action is probed before admission; strict request decoding still follows.
    private struct ActionProbe: Decodable { let action: String? }

    /// Independent host-wide guards protect against a stuck local loop without a session send budget.
    func admitSessionUpdate(_ data: Data, from client: LocalReplyConnection) async -> Bool {
        let action = (try? JSONDecoder().decode(ActionProbe.self, from: data))?.action
        let control = action == "status" || action == "quiet_on"
        let bucket = control ? "local-session-update-control" : "local-session-update"
        let reason = control ? "control_rate_limited" : "runaway_guard"
        let now = clock.now
        if let wait = limiter.retryAfter(for: bucket, now: now, limitPerMinute: control ? 120 : 60) {
            let seconds = Int(wait.components.seconds) + (wait.components.attoseconds > 0 ? 1 : 0)
            var report = LocalSessionUpdateReport(outcome: .refused, reason: reason)
            report.retryAfter = seconds
            let logKey = "session-update-refusal-log:" + reason
            if limiter.retryAfter(for: logKey, now: now, limitPerMinute: 1) == nil {
                limiter.record(logKey, at: now)
                FileHandle.standardError.write(Data(
                    "session_update_refused reason=\(reason) retry_after=\(seconds)\n".utf8))
            }
            await respond(.update(report), to: client)
            return false
        }
        limiter.record(bucket, at: now)
        return true
    }

    /// Admitted requests record `pushed(tool: "local-update")` with the action token.
    /// Neither the target nor the update's text is logged or audited.
    func submitSessionUpdate(_ data: Data, from client: LocalReplyConnection) async {
        do {
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let request: LocalSessionUpdateRequest
            do { request = try JSONDecoder().decode(LocalSessionUpdateRequest.self, from: data) } catch {
                updateLogger.error("Local update decode failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.decodeFailure
            }
            // The action token, never the caller's target text: an unknown target is refused only after this record.
            let action = request.action.rawValue
            do { _ = try await audit.record(.pushed(tool: "local-update", target: action, bytes: data.count)) } catch {
                updateLogger.error("Local update audit failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.auditFailure
            }
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let report = await destination.sessionUpdate(request)
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            await respond(.update(report), to: client)
        } catch is CancellationError {
            retire(client.id)
        } catch {
            let reason = LocalReplyRefusal(error)
            guard !stopped, connections[client.id] != nil else { return retire(client.id) }
            await respond(.init(delivered: 0, error: reason.message, code: reason), to: client)
        }
    }
}
