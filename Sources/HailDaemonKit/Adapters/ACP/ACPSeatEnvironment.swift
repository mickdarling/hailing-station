import Foundation

enum ACPSeatEnvironmentError: Error, Sendable, Equatable {
    case invalidEntry, invalidHome
}

/// Seat principle (#1074): the harness owns login and configuration. Diagnostics contain names only.
struct ACPSeatEnvironment: Sendable, Equatable {
    let environment: [String]
    let removedNames: [String]

    init(base: [String: String], pathOverride: String? = nil) throws {
        // Validate even entries that will be removed or replaced; invalid input never passes silently.
        for (key, value) in base {
            guard !key.isEmpty, !key.contains("="), Self.isValid(key), Self.isValid(value) else {
                throw ACPSeatEnvironmentError.invalidEntry
            }
        }
        guard let home = base["HOME"], home.hasPrefix("/") else { throw ACPSeatEnvironmentError.invalidHome }
        if let pathOverride, !Self.isValid(pathOverride) { throw ACPSeatEnvironmentError.invalidEntry }
        let credentials: Set<String> = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"
        ]
        removedNames = base.keys.filter { credentials.contains($0) }.sorted()
        var kept = base.filter { !credentials.contains($0.key) }
        if let pathOverride { kept["PATH"] = pathOverride }
        environment = kept.map { "\($0.key)=\($0.value)" }.sorted()
    }

    private static func isValid(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
