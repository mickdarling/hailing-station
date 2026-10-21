#if os(macOS)
public import Foundation

/// The owner's spoken note to a named destination (#552): "Jarvis, add to Notes: buy oat milk" saves the dictated
/// words wherever the owner configured "notes", by one of haild's own handlers (`VoiceNoteRunner`). Only names in the
/// owner's destinations file are reachable, and a handler is code in this repo, never one named at run time.
/// Every destination here only saves: anything that sends waits for #89's confirmation.
public struct VoiceDestinations: Sendable, Equatable {
    /// Where a destination's notes go: the handler's kind, as the file's single key, and its target.
    public enum Destination: Sendable, Equatable {
        /// Appended as a dated list item to this Markdown file (an absolute path ending `.md`).
        case markdown(String)
        /// Given as the input of this allowlisted Apple Shortcut, by name.
        case shortcut(String)
    }

    /// One recognised note: the destination's key, where it goes and the words to save, as heard.
    struct Command: Sendable, Equatable {
        let destination: String
        let target: Destination
        let text: String
    }

    public enum LoadError: Error, Equatable { case malformed, invalidName, invalidShortcut, invalidFile, unsafe }

    /// Longest note accepted, in characters; a longer turn is a request to the agent like any other.
    static let maxText = 2000
    /// Keyed spoken name (`RightyoAddressing.key`, so "Shopping list" is "shoppinglist") to its destination.
    let destinations: [String: Destination]

    public init(_ destinations: [String: Destination]) throws {
        var keyed: [String: Destination] = [:]
        for (name, destination) in destinations {
            let key = RightyoAddressing.key(name)
            guard !key.isEmpty, name.split(separator: " ").count <= 3, keyed[key] == nil else {
                throw LoadError.invalidName
            }
            try Self.validate(destination)
            keyed[key] = destination
        }
        self.destinations = keyed
    }

    /// From the owner's own file, but still argv or a path: never empty, overlong or carrying controls; a Shortcut
    /// never an option; a file absolute, without `.`, `..` or empty components, and Markdown.
    private static func validate(_ destination: Destination) throws {
        let controls = { (value: String) in
            value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        switch destination {
        case .shortcut(let name):
            guard !name.isEmpty, name.count <= 100, !name.hasPrefix("-"), !controls(name) else {
                throw LoadError.invalidShortcut
            }
        case .markdown(let path):
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            guard path.hasPrefix("/"), path.count <= 1024, path.hasSuffix(".md"), !controls(path),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw LoadError.invalidFile
            }
        }
    }

    /// `{"notes": {"markdown": "/Users/me/Notes/Inbox.md"}}` or `{"notes": {"shortcut": "Hail to Notes"}}`, exactly
    /// one handler per destination; nil when the file does not exist (the feature is then off).
    /// The file alone decides where a spoken name's words go, so it is trusted only as the RightyO executable is
    /// (`RightyoChildProcess.validate`): after symlinks, a regular file of at most 64 KB owned by this user or root and
    /// not group/world-writable, in directories up to `/` that no other user can write either. Otherwise `unsafe`.
    public static func load(_ url: URL) throws -> VoiceDestinations? {
        var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/") else { throw LoadError.unsafe }
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw LoadError.unsafe
        }
        guard let path = trustedPath(url.path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw LoadError.unsafe }
        guard let raw = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            throw LoadError.malformed
        }
        var parsed: [String: Destination] = [:]
        for (name, fields) in raw {
            switch (fields.count, fields["markdown"], fields["shortcut"]) {
            case (1, let path?, nil): parsed[name] = .markdown(path)
            case (1, nil, let shortcut?): parsed[name] = .shortcut(shortcut)
            default: throw LoadError.malformed
            }
        }
        return try VoiceDestinations(parsed)
    }

    /// The resolved path when it and every directory above it pass `load`'s trust rule (also `VoiceRoutes.load`'s);
    /// nil otherwise.
    static func trustedPath(_ given: String) -> String? {
        guard let resolved = realpath(given, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved), owners: Set<uid_t> = [0, getuid()]
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 * 1024 else { return nil }
        var item = path
        while true {
            guard stat(item, &info) == 0, owners.contains(info.st_uid), info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                return nil
            }
            if item == "/" { return path }
            item = (item as NSString).deletingLastPathComponent
        }
    }

    /// The note a whole turn dictates, given the session's keyed addressing `names`; nil for anything else. After
    /// an optional greeting and name: "add to <dest>" or "put (this|that)? in|into <dest>", then the words, kept as
    /// said (case and punctuation), with any leading ":", "," or "-" taken off. The destination must end at a space,
    /// one of those marks or the end, so "add to notes.md ..." stays a request to the agent. Longest name first.
    func command(in heard: String, names: Set<String>) -> Command? {
        let words = Self.words(heard)
        var index = 0
        if index < words.count, VoiceMute.greetings.contains(words[index].text) { index += 1 }
        if let width = (1...3).first(where: { width in
            index + width < words.count && names.contains(words[index..<index + width].map(\.key).joined())
        }) { index += width }
        guard let rest = Self.lead(words, from: index) else { return nil }
        for width in stride(from: 3, through: 1, by: -1) where rest + width < words.count {
            let key = words[rest..<rest + width].map(\.key).joined()
            guard let destination = destinations[key] else { continue }
            let end = words[rest + width - 1].range.upperBound
            guard end == heard.endIndex || heard[end].isWhitespace || ":,-".contains(heard[end]) else { return nil }
            let text = heard[end...].drop { $0.isWhitespace || ":,-".contains($0) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= Self.maxText else { return nil }
            return Command(destination: key, target: destination, text: text)
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
    static func words(_ heard: String) -> [Word] {
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
#endif
