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
        // Keep constructor references (including unapplied values), the declaration and known path literals.
        let typed = #/
            (?: \bStopReason\s*\.\s*
              | \bcase\s+(?=legacy\s*\(\s*(?:AmbientListeningState\.)?LegacyStopPath\s*\))
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
        if code.contains(#/\.\s*legacy\s*\(/#) {
            sites.formUnion(LegacyStopContext(code).constructorSites)
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

// Inspect the context of a shorthand .legacy(...) without interpreting its payload.
private struct LegacyStopContext {
    private let tokens: [Substring]
    private let enclosing: [Int?]
    private let matchingDelimiter: [Int: Int]

    init(_ code: String) {
        let token = #/"(?:\\.|[^"\\\n])*"|\w+|->|\?\?|==|!=|\S/#
        tokens = code.matches(of: token).map(\.output)
        var scopes: [Int] = []
        var enclosing: [Int?] = []
        var matchingDelimiter: [Int: Int] = [:]
        for (index, word) in tokens.enumerated() {
            enclosing.append(scopes.last)
            switch word {
            case "(", "[", "{": scopes.append(index)
            case ")", "]", "}":
                if let opening = scopes.popLast() {
                    matchingDelimiter[opening] = index
                    matchingDelimiter[index] = opening
                }
            default: break
            }
        }
        self.enclosing = enclosing
        self.matchingDelimiter = matchingDelimiter
    }

    var constructorSites: Set<String.Index> {
        var sites: Set<String.Index> = []
        for index in tokens.indices where tokens[index] == "legacy" {
            guard index > 0, tokens[index - 1] == ".", value(at: index + 1) == "(",
                  let end = matchingDelimiter[index + 1] else { continue }
            if hasStopContext(start: index - 1, end: end) { sites.insert(tokens[index].startIndex) }
        }
        return sites
    }

    private func value(at index: Int) -> Substring? {
        tokens.indices.contains(index) ? tokens[index] : nil
    }

    // Only visit siblings. Commas in calls, closures or subscripts cannot start a new outer argument.
    private func prefix(before index: Int) -> String {
        let opening = enclosing[index] ?? -1
        var words: [Substring] = []
        var cursor = index - 1
        while cursor > opening {
            words.append(tokens[cursor])
            if let other = matchingDelimiter[cursor], other < cursor {
                cursor = other
                words.append(tokens[cursor])
            }
            cursor -= 1
        }
        return words.reversed().joined(separator: " ")
    }

    private func hasStopContext(start: Int, end: Int) -> Bool {
        let before = prefix(before: start)
        if isCast(after: end) { return true }

        let origin = expressionOrigin(in: before)
        if origin.contains(#/\b(?:let|var) \w+ : (?:AmbientListeningState \. )?StopReason =$/#) { return true }
        guard let opening = enclosing[start] else { return false }
        if tokens[opening] == "{" {
            let returnsValue = origin.isEmpty || origin.contains(#/\breturn$/#)
            return returnsValue && returnsStopReason(body: opening)
        }
        guard tokens[opening] == "(" else { return false }
        if isStopArgument(origin, opening: opening) { return true }
        // Parentheses used for grouping carry the surrounding expression's type through to their contents.
        guard origin.isEmpty, let closing = matchingDelimiter[opening],
              prefix(before: opening).contains(#/(?:^|[(:,?={]|\?\?|\breturn)\s*$/#) else { return false }
        return hasStopContext(start: opening, end: closing)
    }

    // For either branch of a ternary, or the fallback of ??, keep the introducer of the whole expression.
    private func expressionOrigin(in prefix: String) -> String {
        guard prefix.hasSuffix(" ?") || prefix.hasSuffix(" :") || prefix.hasSuffix(" ??") else { return prefix }
        let introducer = #/\breturn\b|(?:^|, )\w+ :| =(?= |$)/#
        guard let last = prefix.matches(of: introducer).last else { return "" }
        return String(prefix[..<last.range.upperBound])
    }

    private func isCast(after end: Int) -> Bool {
        guard value(at: end + 1) == "as" else { return false }
        if value(at: end + 2) == "StopReason" { return true }
        return value(at: end + 2) == "AmbientListeningState" && value(at: end + 3) == "."
            && value(at: end + 4) == "StopReason"
    }

    private func returnsStopReason(body: Int) -> Bool {
        let signature = prefix(before: body)
        if signature.contains(#/-> (?:AmbientListeningState \. )?StopReason(?: where [^{};]+)?$/#) { return true }
        guard signature.contains(#/\b(?:if|else|switch|guard|do|catch|while|for)\b[^{};]*$/#),
              let outer = enclosing[body], tokens[outer] == "{" else { return false }
        return returnsStopReason(body: outer)
    }

    private func isStopArgument(_ origin: String, opening: Int) -> Bool {
        let argument = origin.split(separator: ",", omittingEmptySubsequences: false).last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        switch value(at: opening - 1) {
        case "block", "veto", "end", "cancelTransportRestore", "forgetSelection",
             "attributeSelectionLoss", "SendFailureCause":
            return argument == "stop :"
        case "stopListening": return argument == "reason :"
        case "sendError": return argument == "destinationReason :"
        case "stop", "stopped":
            guard origin.isEmpty, value(at: opening - 2) == "." else { return false }
            let base = prefix(before: opening - 2)
            return base.contains(#/(?:^|[(:,?={]|\breturn|\bEvent|\bAmbientListeningState)\s*$/#)
        default: return false
        }
    }
}
