// Daemon options and composition form one review boundary; ambient options grew past the limit with #552.
// swiftlint:disable file_length
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
        /// `--device-diagnostics` (#234), only with `--personal-terminal`: where accepted diagnostics are
        /// stored. Without the flag the capability is not advertised and nothing is written.
        var diagnostics: URL?
        /// `--session-updates` (#609), only with `--personal-terminal`: sessions may send unsolicited updates
        /// through `haild notify`. Off by default.
        var sessionUpdates = false
        /// `--host-health` (#614), only with `--personal-terminal`: answer a device's `health` with the doctor
        /// summary. Without the flag `host_health` is not advertised and the request is refused.
        var health = false
        /// `--voice-routes` (#636), only with `--personal-terminal`: the owner's named routes file, an absolute path.
        /// A file that is missing or does not load refuses startup, so a request naming a session never goes
        /// elsewhere because the routes were silently off.
        var voiceRoutes: URL?
    }

    // Each accepted flag is an explicit branch; combinations are validated after parsing.
    // swiftlint:disable:next cyclomatic_complexity
    static func options(_ arguments: [String]) throws -> Options {
        var address: String?, port: UInt16?
        var authorizer: (any HostSessionAuthorizing)?, personalTerminal = false
        // Value-free switches: `--single-terminal-reply-fallback`, `--device-diagnostics` (#234), and the rest below.
        var switches: Set<String> = [], replySocket: URL?, ambient: [String: String] = [:], voiceRoutes: URL?
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
            case "--reply-socket": replySocket = try path(from: &rest)
            case "--voice-routes" where voiceRoutes == nil: voiceRoutes = try path(from: &rest, absolute: true)
            case "--single-terminal-reply-fallback", "--device-diagnostics",
                 "--ambient-reply-control", "--session-updates", "--host-health": switches.insert(flag)
            case "--ambient-rightyo", "--ambient-rightyo-config", "--ambient-target", "--ambient-ack-clips",
                 "--ambient-destinations", "--ambient-duck-timeout":
                try parseAmbient(flag, from: &rest, into: &ambient)
            default: throw WebSocketListenerError.invalidArguments
            }
        }
        guard let address, let port, let authorizer,
              personalTerminal || (replySocket == nil && switches.isEmpty && voiceRoutes == nil),
              ambient.isEmpty || (personalTerminal && switches.contains("--single-terminal-reply-fallback")) else {
            throw WebSocketListenerError.invalidArguments
        }
        return Options(
            address: address, port: port, authorizer: authorizer,
            personalTerminal: personalTerminal ? (replySocket ?? LocalReplyEndpoint.standardSocket()) : nil,
            singleTerminalReplyFallback: switches.contains("--single-terminal-reply-fallback"),
            ambient: try ambientOptions(ambient, switches),
            diagnostics: switches.contains("--device-diagnostics") ? DiagnosticLog.standardDirectory() : nil,
            sessionUpdates: switches.contains("--session-updates"), health: switches.contains("--host-health"),
            voiceRoutes: voiceRoutes
        )
    }
}

extension ConnectionProbeDaemon {
    /// The listener and reply endpoint for `options`, sharing `audit` between the `--reply-to` socket and
    /// ambient dispatches (#203).
    static func compose(
        _ options: Options, host: HailHost, hostName: String, audit: AuditLog,
        timing: RightyoChildProcess.Timing = .init(), log: @escaping @Sendable (WebSocketListenerEvent) -> Void
    ) async throws -> (WebSocketListener, LocalReplyEndpoint?) {
        var authorizer = options.authorizer
        var ambient: (any AmbientListenerWiring)?
        #if os(macOS)
        if let ambientOptions = options.ambient {
            let router = try await ambientRouter(ambientOptions, host: host, timing: timing, audit: audit, log: log)
            authorizer = PersonalTerminalAuthorizer(ambientAudio: AmbientAudioGate(target: ambientOptions.target,
                                                                                  sink: router))
            ambient = router
        }
        #endif
        if let directory = options.diagnostics {
            let diagnostics = DiagnosticLog(directory: directory)
            await ambient?.observe(diagnostics) // The phone's playback reports, for reply control (rightyo#124).
            authorizer = PersonalTerminalAuthorizer(ambientAudio: authorizer.ambientAudio, diagnostics: diagnostics)
        }
        // Personal terminal only, checked again here as well as in `options` (#614 review).
        if options.health, options.personalTerminal != nil {
            authorizer = PersonalTerminalAuthorizer(ambientAudio: authorizer.ambientAudio,
                                                    diagnostics: authorizer.diagnostics,
                                                    health: HostHealthService().current)
        }
        #if os(macOS)
        if let file = options.voiceRoutes {
            // Options allow routes only with the personal terminal; anything else is a wiring fault, never "off".
            guard let personal = authorizer as? PersonalTerminalAuthorizer else {
                throw WebSocketListenerError.invalidArguments
            }
            authorizer = personal.naming(try voiceRoutes(file, log: log))
        }
        #endif
        let listener = try WebSocketListener(
            bindAddress: options.address, port: options.port, host: host,
            authorizer: authorizer, hostName: hostName,
            singleTerminalReplyFallback: options.singleTerminalReplyFallback, ambient: ambient, log: log
        )
        if options.sessionUpdates { await listener.enableSessionUpdates() }
        let replyEndpoint = try options.personalTerminal.map { socket in
            try LocalReplyEndpoint(socketURL: socket, destination: listener, audit: audit)
        }
        return (listener, replyEndpoint)
    }

