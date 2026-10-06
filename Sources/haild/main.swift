import Darwin
import Foundation
import HailDaemonKit

// Command handlers stay in focused companion files; this composition and error-mapping surface is one line over time.
// swiftlint:disable file_length

// haild: the host daemon's command line (#10 item 1, #41). `run` starts with the read-only connection
// probe (#98); the push endpoint, LaunchAgent, and `pair` arrive with their slices. Exit codes: 2 unknown
// target, 3 refused by the sanitizer, 4 adapter
// unavailable or adapter error, 5 unbound, 6 partial, 7 denied by policy, 8 confirmation needed or cancelled,
// 9 policy file unusable, 64 usage. A `rightyo --reply-to` dispatch the daemon refuses keeps the direct
// path's code where the outcome is the same (8 confirmation needed, 7 rebound); every other dispatch or
// socket refusal exits 1 with the daemon's reason, as `haild reply` does.

// A launchd job often inherits only the system PATH, which omits Homebrew on Apple Silicon and Intel.
// Keep an explicit override for nonstandard installations, then try the two standard Homebrew prefixes.
let configuredTmux = ProcessInfo.processInfo.environment["HAIL_TMUX"]
let tmuxPath = configuredTmux.flatMap { $0.isEmpty ? nil : $0 }
    ?? ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    ?? "tmux"
let standardError = FileHandle.standardError
func makeHost(sanitizing: SanitizePolicy = .init()) async throws -> HailHost {
    let registry = Registry()
    let terminal = TmuxAdapter(runner: ProcessCommandRunner(), tmux: tmuxPath)
    try await registry.register(terminal)
    let bridges = try TmuxReplyAdapter.configuredTargets(in: ProcessInfo.processInfo.environment)
    if !bridges.isEmpty {
        try await registry.register(TmuxReplyAdapter(terminal: terminal, targets: bridges))
    }
    return try HailHost(registry: registry, sanitizing: sanitizing, store: PolicyFile.standard())
}

func usage() -> Never {
    standardError.write(Data("""
    usage: haild targets
           haild targets allow <target-id> [--tier open|confirm|locked] [--capture]
           haild targets deny <target-id>
           haild targets tier <target-id> <open|confirm|locked>
           haild send <target-id> <text>      (text is one argument; quote it)
           haild reply <target-id> [--host <host-id>] [--text <text>] [--pcm16 <path>|--say <text>]
      [--request <opaque-request-UUID>] [--sample-rate <hz>] [--socket <path>]
      [--renderer-output-root <private-existing-directory>]
           haild rightyo <target-id> --session <producer-session-id> [--allow-synthetic]
      [--reply-to <connection-UUID>] [--socket <path>]
           haild rightyo --session <producer-session-id> --dry-run  (JSONL on stdin)
           haild status [--json]
           haild doctor      (checks the running daemon against this haild; exits 1 with a fix per failure)
           haild audit verify|tail|today
           haild diagnostics tail [--device <name>] [--since <90s|15m|2h|1d|ISO-8601>] [--limit <n>] [--json]
           haild diagnostics show <session-id-or-prefix> [--json]
           haild diagnostics clear
           haild run --bind <address> --port <port> --connection-probe
           haild run --bind <address> --port <port> --personal-terminal [--reply-socket <path>]
      [--single-terminal-reply-fallback]
           haild run --bind <address> --port <port> --personal-terminal [--reply-socket <path>]
      --single-terminal-reply-fallback --ambient-rightyo <absolute-rightyo-path>
      --ambient-rightyo-config <absolute-config-path> --ambient-target <target-id>
      (opt-in ambient listening; trusted network only: no TLS or peer authentication yet)
           haild run ... --personal-terminal --device-diagnostics
      (opt-in device diagnostics log: enumerated events only, owner-only, capped at 5 MiB)

    """.utf8))
    exit(64)
}

