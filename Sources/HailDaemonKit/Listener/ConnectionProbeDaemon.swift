import Dispatch
import Foundation
import Synchronization

public enum ConnectionProbeDaemon {
    /// Signal ownership and the two coordinated listeners from `compose`.
    public static func run(
        host: HailHost, arguments: [String], hostName: String,
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void
    ) async throws {
        // One writer per audit directory: a second `AuditLog` on the same day's file is refused `inUse`.
        let (listener, replyEndpoint) = try await compose(
            try options(arguments), host: host, hostName: hostName,
            audit: AuditLog(directory: AuditHistory.standard().directory), log: log
        )
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .utility))
        // The first signal stops gracefully (bounded by the ambient shutdown grace); a second exits at once.
        let signalled = Mutex(false)
        for (source, name) in [(termination, "SIGTERM"), (interruption, "SIGINT")] {
            source.setEventHandler {
                let again = signalled.withLock { seen in
                    defer { seen = true }
                    return seen
                }
                if again { exit(1) }
                Task {
                    await replyEndpoint?.stop()
                    await listener.stop(reason: name)
                }
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

    struct Options {
        var address: String
        var port: UInt16
        var authorizer: any HostSessionAuthorizing
        var personalTerminal: URL?
        /// `--single-terminal-reply-fallback`: a single-phone demo bridge, only with `--personal-terminal`.
        var singleTerminalReplyFallback = false
        /// `--ambient-rightyo`, `--ambient-rightyo-config`, `--ambient-target` (#203): all three or none, only
        /// with `--personal-terminal --single-terminal-reply-fallback` (replies reach the phone only that way).
        var ambient: AmbientOptions?
    }

    // Each accepted flag is an explicit branch; combinations are validated after parsing.
    // swiftlint:disable:next cyclomatic_complexity
    static func options(_ arguments: [String]) throws -> Options {
        var address: String?
        var port: UInt16?
        var authorizer: (any HostSessionAuthorizing)?
        var personalTerminal = false
        var singleTerminalReplyFallback = false
        var replySocket: URL?, ambient: [String: String] = [:]
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
            case "--single-terminal-reply-fallback": singleTerminalReplyFallback = true
            case "--ambient-rightyo", "--ambient-rightyo-config", "--ambient-target":
                try parseAmbient(flag, from: &rest, into: &ambient)
            default: throw WebSocketListenerError.invalidArguments
            }
        }
        guard let address, let port, let authorizer,
              personalTerminal || (replySocket == nil && !singleTerminalReplyFallback),
              ambient.isEmpty || (personalTerminal && singleTerminalReplyFallback) else {
            throw WebSocketListenerError.invalidArguments
        }
        return Options(
            address: address, port: port, authorizer: authorizer,
            personalTerminal: personalTerminal ? (replySocket ?? LocalReplyEndpoint.standardSocket()) : nil,
            singleTerminalReplyFallback: singleTerminalReplyFallback, ambient: try ambientOptions(ambient)
        )
    }
}

extension ConnectionProbeDaemon {
    /// The listener and reply endpoint for `options`, sharing `audit` between the `--reply-to` socket and
    /// ambient dispatches (#203).
    static func compose(
        _ options: Options, host: HailHost, hostName: String, audit: AuditLog,
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void
    ) async throws -> (WebSocketListener, LocalReplyEndpoint?) {
        var authorizer = options.authorizer
        var ambient: (any AmbientListenerWiring)?
        #if os(macOS)
        if let ambientOptions = options.ambient {
            let router = try await ambientRouter(ambientOptions, host: host, audit: audit, log: log)
            authorizer = PersonalTerminalAuthorizer(ambientAudio: AmbientAudioGate(target: ambientOptions.target,
                                                                                  sink: router))
            ambient = router
        }
        #endif
        let listener = try WebSocketListener(
            bindAddress: options.address, port: options.port, host: host,
            authorizer: authorizer, hostName: hostName,
            singleTerminalReplyFallback: options.singleTerminalReplyFallback, ambient: ambient, log: log
        )
        let replyEndpoint = try options.personalTerminal.map { socket in
            try LocalReplyEndpoint(socketURL: socket, destination: listener, audit: audit)
        }
        return (listener, replyEndpoint)
    }

    struct AmbientOptions: Equatable {
        var executable: URL
        var config: URL
        var target: String
    }

    /// Each ambient flag once, with a value: paths absolute, the target never another option.
    fileprivate static func parseAmbient(
        _ flag: String, from rest: inout ArraySlice<String>, into ambient: inout [String: String]
    ) throws {
        guard ambient[flag] == nil, let value = rest.popFirst(), !value.isEmpty, !value.hasPrefix("-"),
              flag == "--ambient-target" || value.hasPrefix("/") else {
            throw WebSocketListenerError.invalidArguments
        }
        ambient[flag] = value
    }

    fileprivate static func ambientOptions(_ ambient: [String: String]) throws -> AmbientOptions? {
        guard !ambient.isEmpty else { return nil }
        guard let executable = ambient["--ambient-rightyo"], let config = ambient["--ambient-rightyo-config"],
              let target = ambient["--ambient-target"] else { throw WebSocketListenerError.invalidArguments }
        return AmbientOptions(executable: URL(fileURLWithPath: executable), config: URL(fileURLWithPath: config),
                              target: target)
    }

    #if os(macOS)
    /// Startup validation (#203): the executable and config pass the child's own checks, and the target is
    /// listed, alive and bound. The binding is pinned for the daemon's lifetime, as `haild rightyo` pins it.
    static func ambientRouter(
        _ options: AmbientOptions, host: HailHost, timing: RightyoChildProcess.Timing = .init(),
        audit: AuditLog? = nil, log: @escaping @Sendable (WebSocketListenerEvent) -> Void
    ) async throws -> AmbientRightyoRouter {
        // The reply block quotes the target: an unsafe or guarded id would refuse every stream, so refuse now.
        try RightyoInputConsumer.validateTarget(options.target)
        try RightyoChildProcess.validate(executable: options.executable, config: options.config)
        let listing = try await host.registry.listing()
        guard let listed = listing.first(where: { $0.info.id == options.target }) else {
            throw HostError.unknownTarget(options.target)
        }
        guard listed.info.alive, let binding = listed.binding, !binding.isEmpty else {
            throw RightyoInputError.unavailableBinding
        }
        return AmbientRightyoRouter(configuration: .init(
            executable: options.executable, config: options.config, target: options.target, binding: binding,
            timing: timing, audit: audit
        ), log: log)
    }
    #endif
}
