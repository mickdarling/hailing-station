#if os(macOS)
public import Foundation

/// The owner's spoken note to a named destination (#552, slice 1): "Jarvis, add to Notes: buy oat milk" runs the
/// Apple Shortcut the owner allowlisted for "notes", with the dictated words as its input. Only names in the owner's
/// destinations file are reachable; there is no "run any shortcut", since a Shortcut may order or send things.
/// Every destination here only saves: anything that sends waits for #89's confirmation.
public struct VoiceDestinations: Sendable, Equatable {
    public struct Destination: Sendable, Equatable {
        public let shortcut: String
        public init(shortcut: String) { self.shortcut = shortcut }
    }

    /// One recognised note: the destination's key, its Shortcut and the words to save, as heard.
    struct Command: Sendable, Equatable {
        let destination: String
        let shortcut: String
        let text: String
    }

    public enum LoadError: Error, Equatable { case malformed, invalidName, invalidShortcut }

    /// Longest note accepted, in characters; a longer turn is a request to the agent like any other.
    static let maxText = 2000
    /// Keyed spoken name (`RightyoAddressing.key`, so "Shopping list" is "shoppinglist") to its destination.
    let destinations: [String: Destination]

    public init(_ destinations: [String: Destination]) throws {
        var keyed: [String: Destination] = [:]
        for (name, destination) in destinations {
            let key = RightyoAddressing.key(name)
            guard !key.isEmpty, name.split(separator: " ").count <= 3 else { throw LoadError.invalidName }
            let shortcut = destination.shortcut
            // From the owner's own file, but still argv: never empty, an option, overlong or carrying controls.
            guard !shortcut.isEmpty, shortcut.count <= 100, !shortcut.hasPrefix("-"),
                  !shortcut.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw LoadError.invalidShortcut
            }
            keyed[key] = destination
        }
        self.destinations = keyed
    }

    /// `{"notes": {"shortcut": "Hail to Notes"}}`; nil when the file does not exist (the feature is then off).
    public static func load(_ url: URL) throws -> VoiceDestinations? {
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) { throw LoadError.malformed }
            return nil
        }
        guard let raw = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            throw LoadError.malformed
        }
        var parsed: [String: Destination] = [:]
        for (name, fields) in raw {
            guard Set(fields.keys) == ["shortcut"], let shortcut = fields["shortcut"] else { throw LoadError.malformed }
            parsed[name] = Destination(shortcut: shortcut)
        }
        return try VoiceDestinations(parsed)
    }

    /// The note a whole turn dictates, given the session's keyed addressing `names`; nil for anything else. After
    /// an optional greeting and name: "add to <dest>" or "put (this|that)? in|into <dest>", then the words, kept as
    /// said (case and punctuation), with any leading ":", "," or "-" taken off.
    func command(in heard: String, names: Set<String>) -> Command? {
        let words = Self.words(heard)
        var index = 0
        if index < words.count, VoiceMute.greetings.contains(words[index].text) { index += 1 }
        if let width = (1...3).first(where: { width in
            index + width < words.count && names.contains(words[index..<index + width].map(\.key).joined())
        }) { index += width }
        guard let rest = Self.lead(words, from: index) else { return nil }
        for width in 1...3 where rest + width < words.count {
            let key = words[rest..<rest + width].map(\.key).joined()
            guard let destination = destinations[key] else { continue }
            let text = heard[words[rest + width - 1].range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: ":,-").union(.whitespacesAndNewlines))
            guard !text.isEmpty, text.count <= Self.maxText else { return nil }
            return Command(destination: key, shortcut: destination.shortcut, text: text)
        }
        return nil
    }

    /// The index just past "add to" or "put [this|that] in|into"; nil when the turn does not start so.
    private static func lead(_ words: [Word], from start: Int) -> Int? {
        func word(_ offset: Int) -> String? { start + offset < words.count ? words[start + offset].text : nil }
        if word(0) == "add", word(1) == "to" { return start + 2 }
        guard word(0) == "put" else { return nil }
        let skip = ["this", "that"].contains(word(1)) ? 2 : 1
        return ["in", "into"].contains(word(skip)) ? start + skip + 1 : nil
    }

    struct Word {
        let text: String
        let key: String
        let range: Range<String.Index>
    }

    /// Runs of letters, digits and apostrophes, lowercased and keyed, with where each sits in `heard`.
    private static func words(_ heard: String) -> [Word] {
        var found: [Word] = []
        var start: String.Index?
        for index in heard.indices + [heard.endIndex] {
            let character = index < heard.endIndex ? heard[index] : " "
            let inWord = character.isLetter || character.isNumber || character == "'"
            if inWord, start == nil { start = index }
            if !inWord, let begin = start {
                let text = heard[begin..<index].lowercased()
                found.append(Word(text: text, key: RightyoAddressing.key(text), range: begin..<index))
                start = nil
            }
        }
        return found
    }
}

/// Runs one allowlisted Shortcut with a note as its input (#552): `shortcuts run <name> --input-path <file>`, no
/// shell, the words only in a private temporary file that is removed afterwards. Returns an outcome token for logs.
struct ShortcutRunner: Sendable {
    var executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    var timeout: Duration = .seconds(30)

    func run(_ shortcut: String, text: String) async -> String {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("hail-note-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: input.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return "input_failed" }
        defer { try? FileManager.default.removeItem(at: input) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", shortcut, "--input-path", input.path]
        (process.standardInput, process.standardOutput, process.standardError) = (nil, nil, nil)
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus) }
        do { try process.run() } catch { return "launch_failed" }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
        defer { timer.cancel() }
        var statuses = exited.stream.makeAsyncIterator()
        let status = await statuses.next() ?? -1
        if process.terminationReason == .uncaughtSignal { return "timeout" }
        return status == 0 ? "saved" : "exit_\(status)"
    }
}
#endif
