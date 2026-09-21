import Dispatch
import Foundation

public enum ConnectionProbeDaemon {
    public static func run(
        host: HailHost, arguments: [String], hostName: String,
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void
    ) async throws {
        let options = try options(arguments)
        let listener = try WebSocketListener(
            bindAddress: options.address, port: options.port, host: host,
            authorizer: options.authorizer, hostName: hostName, log: log
        )
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .utility))
        termination.setEventHandler { Task { await listener.stop(reason: "SIGTERM") } }
        interruption.setEventHandler { Task { await listener.stop(reason: "SIGINT") } }
        termination.resume()
        interruption.resume()
        defer {
            termination.cancel()
            interruption.cancel()
        }
        _ = try await listener.start()
        await listener.waitUntilStopped()
    }

    private struct Options {
        var address: String
        var port: UInt16
        var authorizer: any HostSessionAuthorizing
    }

    private static func options(_ arguments: [String]) throws -> Options {
        var address: String?
        var port: UInt16?
        var authorizer: (any HostSessionAuthorizing)?
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
            default: throw WebSocketListenerError.invalidArguments
            }
        }
        guard let address, let port, let authorizer else { throw WebSocketListenerError.invalidArguments }
        return Options(address: address, port: port, authorizer: authorizer)
    }
}