func note(_ message: String) {
    standardError.write(Data("haild: \(message)\n".utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    note(message)
    exit(code)
}

func reportListingFailures(_ host: HailHost) async {
    for (kind, reason) in await host.listingFailures().sorted(by: { $0.key < $1.key }) {
        note("\(kind): \(reason)")
    }
}

/// `targets`: one line per target: id, alive or dead, its policy state, its name. The policy state is
/// `denied` (not allowed), the tier, or the tier plus `rebound` (the program behind the name changed) or
/// `unbound` (the adapter reports no identity to match).
func listTargets(_ host: HailHost) async throws {
    let policy = await host.currentPolicy
    let unusable = await host.policyFailure != nil
    for listed in try await host.registry.listing() {
        let target = listed.info
        var state = unusable ? "policy-unusable" : "denied"
        if !unusable, let allowed = policy.targets[target.id] {
            state = allowed.tier.rawValue
            if listed.binding == nil {
                state += " unbound"
            } else if allowed.binding != listed.binding {
                state += " rebound"
            }
        }
        print("\(target.id)\t\(target.alive ? "alive" : "dead")\t\(state)\t\(target.name)")
    }
    await reportListingFailures(host)
    if let failure = await host.policyFailure { fail("policy unusable, delivery refused: \(failure)", code: 9) }
}

func parseTier(_ raw: String) -> Tier {
    guard let tier = Tier(rawValue: raw) else { fail("unknown tier \(raw); use open, confirm, or locked", code: 64) }
    return tier
}

/// `targets allow <id> [--tier t] [--capture]`.
func allowTarget(_ host: HailHost, _ arguments: ArraySlice<String>) async throws {
    guard let id = arguments.first else { usage() }
    var tier = Tier.confirm
    var capture = false
    var rest = arguments.dropFirst()
    while let flag = rest.popFirst() {
        switch flag {
        case "--tier":
            guard let raw = rest.popFirst() else { usage() }
            tier = parseTier(raw)
        case "--capture": capture = true
        default: usage()
        }
    }
    let allowed = try await host.allow(id, tier: tier, capture: capture)
    print("allowed \(id) at tier \(allowed.tier.rawValue)\(allowed.capture ? " with capture" : "")")
}

func manageTargets(_ host: HailHost, _ arguments: ArraySlice<String>) async throws {
    switch arguments.first {
    case nil:
        try await listTargets(host)
    case "allow":
        try await allowTarget(host, arguments.dropFirst())
    case "deny":
        guard arguments.count == 2, let id = arguments.last else { usage() }
        print(try await host.deny(id) ? "denied \(id)" : "\(id) was not allowed")
    case "tier":
        guard arguments.count == 3, let id = arguments.dropFirst().first, let raw = arguments.last else { usage() }
        let tier = parseTier(raw)
        guard try await host.setTier(tier, for: id) else { fail("\(id) is not allowed; allow it first", code: 7) }
        print("\(id) is now \(tier.rawValue)")
    default:
        usage()
    }
}

/// The read-back at the keyboard: print every line, then wait for the word `send`. Not a terminal, or any
/// other answer, cancels. There is no flag that skips this; the read-back is the control (#41 item 2).
func confirmAtKeyboard(_ host: HailHost, _ readBack: ReadBack, id: String, text: String) async throws {
    note("\(id) needs confirmation: \(readBack.reason)")
    if !readBack.guardHits.isEmpty { note("guarded: \(readBack.guardHits.joined(separator: ", "))") }
    for line in readBack.lines { standardError.write(Data("  > \(line)\n".utf8)) }
    guard isatty(STDIN_FILENO) == 1 else { fail("confirmation needed; run from a terminal to read back", code: 8) }
    standardError.write(Data("type send to deliver, anything else to cancel: ".utf8))
    guard readLine()?.trimmingCharacters(in: .whitespaces) == "send" else { fail("cancelled", code: 8) }
    switch try await host.send(text, to: id, confirmedHash: readBack.hash) {
    case .delivered(let lines): print("sent \(lines.count) line\(lines.count == 1 ? "" : "s") to \(id)")
    case .needsConfirmation: fail("confirmation expired or the target changed; try again", code: 8)
    }
}

func send(_ host: HailHost, id: String, text: String) async throws {
    switch try await host.send(text, to: id) {
    case .delivered(let lines): print("sent \(lines.count) line\(lines.count == 1 ? "" : "s") to \(id)")
    case .needsConfirmation(let readBack): try await confirmAtKeyboard(host, readBack, id: id, text: text)
    }
}

/// Exits 9 when the policy is unusable, after printing, so a health check cannot read "healthy".
func status(_ host: HailHost) async throws {
    print(DaemonInfo.banner)
    let failure = await host.policyFailure
    if let failure {
        print("policy: UNUSABLE, delivery refused: \(failure)")
    } else {
        let policy = await host.currentPolicy
        print("policy: \(host.policySummary), \(policy.targets.count) allowed")
    }
    print("targets: \(try await host.targets().count)")
    await reportListingFailures(host)
    if failure != nil { exit(9) }
}

/// `rightyo` arguments: the target first unless dry run, then flags in any order. `--reply-to` names the
/// listener connection (its peer UUID, as logged on `session_connected`) that will own each reply (#188);
/// `--socket` is the daemon's owner-only reply socket and is only meaningful with it. Dry run never
/// touches a socket, so neither flag is accepted with `--dry-run`. Any other shape is usage (64).
private struct RightyoOptions {
    var target = "dry-run"
    var session = ""
    var dryRun = false
    var allowSynthetic = false
    var replyTo: UUID?
    var socket = LocalReplyEndpoint.standardSocket()
    var socketGiven = false

    static func parse(_ arguments: ArraySlice<String>) -> RightyoOptions {
        var options = RightyoOptions()
        var rest = arguments
        var targetGiven = false
        if let first = rest.first, !first.hasPrefix("--") {
            options.target = first
            targetGiven = true
            rest = rest.dropFirst()
        }
        while let flag = rest.popFirst() { options.apply(flag, &rest) }
        guard !options.session.isEmpty, targetGiven != options.dryRun,
              !options.dryRun || (options.replyTo == nil && !options.socketGiven),
              options.replyTo != nil || !options.socketGiven else { usage() }
        return options
    }

    private mutating func apply(_ flag: String, _ rest: inout ArraySlice<String>) {
        switch flag {
        case "--dry-run": dryRun = true
        case "--allow-synthetic": allowSynthetic = true
        case "--session": session = Self.value(for: flag, from: &rest)
        case "--reply-to":
            guard let id = UUID(uuidString: Self.value(for: flag, from: &rest)) else { usage() }
            replyTo = id
        case "--socket":
            socket = URL(fileURLWithPath: Self.value(for: flag, from: &rest))
            socketGiven = true
        default: usage()
        }
    }

    /// The value of a value-taking option: present, non-empty and never another option. `--session --dry-run`
    /// is usage, not a session named `--dry-run` that would build a live host under the dry-run shape.
    private static func value(for flag: String, from rest: inout ArraySlice<String>) -> String {
        guard let value = rest.popFirst(), !value.isEmpty, !value.hasPrefix("-") else { usage() }
        return value
    }
}

/// Foreground local stdin only. The caller opts into both the target and producer session (#183). With
/// `--reply-to` the host is used for the pinned binding only and every admitted request is dispatched by
/// the running daemon on behalf of that connection; without it, delivery is the direct path, unchanged.
func rightyo(_ arguments: ArraySlice<String>) async throws {
    let options = RightyoOptions.parse(arguments)
    let host = options.dryRun ? nil : try await makeHost(sanitizing: HailHost.localPromptSanitizing)
    let dispatcher = options.replyTo.map { RightyoSocketDispatcher(connection: $0, socketURL: options.socket) }
    let consumer = try RightyoInputConsumer(host: host, target: options.target,
        binding: try await rightyoBinding(host, target: options.target), session: options.session,
        allowSynthetic: options.allowSynthetic, dispatcher: dispatcher)
    note("RightyO local input ready; finalized-turn events only. No microphone capture started.")
    if let connection = options.replyTo {
        note("requests are dispatched by the running daemon for connection \(connection.uuidString)")
    }
    var buffer = Data()
    while let chunk = try rightyoReadChunk() {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            try await consumeRightyo(Data(line), with: consumer, options: options)
        }
        guard buffer.count <= 1_200_000 else { throw RightyoInputError.capacity }
    }
    if !buffer.isEmpty { try await consumeRightyo(buffer, with: consumer, options: options) }
    try await consumer.finish()
}

private func rightyoReadChunk() throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if count > 0 { return Data(bytes.prefix(count)) }
        if count == 0 { return nil }
        if errno != EINTR { throw RightyoInputError.invalidEvent }
    }
}

