#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
private struct StdioPending {
    let continuation: CheckedContinuation<JSONValue, any Error>
    let reply: Bool
    var written = false
    var response: Result<JSONValue, any Error>?
}
private struct StdioWork {
    let writer: Task<Void, Never>
    let timer: Task<Void, Never>
    func join() async { timer.cancel(); await writer.value; await timer.value }
}
/// Transport only. Scoped cleanup is not proof of provider-turn interruption or authentication.
actor CodexStdioTransport {
    private nonisolated let child: OwnedStdioChild
    private nonisolated let stopping = Mutex(false)
    private let limits: CodexStdioLimits
    private var pending: [Int64: StdioPending] = [:]
    private var work: [Int64: StdioWork] = [:]
    private var notifications: [(CodexStdioNotification, Int)] = []
    private var retainedBytes = 0
    private var nextID: Int64 = 1
    private var terminal: CodexStdioError?
    private var consumer: CheckedContinuation<CodexStdioNotification, any Error>?
    private var reader: Task<Void, Never>?
    init(command: OwnedStdioCommand, limits: CodexStdioLimits = .init()) throws {
        guard limits.requestTimeout > .zero, limits.requestTimeout <= .seconds(60),
              (1...4).contains(limits.maxRequests), (1...256).contains(limits.maxNotifications),
              (1...262_144).contains(limits.maxNotificationBytes), (1...65_536).contains(limits.maxFrameBytes) else {
            throw CodexStdioError.invalidConfiguration
        }
        child = try OwnedStdioChild(command: command, grace: limits.terminationGrace); self.limits = limits
    }
    static func withTransport<Result: Sendable>(
        command: OwnedStdioCommand, limits: CodexStdioLimits = .init(),
        operation: @Sendable (CodexStdioTransport) async throws -> Result
    ) async throws -> Result {
        guard !Task.isCancelled else { throw CodexStdioError.stopped }
        let transport = try CodexStdioTransport(command: command, limits: limits)
        return try await withTaskCancellationHandler {
            do { let result = try await operation(transport); await transport.join(); return result } catch {
                await transport.join(); throw error
            }
        } onCancel: { transport.cancel() }
    }
    nonisolated func cancel() { stopping.withLock { $0 = true }; child.cancel() }
    var isReaped: Bool { child.isReaped }
    var isWaitingForNotification: Bool { consumer != nil }
    func join() async {
        cancel(); fail(.stopped)
        let outstanding = work
        await child.join()
        for task in outstanding.values { await task.join() }
        await reader?.value
        work.removeAll()
    }
    func request(_ method: CodexStdioMethod, params: JSONValue = .object([:])) async throws -> JSONValue {
        try await send(method.rawValue, params: params, reply: true)
    }
    func notify(_ method: CodexStdioNotice, params: JSONValue = .object([:])) async throws {
        _ = try await send(method.rawValue, params: params, reply: false)
    }
    private func send(_ method: String, params: JSONValue, reply: Bool) async throws -> JSONValue {
        try requireActive()
        guard work.count < limits.maxRequests, nextID < Int64.max else { throw CodexStdioError.capacityExceeded }
        let id = nextID
        var object: [String: JSONValue] = ["method": .string(method), "params": params]
        if reply { object["id"] = .integer(id) }
        let data = try CodexJSONL.encode(.object(object))
        guard data.count <= limits.maxFrameBytes else { throw CodexStdioError.oversizedFrame }
        _ = try CodexJSONL.decode(data); nextID += 1; startReader()
        do {
            let result: JSONValue = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled { continuation.resume(throwing: CodexStdioError.stopped); return }
                    pending[id] = StdioPending(continuation: continuation, reply: reply)
                    schedule(id, data: data)
                }
            } onCancel: { self.cancel() }
            await complete(id); return result
        } catch { await complete(id); throw error }
    }
    private func schedule(_ id: Int64, data: Data) {
        let timer = Task {
            do { try await Task.sleep(for: limits.requestTimeout) } catch { return }
            if pending[id] != nil { fail(.timedOut) }
        }
        let writer = Task {
            do {
                try await child.write(data + Data([10]))
                writeFinished(id)
            } catch { fail(error as? CodexStdioError ?? .transportLost) }
        }
        work[id] = StdioWork(writer: writer, timer: timer)
    }
    private func complete(_ id: Int64) async {
        guard let task = work[id] else { return }
        await task.join(); work[id] = nil
    }
    func nextNotification() async throws -> CodexStdioNotification {
        try requireActive()
        guard consumer == nil else { throw CodexStdioError.capacityExceeded }
        startReader()
        if !notifications.isEmpty {
            let (value, count) = notifications.removeFirst(); retainedBytes -= count; return value
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CodexStdioError.stopped) } else {
                    consumer = continuation
                }
            }
        } onCancel: { self.cancel() }
    }
    private func requireActive() throws {
        if let terminal { throw terminal }
        guard !Task.isCancelled, !child.isStopped, !stopping.withLock({ $0 }) else { throw CodexStdioError.stopped }
    }
    private func startReader() { if reader == nil { reader = Task { await read() } } }
}
extension CodexStdioTransport {
    private func read() async {
        do {
            var frames = try CodexJSONL(maxFrameBytes: limits.maxFrameBytes)
            for try await chunk in child.chunks {
                try frames.append(chunk) { value, count in try receive(value, bytes: count) }
            }
            try frames.finish(); fail(.transportLost)
        } catch { fail(error as? CodexStdioError ?? .transportLost) }
    }
    private func receive(_ value: JSONValue, bytes: Int) throws {
        guard terminal == nil, !stopping.withLock({ $0 }) else { throw CodexStdioError.stopped }
        switch try CodexRPCEnvelope(value) {
        case .response(let id, let result): try reply(id, result: .success(result))
        case .refusal(let id): try reply(id, result: .failure(CodexStdioError.providerRefused))
        case .notification(let method, let params):
            let value = CodexStdioNotification(method: method, params: params)
            guard notifications.count < limits.maxNotifications,
                  bytes <= limits.maxNotificationBytes - retainedBytes else { throw CodexStdioError.capacityExceeded }
            if let consumer { self.consumer = nil; consumer.resume(returning: value); return }
            notifications.append((value, bytes)); retainedBytes += bytes
        }
    }
    private func reply(_ id: Int64, result: Result<JSONValue, any Error>) throws {
        guard pending[id]?.reply == true, pending[id]?.response == nil else {
            throw CodexStdioError.unknownResponse
        }
        pending[id]?.response = result; finish(id)
    }
    private func writeFinished(_ id: Int64) {
        guard pending[id] != nil else { return }
        pending[id]?.written = true
        if pending[id]?.reply == false { pending[id]?.response = .success(.null) }
        finish(id)
    }
    private func finish(_ id: Int64) {
        guard let request = pending[id], request.written, let result = request.response else { return }
        pending[id] = nil
        work[id]?.timer.cancel(); request.continuation.resume(with: result)
    }
    private func fail(_ error: CodexStdioError) {
        guard terminal == nil else { return }
        terminal = error; cancel()
        let outstanding = pending; pending.removeAll()
        for request in outstanding.values { request.continuation.resume(throwing: error) }
        for task in work.values { task.timer.cancel() }
        consumer?.resume(throwing: error); consumer = nil; notifications.removeAll(); retainedBytes = 0
    }
}
#endif
