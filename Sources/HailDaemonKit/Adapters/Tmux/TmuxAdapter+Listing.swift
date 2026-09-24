import Foundation

/// The parsing, diffing, and polling behind `TmuxAdapter`, kept apart from the actor so each stays readable.
extension TmuxAdapter {

    struct Session: Equatable, Sendable {
        var id: String
        /// `#{session_created}`, epoch seconds; ids restart at `$0` when the server restarts.
        var created: String
        /// The active pane's id and pid at listing time (threat model B3).
        var paneID: String
        var panePID: String
        var name: String

        var binding: String { "\(id)@\(created)/\(paneID):\(panePID)" }
    }

    /// `-l` chunks by character so a chunk boundary never splits a grapheme cluster.
    static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[index..<end]))
            index = end
        }
        return out
    }

    /// Parses `list-sessions -F listFormat`. Blank or short lines are skipped; the name may contain pipes.
    static func parseSessions(_ stdout: String) -> [Session] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            return Session(id: parts[0], created: parts[1], paneID: parts[2], panePID: parts[3], name: parts[4])
        }
    }

    /// Vanish then appear events between two listings, keyed by binding so a session replaced under the
    /// same name is a vanish and an appear, never silence. Sorted by name for determinism.
    static func diff(old: [Session], new: [Session]) -> [TargetEvent] {
        let oldBindings = Set(old.map(\.binding))
        let newBindings = Set(new.map(\.binding))
        let vanished = old.filter { !newBindings.contains($0.binding) }.map(\.name).sorted()
            .map { TargetEvent.vanished(name: $0) }
        let appeared = new.filter { !oldBindings.contains($0.binding) }.sorted { $0.name < $1.name }
            .map { TargetEvent.appeared(AdapterTarget(name: $0.name, binding: $0.binding)) }
        return vanished + appeared
    }

    static func baseArguments(socket: String?) -> [String] {
        socket.map { ["-L", $0] } ?? []
    }

    /// No server is an empty list, not a failure: the daemon starts before any session exists. tmux 3.5
    /// says `error connecting to <socket> (No such file or directory)` when the socket was never created and
    /// `no server running on <socket>` when the file exists without a server.
    static func listSessions(
        runner: any CommandRunner, tmux: String, baseArguments: [String]
    ) async throws -> [Session] {
        let result = try await runner.run(tmux, baseArguments + ["list-sessions", "-F", listFormat])
        if result.exitCode != 0 {
            guard isNoServer(result.errorText) else { throw AdapterError.captureFailed(result.errorText) }
            return []
        }
        return parseSessions(result.stdout)
    }

    static func isNoServer(_ stderr: String) -> Bool {
        stderr.contains("no server running")
            || (stderr.contains("error connecting to") && stderr.contains("No such file or directory"))
    }

    static func pollingStream(
        runner: any CommandRunner, tmux: String, baseArguments: [String], interval: Duration?
    ) -> AsyncStream<TargetEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            guard let interval else {
                continuation.finish()
                return
            }
            let task = Task {
                var known: [Session] = []
                while !Task.isCancelled {
                    // A failing listing is retried next tick; the daemon's status reports it via the registry.
                    let listing = try? await listSessions(runner: runner, tmux: tmux, baseArguments: baseArguments)
                    if let current = listing {
                        for event in diff(old: known, new: current) { continuation.yield(event) }
                        known = current
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
