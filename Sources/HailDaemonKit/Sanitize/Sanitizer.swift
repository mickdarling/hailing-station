import Foundation

/// How much a delivery may carry and what a line break means (#44 item 2, #41 tiers).
public struct SanitizePolicy: Sendable, Equatable {
    public enum Newlines: Sendable, Equatable {
        /// One utterance is one command: a line break before the end is refused (the default everywhere).
        case reject
        /// Each line becomes its own delivery; only for targets whose policy allows multi-line (#41).
        case split
    }

    public var maxCharacters: Int
    /// The text frame cap (#44 item 3, `PayloadLimits`): combining marks cannot inflate 2,000 characters.
    public var maxUTF8Bytes: Int
    public var newlines: Newlines
    /// Under `.split`, the most lines one delivery may become; each line is a separate Enter.
    public var maxLines: Int

    public init(
        maxCharacters: Int = 2_000, maxUTF8Bytes: Int = 8_192, newlines: Newlines = .reject, maxLines: Int = 20
    ) {
        self.maxCharacters = maxCharacters
        self.maxUTF8Bytes = maxUTF8Bytes
        self.newlines = newlines
        self.maxLines = maxLines
    }
}

/// Why text was refused. Every case is spoken back to the user by policy (#41), so the wording is plain.
public enum SanitizeError: Error, Equatable, Sendable {
    case empty
    case tooLong(characters: Int, limit: Int)
    case tooManyBytes(bytes: Int, limit: Int)
    case tooManyLines(lines: Int, limit: Int)
    case containsLineBreak
    /// Bidirectional controls, zero-width, or other invisible characters: they hide or reorder what is
    /// delivered while reading back as something else.
    case hiddenCharacters(String)
}

/// Turns text into the exact lines a target may receive (#44 item 2, threat model B3 tampering rows).
///
/// Order matters: the caps run first on the raw text so a megabyte cannot cost a normalisation pass; NFC
/// next so later checks see one canonical form (the byte cap is re-checked after it); hidden characters
/// are refused rather than stripped, because stripping them would silently change what the user meant;
/// then escape sequences and every C0/C1 control except line breaks are removed (tab included: at an
/// interactive target it is the completion key, and a spoken utterance never contains one); every
/// space-separator lookalike (no-break space, en space, ideographic space, ...) becomes a plain space so
/// read-back, guards, and the pane tokenise alike; then line breaks are applied by policy. Trailing
/// whitespace is dropped: the adapter adds the one Enter.
///
/// Contract for callers: NFC maps lookalikes onto ASCII (U+037E to `;`, U+1FEF to a backtick, U+212A to
/// `K`), so the dangerous-pattern guard (#41) and any host-side read-back must run on the returned lines,
/// never on the frame text.
public enum Sanitizer {
    public static func sanitize(_ text: String, policy: SanitizePolicy = SanitizePolicy()) throws -> [String] {
        let bytes = text.utf8.count
        guard bytes <= policy.maxUTF8Bytes else {
            throw SanitizeError.tooManyBytes(bytes: bytes, limit: policy.maxUTF8Bytes)
        }
        let count = text.count
        guard count <= policy.maxCharacters else {
            throw SanitizeError.tooLong(characters: count, limit: policy.maxCharacters)
        }
        let normalized = text.precomposedStringWithCanonicalMapping
        guard normalized.utf8.count <= policy.maxUTF8Bytes else {
            throw SanitizeError.tooManyBytes(bytes: normalized.utf8.count, limit: policy.maxUTF8Bytes)
        }
        if let hidden = firstHiddenCharacterClass(in: normalized) { throw SanitizeError.hiddenCharacters(hidden) }
        var stripped = foldSpaces(stripControls(stripEscapeSequences(normalized)))
        while let last = stripped.last, last.isWhitespace { stripped.removeLast() }
        let lines = stripped.split(omittingEmptySubsequences: true) { $0.isNewline }
            .map(String.init)
            .filter { $0.contains { !$0.isWhitespace } }
        guard !lines.isEmpty else { throw SanitizeError.empty }
        if policy.newlines == .reject, stripped.contains(where: \.isNewline) { throw SanitizeError.containsLineBreak }
        guard lines.count <= policy.maxLines else {
            throw SanitizeError.tooManyLines(lines: lines.count, limit: policy.maxLines)
        }
        return lines
    }

    // MARK: - Pieces

    /// This is input sanitization: the sequences are removed so the pane never receives them. CSI (`ESC [`
    /// or C1 U+009B: parameters and intermediates, one final byte); the string sequences OSC, DCS, SOS, PM,
    /// APC (`ESC ]`, `ESC P`, `ESC X`, `ESC ^`, `ESC _` or their C1 forms: up to BEL or ST, payload
    /// included); `ESC` plus intermediates plus a final; and a bare trailing ESC. A control character that
    /// cuts a sequence short is kept, as a terminal would execute it, so a line break cannot hide inside.
    static func stripEscapeSequences(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            let next = index + 1 < scalars.count ? scalars[index + 1].value : nil
            switch value {
            case 0x1B where next == 0x5B:
                index = endOfCSI(scalars, from: index + 2)
            case 0x1B where next.map(stringIntroducers.contains) == true:
                index = endOfString(scalars, from: index + 2)
            case 0x1B:
                index = endOfEscape(scalars, from: index + 1)
            case 0x9B:
                index = endOfCSI(scalars, from: index + 1)
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                index = endOfString(scalars, from: index + 1)
            default:
                out.append(scalars[index])
                index += 1
            }
        }
        return String(out)
    }

    /// The 7-bit second bytes of DCS (`P`), SOS (`X`), OSC (`]`), PM (`^`), and APC (`_`).
    private static let stringIntroducers: Set<UInt32> = [0x50, 0x58, 0x5D, 0x5E, 0x5F]

    /// C0 (U+0000...U+001F) except line breaks, DEL, and C1 (U+0080...U+009F). Tab goes too: delivered
    /// with `send-keys` it is the completion keystroke, not text.
    static func stripControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x0A, 0x0D: return true
            case 0x00...0x1F, 0x7F, 0x80...0x9F: return false
            default: return true
            }
        }))
    }

    /// Every Zs space separator becomes U+0020. Line breaks and tabs are handled elsewhere; the Zl and Zp
    /// separators are line breaks to `Character.isNewline` and stay for the policy step.
    static func foldSpaces(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .spaceSeparator ? " " : scalar
        }))
    }

    /// Index just past the final byte (0x40...0x7E) of a CSI, or at the first scalar that is neither a
    /// parameter (0x30...0x3F) nor an intermediate (0x20...0x2F), which is then kept.
    private static func endOfCSI(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if (0x40...0x7E).contains(value) { return index + 1 }
            if !(0x20...0x3F).contains(value) { return index }
            index += 1
        }
        return index
    }

    /// Index just past BEL, U+009C, or `ESC \`; an unterminated string swallows to the end, as a terminal
    /// would, except that a line break ends it so it cannot hide one.
    private static func endOfString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x07 || value == 0x9C { return index + 1 }
            if value == 0x1B, index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
            if value == 0x0A || value == 0x0D { return index }
            index += 1
        }
        return index
    }

    /// `ESC` then zero or more intermediates (0x20...0x2F) then one final (0x30...0x7E); anything else
    /// ends the escape and is kept.
    private static func endOfEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
        if index < scalars.count, (0x30...0x7E).contains(scalars[index].value) { return index + 1 }
        return index
    }
}
