import Foundation

/// Lists and pipe tables: the block kinds that gather several lines of their own (#606).
extension MarkdownBlockParser {
    // MARK: Lists

    struct Item {
        /// The item's first line, so a list cut by the block cap resumes there as readable text.
        var line = 0
        var indent: Int
        var marker: String
        var text: String
    }

    static func listItem(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        if let bullet = body.first, "-*+".contains(bullet), body.dropFirst().first == " " {
            return Item(indent: indent, marker: "•", text: body.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let delimiter = body.dropFirst(digits.count).first,
              delimiter == "." || delimiter == ")", body.dropFirst(digits.count + 1).first == " " else { return nil }
        return Item(
            indent: indent, marker: "\(digits)\(delimiter)",
            text: body.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        )
    }

    mutating func list(_ first: Item) {
        var items = [first]
        items[0].line = index
        index += 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var item = Self.listItem(line) {
                item.line = index
                items.append(item)
            } else if !trimmed.isEmpty, line.first == " " || line.first == "\t" {
                items[items.count - 1].text += "\n" + trimmed // An indented continuation of the item above.
            } else {
                break
            }
            index += 1
        }
        // Depth from indentation relative to the list's own indents, so 2-space and 4-space styles both nest.
        var indents: [Int] = []
        for item in items {
            while let last = indents.last, item.indent < last { indents.removeLast() }
            if indents.last.map({ item.indent > $0 }) ?? true { indents.append(item.indent) }
            let depth = min(indents.count - 1, MessageMarkdown.maxListDepth)
            guard blocks.count < MessageMarkdown.maxBlocks else {
                index = item.line // The rest of the list, from this item on, is kept as plain text by `parse`.
                return
            }
            blocks.append(.listItem(depth: depth, marker: item.marker, text: MessageMarkdown.inline(item.text)))
        }
    }

    // MARK: Tables

    static func isDelimiterRow(_ line: String) -> Bool {
        let cells = cells(line)
        guard !cells.isEmpty, line.contains("-") else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    /// Splits a row on unescaped pipes, ignoring one leading and one trailing pipe; `\|` is a literal pipe.
    static func cells(_ line: String) -> [String] {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed = trimmed.dropLast() }
        var cells: [String] = [], current = "", escaped = false
        for character in trimmed {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    mutating func table() {
        let allHeader = Self.cells(lines[index])
        let header = Array(allHeader.prefix(MessageMarkdown.maxColumns))
        var truncated = allHeader.count > header.count
        index += 2
        var rows: [[AttributedString]] = []
        while index < lines.count {
            let line = lines[index]
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            if rows.count < MessageMarkdown.maxRows {
                var cells = Array(Self.cells(line).prefix(header.count))
                cells += Array(repeating: "", count: header.count - cells.count)
                rows.append(cells.map(MessageMarkdown.inline))
            } else {
                truncated = true
            }
            index += 1
        }
        var table = MarkdownTable(header: header.map(MessageMarkdown.inline), rows: rows)
        table.truncated = truncated
        blocks.append(.table(table))
    }
}