private func rightyoBinding(_ host: HailHost?, target: String) async throws -> String {
    guard let host else { return "dry-run" }
    let listing = try await host.registry.listing()
    guard let listed = listing.first(where: { $0.info.id == target }),
          let binding = listed.binding, !binding.isEmpty else { throw RightyoInputError.unavailableBinding }
    return binding
}

private func consumeRightyo(_ line: Data, with consumer: RightyoInputConsumer, options: RightyoOptions) async throws {
    let event = try RightyoInputEvent.decode(line)
    guard try await consumer.consume(event) else { return }
    let receipt: String
    if let superseded = event.supersededRequestId {
        receipt = "rightyo: override \(superseded)"
    } else if options.dryRun {
        receipt = "rightyo: request validated (dry run; no delivery)"
    } else if let connection = options.replyTo {
        // The receipt names who owns the reply, never the prompt. No request means the prompt landed but
        // nobody can be answered through `haild reply --request` (legacy adapter, or ownership lost).
        let delivered = await consumer.lastReceipt
        if let caveat = delivered?.caveat { note(caveat) }
        let ownership = delivered?.request.map { "reply request \($0.uuidString)" } ?? "no reply ownership"
        receipt = "rightyo: request delivered to \(options.target) for connection \(connection.uuidString)"
            + " (\(ownership))"
    } else {
        receipt = "rightyo: request delivered"
    }
    FileHandle.standardOutput.write(Data((receipt + "\n").utf8))
}

