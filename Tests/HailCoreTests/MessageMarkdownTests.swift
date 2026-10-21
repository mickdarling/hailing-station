import Foundation
import Testing
@testable import HailCore

/// #606: the shared Markdown model for a reply's metadata. Synthetic content only.
@Suite struct MessageMarkdownTests {
    private func text(_ string: AttributedString) -> String { String(string.characters) }

    private func links(_ string: AttributedString) -> [URL] { string.runs.compactMap(\.link) }

    @Test func headingsParagraphsAndRules() {
        let blocks = MessageMarkdown.blocks("# Title\n\nFirst line\nsecond line\n\n---\n### Small ###")
        #expect(blocks.count == 4)
        guard case .heading(1, let title) = blocks[0], case .paragraph(let body) = blocks[1],
              case .rule = blocks[2], case .heading(3, let small) = blocks[3] else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(text(title) == "Title")
        #expect(text(body) == "First line\nsecond line")
        #expect(text(small) == "Small")
    }

    @Test func bulletAndNumberedListsNestByIndentation() {
        let blocks = MessageMarkdown.blocks("- one\n  - nested\n    more of nested\n- two\n\n1. first\n2) second")
        let items = blocks.compactMap { block -> String? in
            guard case .listItem(let depth, let marker, let body) = block else { return nil }
            return "\(depth) \(marker) \(text(body))"
        }
        #expect(items == ["0 • one", "1 • nested\nmore of nested", "0 • two", "0 1. first", "0 2) second"])
    }

    @Test func fencedCodeIsKeptExactlyAndNeverParsed() {
        let blocks = MessageMarkdown.blocks("```swift\nlet x = \"**not bold**\" // [no](https://example.com)\n```\nafter")
        #expect(blocks.first == .code(language: "swift", text: "let x = \"**not bold**\" // [no](https://example.com)"))
        let unterminated = MessageMarkdown.blocks("~~~\n<script>raw</script>")
        #expect(unterminated == [.code(language: nil, text: "<script>raw</script>")])
    }

