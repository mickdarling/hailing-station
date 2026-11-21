import Foundation

/// References retain the enclosing function and duplicates so an extra stop in the same function counts.
struct StopReferenceSource {
    private let code: String
    private let bare: Set<String>
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
        members = bare.union(["block", "veto", "legacy", "sendError", "bindingLoss"])
            .union(AmbientLegacyStopPathTests.paths.map { String(describing: $0) })
        let assignments = #/
            (?m) (?:\b(?:let|var)\s+|\b(?:\w+\??[ \t]*\.[ \t]*)*)
            (\w+)(?:[ \t]*:[^={};\n]+)?\s*=\s*
            (?:\w+\??\s*\.\s*)*\.?(\w+)(?:\((?:\w+:)+\))?[ \t]*(?=$|[;}])
            /#
        self.assignments = code.matches(of: assignments).map { (String($0.1), String($0.2)) }
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
                let name = String(word)
                if aliases.contains(name) || bare.contains(name) || (token.3 != nil && members.contains(name)) {
                    sites.append("\(scope) \(name)")
                }
            }
        }
        return sites
    }
}
