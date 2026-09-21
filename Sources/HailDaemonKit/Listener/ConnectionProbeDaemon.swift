import Dispatch
import Foundation

public enum ConnectionProbeDaemon {
    // Signal ownership and two coordinated listeners make the composition root intentionally linear.
    // swiftlint:disable:next function_body_length
    public static func run(
        host: HailHost, arguments: [String], hostName: String,
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void
    ) async throws {
        let options = try options(arguments)
        let listener = try WebSocketListener(
            bindAddress: options.address, port: options.port, host: host,
            authorizer: options.authorizer, hostName: hostName, log: log
        )
        let replyEndpoint: LocalReplyEndpoint? = try options.personalTerminal.map { socket in
            try LocalReplyEndpoint(
                socketURL: socket, destination: listener,
                audit: AuditLog(directory: AuditHistory.standard().directory)
            )
        }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .utility))
        termination.setEventHandler {
            Task {
                await replyEndpoint?.stop()
                await listener.stop(reason: "SIGTERM")
            }
        }
        interruption.setEventHandler {
            Task {
                await replyEndpoint?.stop()
                await listener.stop(reason: "SIGINT")
            }
        }
        termination.resume()
        interruption.resume()
        defer {
            termination.cancel()
            interruption.cancel()
        }
        do {
            _ = try await listener.start()
            try await replyEndpoint?.start()
            await listener.waitUntilStopped()
            await replyEndpoint?.stop()
        } catch {
            await replyEndpoint?.stop()
            await listener.stop(reason: "startup failed")
            throw error
        }
    }

    private struct Options {
        var address: String
        var port: UInt16
        var authorizer: any HostSessionAuthorizing
        var personalTerminal: URL?
    }

    // Each accepted flag is an explicit branch; combinations are validated after parsing.
    // swiftlint:disable:next cyclomatic_complexity
    private static func options(_ arguments: [String]) throws -> Options {
        var address: String?
        var port: UInt16?
        var authorizer: (any HostSessionAuthorizing)?
        var personalTerminal = false
        var replySocket: URL?
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch flag {
            case "--bind": address = rest.popFirst()
            case "--port":
                if let value = rest.popFirst(), let parsed = UInt16(value), parsed > 0 { port = parsed }
            case "--connection-probe":
                guard authorizer == nil else { throw WebSocketListenerError.invalidArguments }
                authorizer = ConnectionProbeAuthorizer()
            case "--personal-terminal":
                guard authorizer == nil else { throw WebSocketListenerError.invalidArguments }
                authorizer = PersonalTerminalAuthorizer()
                personalTerminal = true
            case "--reply-socket":
                guard let path = rest.popFirst(), !path.isEmpty else {
                    throw WebSocketListenerError.invalidArguments
                }
                replySocket = URL(fileURLWithPath: path)
            default: throw WebSocketListenerError.invalidArguments
            }
        }
        guard let address, let port, let authorizer,
              personalTerminal || replySocket == nil else { throw WebSocketListenerError.invalidArguments }
        return Options(
            address: address, port: port, authorizer: authorizer,
            personalTerminal: personalTerminal ? (replySocket ?? LocalReplyEndpoint.standardSocket()) : nil
        )
    }
}