    @Test func tablesPadShortRowsAndOfferANarrowFallback() throws {
        let source = "| Check | Result |\n| :--- | ---: |\n| tests | passed |\n| lint |\n| a \\| b | ok |"
        let blocks = MessageMarkdown.blocks(source)
        guard case .table(let table) = try #require(blocks.first) else {
            Issue.record("not a table: \(blocks)")
            return
        }
        #expect(table.header.map(text) == ["Check", "Result"])
        #expect(table.rows.map { $0.map(text) } == [["tests", "passed"], ["lint", ""], ["a | b", "ok"]])
        #expect(table.records[1].map { text($0.name) } == ["Check"]) // the empty cell is skipped
        #expect(!table.truncated)
    }

    @Test func aPipeWithoutADelimiterRowIsAParagraph() {
        #expect(MessageMarkdown.blocks("a | b\nc | d") == [.paragraph(AttributedString("a | b\nc | d"))])
    }

    @Test func inlineStylesBecomePresentationIntents() {
        let styled = MessageMarkdown.inline("**bold** _it_ `code` ~~gone~~")
        let intents = styled.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.code))
        #expect(intents.contains(.strikethrough))
        #expect(text(styled) == "bold it code gone")
    }

    @Test func webLinksStayLinksAndShowTheirRealSite() {
        let linked = MessageMarkdown.inline("See [the PR](https://example.com/pull/1) and https://example.org/x.")
        #expect(links(linked) == [URL(string: "https://example.com/pull/1"), URL(string: "https://example.org/x")])
        #expect(text(linked) == "See the PR (example.com) and https://example.org/x.")
    }

    @Test func nonWebLinksAreTextThatNamesTheirTarget() {
        for target in ["javascript:alert(1)", "file:///etc/hosts", "https://user@example.com/", "docs/readme.md"] {
            let shown = MessageMarkdown.inline("[open](\(target))")
            #expect(links(shown).isEmpty, "\(target)")
            #expect(text(shown).contains(target), "\(target)")
        }
    }

    @Test func imagesAreNeverLoadedOnlyLinked() {
        let shown = MessageMarkdown.inline("![chart](https://example.com/chart.png)")
        #expect(shown.runs.allSatisfy { $0.imageURL == nil })
        #expect(links(shown) == [URL(string: "https://example.com/chart.png")])
        #expect(text(shown).hasPrefix("Image: chart"))
    }

    @Test func rawHTMLIsLiteralText() {
        let shown = MessageMarkdown.inline("<b>hi</b> <img src=\"https://example.com/x.png\">")
        #expect(text(shown) == "<b>hi</b> <img src=\"https://example.com/x.png\">")
        #expect(links(shown).isEmpty)
        #expect(shown.runs.allSatisfy { !($0.inlinePresentationIntent?.contains(.inlineHTML) ?? false) })
    }

    @Test func linkLabelsLoseHiddenFormatCharacters() {
        let shown = MessageMarkdown.inline("[exa\u{202E}mple](https://example.com)")
        #expect(!text(shown).unicodeScalars.contains("\u{202E}"))
    }

    @Test func plainTextHasNoMarkdownSyntax() {
        let blocks = MessageMarkdown.blocks("## Status\n- **done**: [PR](https://example.com/pull/1)")
        #expect(MessageMarkdown.plainText(blocks) == "Status\n• done: PR (example.com)")
    }

    @Test func blockAndRowCapsKeepTheRestReadable() throws {
        let many = (0..<(MessageMarkdown.maxBlocks + 10)).map { "# h\($0)" }.joined(separator: "\n")
        let blocks = MessageMarkdown.blocks(many)
        #expect(blocks.count == MessageMarkdown.maxBlocks + 1)
        guard case .paragraph(let rest) = try #require(blocks.last) else {
            Issue.record("no remainder paragraph")
            return
        }
        #expect(text(rest).hasPrefix("# h\(MessageMarkdown.maxBlocks)"))

        let rows = (0..<(MessageMarkdown.maxRows + 5)).map { "| r\($0) |" }.joined(separator: "\n")
        guard case .table(let table) = try #require(MessageMarkdown.blocks("| h |\n| - |\n" + rows).first) else {
            Issue.record("not a table")
            return
        }
        #expect(table.rows.count == MessageMarkdown.maxRows)
        #expect(table.truncated)
    }

    /// A list crossing the block cap keeps the items it could not place as text, from the first one left out.
    @Test func aListCutByTheBlockCapKeepsTheRestAsText() throws {
        let items = (0..<450).map { "- item \($0)" }.joined(separator: "\n")
        let blocks = MessageMarkdown.blocks(items + "\nTAIL")
        #expect(blocks.count == MessageMarkdown.maxBlocks + 1)
        guard case .paragraph(let rest) = try #require(blocks.last) else {
            Issue.record("no remainder paragraph")
            return
        }
        #expect(text(rest).hasPrefix("- item \(MessageMarkdown.maxBlocks)\n"))
        #expect(text(rest).hasSuffix("- item 449\nTAIL"))
    }

    /// A paragraph closed by a heading at the cap: the heading and the rest rejoin the text, never past the cap.
    @Test func blocksFinishedPastTheCapRejoinTheText() throws {
        let headings = (0..<(MessageMarkdown.maxBlocks - 1)).map { "# h\($0)" }
        let blocks = MessageMarkdown.blocks((headings + ["last paragraph", "# over", "tail"]).joined(separator: "\n"))
        #expect(blocks.count == MessageMarkdown.maxBlocks + 1)
        #expect(blocks[MessageMarkdown.maxBlocks - 1] == .paragraph(AttributedString("last paragraph")))
        guard case .paragraph(let rest) = try #require(blocks.last) else {
            Issue.record("no remainder paragraph")
            return
        }
        #expect(text(rest) == "# over\ntail")
    }

    @Test func onlyBlankLinesPastTheCapLeaveNoEmptyBlock() {
        let items = (0..<MessageMarkdown.maxBlocks).map { "- item \($0)" }.joined(separator: "\n")
        let blocks = MessageMarkdown.blocks(items + "\n\n   \n")
        #expect(blocks.count == MessageMarkdown.maxBlocks)
        #expect(blocks.allSatisfy { if case .listItem = $0 { true } else { false } })
    }

    @Test func aLinkTargetOver2048BytesIsNotALink() {
        let target = "https://example.com/" + String(repeating: "a", count: 2_048)
        let shown = MessageMarkdown.inline("[long](\(target))")
        #expect(links(shown).isEmpty)
        #expect(text(shown).hasPrefix("long (https://example.com/"))
    }

    @Test func deeplyNestedInputDoesNotRecurse() {
        let quotes = String(repeating: ">", count: 10_000) + " deep"
        let brackets = String(repeating: "[", count: 10_000) + "x"
        #expect(MessageMarkdown.blocks(quotes).count == 1)
        #expect(MessageMarkdown.blocks(brackets).count == 1)
    }
}