func exitCode(for denial: Denial) -> Int32 {
    if case .unbound = denial { return 5 }
    return 7
}

func logNetworkEvent(_ event: WebSocketListenerEvent) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(event) else { return }
    standardError.write(data + Data("\n".utf8))
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
do {
    switch command {
    case "targets": try await manageTargets(try await makeHost(), arguments.dropFirst())
    case "send":
        guard arguments.count == 3 else { usage() }
        try await send(try await makeHost(), id: arguments[1], text: arguments[2])
    case "status":
        switch arguments.dropFirst().first {
        case nil: try await status(try await makeHost())
        case "--json" where arguments.count == 2: try statusJSON()
        default: usage()
        }
    case "doctor" where arguments.count == 1: doctor()
    case "reply": try await reply(arguments.dropFirst())
    case "rightyo": try await rightyo(arguments.dropFirst())
    case "audit": try audit(arguments.dropFirst())
    case "diagnostics": try diagnostics(arguments.dropFirst())
    case "run":
        let hostName = try HostIdentity.resolve()
        let recorder = DaemonStatusRecorder(
            file: DaemonStatus.standardFile(), hostID: hostName, build: BuildIdentity.current()
        )
        try await ConnectionProbeDaemon.run(
            host: try await makeHost(), arguments: Array(arguments.dropFirst()), hostName: hostName,
            log: { event in
                logNetworkEvent(event)
                recorder.observe(event)
            }
        )
    default: usage()
    }
} catch WebSocketListenerError.invalidArguments {
    usage()
} catch let error as HostError {
    switch error {
    case .unknownTarget(let id): fail("unknown target \(id); run `haild targets`", code: 2)
    case .adapterUnavailable(let kind, let reason): fail("\(kind) adapter unavailable: \(reason)", code: 4)
    case .refused(let reason): fail("refused: \(reason)", code: 3)
    case .denied(let denial): fail("denied: \(denial)", code: exitCode(for: denial))
    case .partial(let delivered, let reason):
        fail("delivered \(delivered.count) line\(delivered.count == 1 ? "" : "s"), then: \(reason)", code: 6)
    case .policyUnavailable(let reason): fail("policy unusable, delivery refused: \(reason)", code: 9)
    }
} catch let error as PolicyFileError {
    fail("policy: \(error)", code: 9)
} catch let error as PolicyFormatError {
    fail("policy: \(error)", code: 9)
} catch let error as AdapterError {
    fail("\(error)", code: 4)
} catch let error as RightyoTargetError {
    fail("RightyO target refused: \(error)", code: 64)
} catch let error as RightyoChildError {
    fail("ambient RightyO refused (\(error)): use an absolute executable and config path, owned by you or root"
         + " and not group- or world-writable, including every parent directory", code: 64)
} catch is RightyoInputError {
    fail("RightyO input refused; no automatic retry. Check session, lifecycle, limits and target policy.", code: 8)
} catch HostIdentityError.invalidOverride(let value) {
    fail("\(HostIdentity.environmentKey)=\(String(reflecting: value)) is not a host name:"
         + " use letters, digits, dots and hyphens", code: 64)
} catch let error as DiagnosticLogError {
    fail("device diagnostics refused: \(error); the log directory must be yours and closed to others")
} catch ReplyCommandError.usage {
    usage()
} catch {
    fail("\(error)")
}
