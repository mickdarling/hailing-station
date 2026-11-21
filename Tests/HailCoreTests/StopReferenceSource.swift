import Foundation

/// References retain the enclosing function and duplicates so an extra stop in the same function counts.
struct StopReferenceSource {
    private let code: String
    private let bare: Set<String>
    private let legacyConstructors: Set<String.Index>
    let members: Set<String>
    let assignments: [(name: String, value: String)]

    init(_ source: String) {
        let commentsOrStrings = #/"(?:\\.|[^"\\\n])*"|\/\/[^\n]*|\/\*(?s:.*?)\*\//#
        code = source.replacing(commentsOrStrings) { $0.output.hasPrefix("/") ? " " : String($0.output) }
        var bare: Set<String> = ["turnOff", "destinationLost", "ownerChangedDestination", "cancelTransportRestore",
                                 "bindingLossReason", "destinationLossReason", "targetLoss", "attributeSelectionLoss",
                                 "recordSendFailure", "cancelForDiagnosticsDismissal"]
        if code.contains(#/(?:class|extension)\s+AmbientListeningReconnect\b/#) { bare.formUnion(["block", "veto"]) }
        if code.contains(#/(?:class|extension)\s+AmbientListeningController\b/#) {
            bare.formUnion(["end", "observeSystemEnd", "updateDestination", "stopListening"])
        }
        if code.contains(#/(?:enum|extension)\s+(?:AmbientListeningState\.)?StopReason\b/#) {
            bare.formUnion(["legacy", "sendError", "bindingLoss"])
        }
        self.bare = bare
        let paths = Set(AmbientLegacyStopPathTests.paths.map { String(describing: $0) })
        members = bare.union(["block", "veto", "legacy", "sendError", "bindingLoss"]).union(paths)
        let legacyConstructors = Self.legacyConstructorSites(in: code, paths: paths)
        self.legacyConstructors = legacyConstructors
        let assignments = #/
            (?m) (?: \b(?:let|var)[ \t]+(\w+)(?:[ \t]*:[^={};\n]+)?
                   | (?:^|[;{])[ \t]*(?:\w+\??[ \t]*\.[ \t]*)*(\w+) ) \s*=\s*
            (?:\w+\??\s*\.\s*)*\.?(\w+)(?:\((?:\w+:)+\))?[ \t]*(?=$|[;}])
            /#
        self.assignments = code.matches(of: assignments).compactMap { match in
            guard let name = match.1 ?? match.2,
                  match.3 != "legacy" || legacyConstructors.contains(match.3.startIndex) else { return nil }
            return (String(name), String(match.3))
        }
    }

    private static func legacyConstructorSites(in code: String, paths: Set<String>) -> Set<String.Index> {
        guard code.contains("legacy") else { return [] }
        // A constructor value carries its type. A shorthand call carries a path case or a stop API's argument type.
        let typed = #/
            (?: \bStopReason\s*\.\s*
              | \bcase\s+(?=legacy\s*\(\s*(?:AmbientListeningState\.)?LegacyStopPath\s*\))
              | \b(?:cancelTransportRestore|block)\s*\([^(){}]*?\bstop\s*:\s*\.\s*(?=legacy\s*\()
            )(legacy)\b
            /#
        var sites = Set(code.matches(of: typed).map { $0.1.startIndex })
        let shorthand = #/
            (?m) (?:^|[(:,?=]|\breturn)\s*\.\s*(legacy)\s*\(\s*
            (?:(?:AmbientListeningState\.)?LegacyStopPath)?\.\s*(\w+)\s*\)
            /#
        for call in code.matches(of: shorthand) where paths.contains(String(call.2)) {
            sites.insert(call.1.startIndex)
        }
        return sites
    }

    func references(aliases: Set<String>) -> [String] {
        guard members.union(aliases).contains(where: { code.contains($0) }) else { return [] }
        let tokens = #/\bfunc\s+(\w+)|\bvar\s+(bindingLossReason|body)\b|(\.\s*)?\b(\w+)\b/#
        var scope = "<file>"
        var sites: [String] = []
        for token in code.matches(of: tokens) {
            if let declaration = token.1 ?? token.2 {
                scope = String(declaration)
            } else if let word = token.4 {
                if word == "legacy" && !legacyConstructors.contains(word.startIndex) { continue }
                let name = String(word)
                if aliases.contains(name) || bare.contains(name) || (token.3 != nil && members.contains(name)) {
                    sites.append("\(scope) \(name)")
                }
            }
        }
        return sites
    }
}
