import HailCore
import SwiftUI

/// Fenced code (#606): exactly as written, monospaced, scrolling sideways rather than wrapping, selectable and
/// copyable on its own.
struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(verbatim: code)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(8)
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("Copy Code", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
        .accessibilityValue(code)
    }
}

/// A pipe table (#606): a grid where it fits, otherwise each row as "column: value" lines, so a narrow phone never
/// clips a column. Each row is one VoiceOver element that names its columns.
struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                grid
                records
            }
            if table.truncated {
                Text("Table shortened. Show Raw Text for all of it.")
                    .font(.caption2)
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                    Text(ReplyMetadataView.styled(cell)).fontWeight(.semibold).foregroundStyle(.primary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Divider()
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(ReplyMetadataView.styled(cell))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(table.records.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(record.enumerated()), id: \.offset) { _, pair in
                        Text(Self.line(name: pair.name, value: pair.value))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "Column: value", the column name bold; one string, so it wraps as one line of text.
    private static func line(name: AttributedString, value: AttributedString) -> AttributedString {
        var named = name
        named.inlinePresentationIntent = .stronglyEmphasized
        return named + AttributedString(": ") + ReplyMetadataView.styled(value)
    }
}

#Preview("Reply details (#606)") {
    let source = """
        ## Build
        - **Status:** green, see [the pull request](https://example.com/pull/1)
        - File: `Sources/Example.swift`
          - nested note

        | Check | Result | Notes |
        | --- | --- | --- |
        | tests | passed | synthetic run |
        | lint | passed | |

        ```swift
        let reply = "synthetic"
        ```

        > a _quoted_ note
        <b>raw html stays text</b> ![chart](https://example.com/chart.png) [odd](javascript:void(0))
        """
    ScrollView {
        ReplyMetadataView(source: source, blocks: MessageMarkdown.blocks(source))
            .padding()
    }
}
