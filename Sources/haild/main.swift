import Foundation
import HailDaemonKit

// haild: the host daemon's command line (#10 item 1, #41). `run` starts with the read-only connection
// probe (#98); the push endpoint, LaunchAgent, and `pair` arrive with their slices. Exit codes: 2 unknown
// target, 3 refused by the sanitizer, 4 adapter
// unavailable or adapter error, 5 unbound, 6 partial, 7 denied by policy, 8 confirmation needed or
// cancelled, 9 policy file unusable, 64 usage.

let tmuxPath = ProcessInfo.processInfo.environment["HAIL_TMUX"] ?? "tmux"
let standardError = FileHandle.standardError

func makeHost() async throws -> HailHost {
    let registry = Registry()
    try await registry.register(TmuxAdapter(runner: ProcessCommandRunner(), tmux: tmuxPath))
    return try HailHost(registry: registry, store: PolicyFile.standard())
}

func usage() -> Never {
    standardError.write(Data("""
    usage: haild targets
           haild targets allow <target-id> [--tier open|confirm|locked] [--capture]
           haild targets deny <target-id>
           haild targets tier <target-id> <open|confirm|locked>
           haild send <target-id> <text>      (text is one argument; quote it)
           haild status
           haild audit verify|tail|today
           haild run --bind <address> --port <port> --connection-probe

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
    case "status": try await status(try await makeHost())
    case "audit": try audit(arguments.dropFirst())
    case "run":
        try await ConnectionProbeDaemon.run(
            host: try await makeHost(), arguments: Array(arguments.dropFirst()),
            hostName: ProcessInfo.processInfo.hostName, log: logNetworkEvent
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
} catch {
    fail("\(error)")
}
