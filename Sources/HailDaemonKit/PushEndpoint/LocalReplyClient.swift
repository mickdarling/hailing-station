public import Foundation
public import HailProtocol
import Network

public enum LocalReplyClientError: Error, Equatable, Sendable {
    case invalidSocket(String)
    case timeout
    case failed(String)
    case refused(String)
}

/// Sends one frame to the owner-only local endpoint and waits for its delivery result.
public enum LocalReplyClient {
    public static func submit(_ frame: Frame, socketURL: URL) async throws -> Int {
        guard socketURL.isFileURL,
              let info = try PolicyFile.info(socketURL) else {
            throw LocalReplyClientError.invalidSocket(socketURL.path)
        }
        do {
            try PolicyFile.check(info, at: socketURL, type: S_IFSOCK)
        } catch {
            throw LocalReplyClientError.invalidSocket(socketURL.path)
        }
        var request = try FrameCoding.encode(frame)
        guard request.count <= PayloadLimits.defaultMaxFrameBytes else {
            throw LocalReplyClientError.failed("frame too large")
        }
        request.append(UInt8(ascii: "\n"))
        let transaction = LocalReplyTransaction(socketURL: socketURL)
        let response = try await transaction.perform(request)
        if let error = response.error { throw LocalReplyClientError.refused(error) }
        return response.delivered
    }
}

private final class LocalReplyTransaction: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hail.local-reply-client")
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalReplyResponse, any Error>?
    private var sent = false

    init(socketURL: URL) {
        connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
    }

    func perform(_ request: Data) async throws -> LocalReplyResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            connection.stateUpdateHandler = { [weak self] state in self?.changed(state, request: request) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.finish(.failure(LocalReplyClientError.timeout))
            }
        }
    }

    private func changed(_ state: NWConnection.State, request: Data) {
        switch state {
        case .ready:
            let shouldSend = lock.withLock {
                guard !sent else { return false }
                sent = true
                return true
            }
            guard shouldSend else { return }
            connection.send(
                content: request, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    if let error { self?.finish(.failure(error)) } else { self?.receive(Data()) }
                }
            )
        case .failed(let error):
            finish(.failure(LocalReplyClientError.failed("\(error)")))
        case .cancelled:
            finish(.failure(LocalReplyClientError.failed("connection cancelled")))
        default:
            break
        }
    }

    private func receive(_ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let error { finish(.failure(error)); return }
            var response = buffer
            if let data { response.append(data) }
            guard response.count <= 4 * 1_024 else {
                finish(.failure(LocalReplyClientError.failed("response too large")))
                return
            }
            if let newline = response.firstIndex(of: UInt8(ascii: "\n")) {
                do {
                    finish(.success(try JSONDecoder().decode(LocalReplyResponse.self, from: response[..<newline])))
                } catch {
                    finish(.failure(LocalReplyClientError.failed("malformed response")))
                }
            } else if done {
                finish(.failure(LocalReplyClientError.failed("response ended early")))
            } else {
                receive(response)
            }
        }
    }

    private func finish(_ result: Result<LocalReplyResponse, any Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return }
        connection.cancel()
        pending.resume(with: result)
    }
}