    struct AmbientOptions: Equatable {
        var executable: URL, config: URL, target: String
        var ackClips: URL? // `--ambient-ack-clips` (rightyo#105); nil or no clips leaves acknowledgements off.
        var replyControl = false // `--ambient-reply-control` (rightyo#124), only with `--device-diagnostics`.
        var destinations: URL? // `--ambient-destinations` (#552); a missing file leaves spoken notes off.
        /// `--ambient-duck-timeout` (#735): whole seconds in `AmbientRightyoRouter.duckTimeoutRange`; nil is the default.
        var duckTimeout: TimeInterval?
        /// Where spoken notes keep their Shortcut inputs (#552); tests point it at a scratch folder.
        var noteInputs = VoiceNoteInputs()
    }

    /// A flag's path: never empty and, when `absolute`, starting at `/`.
    fileprivate static func path(from rest: inout ArraySlice<String>, absolute: Bool = false) throws -> URL {
        guard let path = rest.popFirst(), !path.isEmpty, !absolute || path.hasPrefix("/") else {
            throw WebSocketListenerError.invalidArguments
        }
        return URL(fileURLWithPath: path)
    }

    /// Each ambient flag once, with a value: paths absolute, the target never another option, the duck timeout digits.
    fileprivate static func parseAmbient(
        _ flag: String, from rest: inout ArraySlice<String>, into ambient: inout [String: String]
    ) throws {
        let digits = { (value: String) in value.count <= 6 && value.allSatisfy { ("0"..."9").contains($0) } }
        guard ambient[flag] == nil, let value = rest.popFirst(), !value.isEmpty, !value.hasPrefix("-"),
              flag == "--ambient-duck-timeout" ? digits(value) : flag == "--ambient-target" || value.hasPrefix("/")
        else {
            throw WebSocketListenerError.invalidArguments
        }
        ambient[flag] = value
    }

    fileprivate static func ambientOptions(_ ambient: [String: String], _ on: Set<String>) throws -> AmbientOptions? {
        let control = on.contains("--ambient-reply-control"), diagnostics = on.contains("--device-diagnostics")
        guard !control || (!ambient.isEmpty && diagnostics) else { throw WebSocketListenerError.invalidArguments }
        guard !ambient.isEmpty else { return nil }
        guard let executable = ambient["--ambient-rightyo"], let config = ambient["--ambient-rightyo-config"],
              let target = ambient["--ambient-target"] else { throw WebSocketListenerError.invalidArguments }
        let duckTimeout = try ambient["--ambient-duck-timeout"].map { value in
            guard let seconds = TimeInterval(value), AmbientRightyoRouter.duckTimeoutRange.contains(seconds) else {
                throw WebSocketListenerError.invalidArguments
            }
            return seconds
        }
        return AmbientOptions(executable: URL(fileURLWithPath: executable), config: URL(fileURLWithPath: config),
                              target: target, ackClips: ambient["--ambient-ack-clips"].map(URL.init(fileURLWithPath:)),
                              replyControl: control,
                              destinations: ambient["--ambient-destinations"].map(URL.init(fileURLWithPath:)),
                              duckTimeout: duckTimeout)
    }

    #if os(macOS)
    /// The owner's voice routes (#636), logged by count only. Asked for but missing, or failing to load, they refuse
    /// startup rather than letting a named request go to whichever target was chosen before.
    static func voiceRoutes(
        _ file: URL, log: @Sendable (WebSocketListenerEvent) -> Void
    ) throws -> VoiceRoutes {
        do {
            guard let routes = try VoiceRoutes.load(file) else { throw VoiceRoutes.LoadError.missing }
            log(.init(event: "voice_routes", detail: "count=\(routes.routes.count)"))
            return routes
        } catch let error as VoiceRoutes.LoadError {
            log(.init(event: "voice_routes", detail: "error=\(error)"))
            throw VoiceRoutesStartupError(path: file.path, reason: error)
        }
    }

    /// A routes file that stopped startup, named so the operator can find it: `--voice-routes <path>: missing`.
    public struct VoiceRoutesStartupError: Error, Equatable, CustomStringConvertible {
        public let path: String
        public let reason: VoiceRoutes.LoadError
        public var description: String { "--voice-routes \(path): \(reason)" }
    }

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
        let library = options.ackClips.map(AmbientAckLibrary.init(directory:))
        let clips = library.flatMap { $0.isEmpty ? nil : $0 }
        // Skipped clips are counted even when none loaded, so a too-large recording is never silent.
        if let library { log(.init(event: "ambient_ack_clips", detail: library.startupDetail)) }
        var configuration = AmbientRightyoRouter.Configuration(
            executable: options.executable, config: options.config, target: options.target, binding: binding,
            timing: timing, audit: audit, acknowledgements: clips, replyControl: options.replyControl
        )
        if let duckTimeout = options.duckTimeout { configuration.duckTimeout = duckTimeout }
        // Spoken notes (#552): a malformed file leaves them off and says so, rather than refusing to start.
        if let file = options.destinations {
            // Inputs a haild left mid-Shortcut, in its own folder and off the startup path: never a wait for ready.
            VoiceNoteInputs.inBackground { [inputs = options.noteInputs] in inputs.sweep() }
            do {
                configuration.destinations = try VoiceDestinations.load(file)
                let count = configuration.destinations.map { "count=\($0.destinations.count)" } ?? "missing"
                log(.init(event: "ambient_destinations", detail: count))
            } catch {
                log(.init(event: "ambient_destinations", detail: "error=\(error)"))
            }
        }
        return AmbientRightyoRouter(configuration: configuration, log: log)
    }
    #endif
}
