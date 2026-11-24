import Foundation

/// Counts legacy spellings throughout production code and stop names in controller files.
struct StopReferenceSource {
    private static let entryPoints: Set<String> = [
        "attachStationRoot", "attributeSelectionLoss", "beginEnding", "bindingLoss", "block",
        "cancelForDiagnosticsDismissal", "cancelTransportRestore", "destinationLossReason", "destinationLost",
        "disposeStationScene", "end", "endBySystem", "forgetSelection", "legacy",
        "observeSystemEnd", "ownerChangedDestination", "receiveAmbientRefusal", "recordSendFailure", "retire",
        "retirePendingOwnerStart", "sendError", "sendFailed", "stationWindowDisposed", "stopCaptureForDrain",
        "stopForPolicy", "stopForSceneDisposal", "stopListening", "targetLoss", "turnOff", "updateDestination", "veto"
    ]
    private static let names = entryPoints.union(["bindingLossReason"])
        .union(AmbientLegacyStopPathTests.paths.map { String(describing: $0) })

    private static let controllerNames: Set<Substring> = [
        "AmbientListeningController", "ambientController", "attachStationRoot", "disposeStationScene",
        "stationWindowDisposed", "stopCaptureForDrain"
    ]
    // A caller can inherit its receiver from another file (e.g. a StationCard extension).
    private static let qualifiedStops: [Substring: Set<Substring>] = [
        "controller": ["turnOff", "destinationLost", "ownerChangedDestination", "cancelForDiagnosticsDismissal",
                       "receiveAmbientRefusal", "cancelTransportRestore", "stopForSceneDisposal"],
        "reconnect": ["block", "veto", "sendFailed"]
    ]

    var includesEntryPoints = false
    var legacyCounts: [String: Int] = [:]
    var controllerCounts: [String: Int] = [:]
    var unappliedLines: [String: Int] = [:]

    init(_ source: String, definesStopPaths: Bool = false) throws {
        guard definesStopPaths || source.contains("legacy") || source.contains("LegacyStopPath")
                || Self.controllerNames.contains(where: { source.contains($0) })
                || Self.qualifiedStops.keys.contains(where: { source.contains($0) }) else { return }
        var lexer = StopReferenceLexer(source)
        let tokens = try lexer.tokens()
        includesEntryPoints = definesStopPaths || Self.referencesController(tokens)
        for (index, word) in tokens.enumerated() {
            if word == "LegacyStopPath" {
                legacyCounts["LegacyStopPath", default: 0] += 1
            } else if word == "legacy" {
                let previous = tokens[..<index].last
                let hasParen = tokens.dropFirst(index + 1).first == "("
                if previous == "." {
                    legacyCounts[".legacy", default: 0] += 1
                    if hasParen { legacyCounts[".legacy(", default: 0] += 1 }
                } else if hasParen, previous != "func" {
                    legacyCounts["legacy(", default: 0] += 1
                }
            }
        }
        if includesEntryPoints { countEntryPoints(tokens, in: source) }
    }

    private static func referencesController(_ tokens: [Substring]) -> Bool {
        if !controllerNames.isDisjoint(with: tokens) { return true }
        for (index, receiver) in tokens.enumerated() {
            guard let members = qualifiedStops[receiver] else { continue }
            var following = tokens.dropFirst(index + 1)
            if following.first == "?" || following.first == "!" { following = following.dropFirst() }
            if following.first == ".", let name = following.dropFirst().first, members.contains(name) { return true }
        }
        return false
    }

    private mutating func countEntryPoints(_ tokens: [Substring], in source: String) {
        for (index, word) in tokens.enumerated() where Self.names.contains(String(word)) {
            let name = String(word)
            controllerCounts[name, default: 0] += 1
            let previous = index > 0 ? tokens[index - 1] : ""
            let next = tokens.dropFirst(index + 1)
            if Self.entryPoints.contains(name), previous != "func", !Self.isApplied(next) {
                let line = Self.lineTokens(at: index, tokens: tokens, source: source)
                unappliedLines[line, default: 0] += 1
            }
        }
    }

    private static func lineTokens(at index: Int, tokens: [Substring], source: String) -> String {
        let word = tokens[index]
        let start = source[..<word.startIndex].lastIndex(where: \.isNewline) ?? source.startIndex
        let end = source[word.endIndex...].firstIndex(where: \.isNewline) ?? source.endIndex
        let before = tokens[..<index].reversed().prefix { $0.startIndex >= start }
        let after = tokens[index...].prefix { $0.startIndex < end }
        return (Array(before.reversed()) + after).joined(separator: " ")
    }

    private static func isApplied(_ following: ArraySlice<Substring>) -> Bool {
        if following.first == "{" { return true }
        guard following.first == "(" else { return false }
        // block(_:stop:) names a function value. A call has an expression after each label.
        var arguments = following.dropFirst()
        while arguments.count >= 2, arguments.dropFirst().first == ":" {
            arguments = arguments.dropFirst(2)
            if arguments.first == ")" { return false }
        }
        return true
    }
}
