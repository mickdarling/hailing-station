public import Foundation

/// One block of a reply's Markdown metadata (#606), ready to render. Every inline run is already made safe by
/// `MessageMarkdown.inline`: only checked web links, no images loaded, raw HTML shown as the text it is.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// `depth` 0 is a top-level item; `marker` is "•" or the item's number with its "." or ")".
    case listItem(depth: Int, marker: String, text: AttributedString)
    case quote(AttributedString)
    /// Shown exactly as written, in monospace; `language` is the fence's info word, if any.
    case code(language: String?, text: String)
    case table(MarkdownTable)
    case rule
}

/// A pipe table. Rows are padded or cut to the header's width, so every row has one cell per column.
public struct MarkdownTable: Equatable, Sendable {
    public var header: [AttributedString]
    public var rows: [[AttributedString]]
    /// Columns or rows past the caps were left out; the client's raw text still has them.
    public var truncated = false

    /// The narrow-screen fallback: each row as "column: value" pairs, skipping empty cells.
    public var records: [[(name: AttributedString, value: AttributedString)]] {
        rows.map { row in
            zip(header, row).compactMap { name, value in value.characters.isEmpty ? nil : (name, value) }
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.header == rhs.header && lhs.rows == rhs.rows && lhs.truncated == rhs.truncated
    }
}

/// A shared, platform-neutral Markdown model for a reply's metadata (#606): a small line-based block parser
/// (headings, paragraphs, lists, quotes, fenced code, pipe tables, rules) over Foundation's inline Markdown. It never
/// recurses, so input depth cannot exhaust the stack, and it is bounded in blocks, columns and rows. Anything it does
/// not recognise is a paragraph of the text as written, so nothing is hidden; a client keeps the raw source as well.
public enum MessageMarkdown {
    public static let maxBlocks = 400
    public static let maxColumns = 12
    public static let maxRows = 200
    static let maxListDepth = 4

    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var parser = MarkdownBlockParser(lines: source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return parser.parse()
    }

    /// Plain text for an accessibility summary or a copy: the source's words without Markdown syntax.
    public static func plainText(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text): String(text.characters)
            case .listItem(_, let marker, let text): "\(marker) \(String(text.characters))"
            case .code(_, let text): text
            case .table(let table):
                ([table.header] + table.rows).map { $0.map { String($0.characters) }.joined(separator: ", ") }
                    .joined(separator: "\n")
            case .rule: ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct MarkdownBlockParser {
    let lines: [String]
    var index = 0
    var blocks: [MarkdownBlock] = []
    /// Each block's first line, so blocks past the cap go back to the text they came from.
    var starts: [Int] = []
    var paragraph: [String] = []
    var paragraphStart = 0

    init(lines: [String]) { self.lines = lines }

    mutating func parse() -> [MarkdownBlock] {
        while index < lines.count, blocks.count < MessageMarkdown.maxBlocks {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let fence = Self.fence(trimmed) {
                flushParagraph()
                code(fence)
            } else if let heading = Self.heading(trimmed) {
                flushParagraph()
                add(.heading(level: heading.level, text: MessageMarkdown.inline(heading.text)), from: index)
                index += 1
            } else if Self.isRule(trimmed) {
                flushParagraph()
                add(.rule, from: index)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                quote()
            } else if let item = Self.listItem(line) {
                flushParagraph()
                list(item)
            } else if trimmed.contains("|"), index + 1 < lines.count, Self.isDelimiterRow(lines[index + 1]) {
                flushParagraph()
                table()
            } else {
                if paragraph.isEmpty { paragraphStart = index }
                paragraph.append(trimmed)
                index += 1
            }
        }
        flushParagraph()
        return finish()
    }

    private mutating func finish() -> [MarkdownBlock] {
        // Past the block cap the rest stays readable as plain text rather than disappearing, from the first line of
        // the first block over it. A step may finish a block or two over the cap; they rejoin the text here.
        var rest = index
        if blocks.count > MessageMarkdown.maxBlocks {
            rest = starts[MessageMarkdown.maxBlocks]
            blocks.removeLast(blocks.count - MessageMarkdown.maxBlocks)
        }
        let leftover = lines[min(rest, lines.count)...].joined(separator: "\n")
        if !leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.paragraph(AttributedString(leftover)))
        }
        return blocks
    }

    mutating func add(_ block: MarkdownBlock, from line: Int) {
        blocks.append(block)
        starts.append(line)
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        add(.paragraph(MessageMarkdown.inline(paragraph.joined(separator: "\n"))), from: paragraphStart)
        paragraph = []
    }

    // MARK: Fenced code

    private static func fence(_ trimmed: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let run = String(trimmed.prefix { $0 == marker.first })
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            guard !(marker == "```" && info.contains("`")) else { return nil }
            let language = info.split(separator: " ").first.map(String.init)
            return (run, language.map { String($0.prefix(32)) })
        }
        return nil
    }

    private mutating func code(_ fence: (marker: String, language: String?)) {
        let start = index
        index += 1
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.hasPrefix(fence.marker), trimmed.allSatisfy({ $0 == fence.marker.first }) { break }
            body.append(lines[index - 1])
        }
        add(.code(language: fence.language, text: body.joined(separator: "\n")), from: start)
    }

    // MARK: Headings, rules, quotes

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is decoration: "## Title ##".
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(closing) }
        return (hashes, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private mutating func quote() {
        let start = index
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            body.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            index += 1
        }
        add(.quote(MessageMarkdown.inline(body.joined(separator: "\n"))), from: start)
    }
}
