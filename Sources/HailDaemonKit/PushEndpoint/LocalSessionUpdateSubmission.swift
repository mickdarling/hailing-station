import Foundation
import OSLog

private let updateLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "local-update")

extension LocalReplyEndpoint {
    /// Same admission budget and fail-closed audit as an ambient request: `pushed(tool: "local-update")` with the
    /// action token. Neither the target nor the update's text is logged or audited.
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
