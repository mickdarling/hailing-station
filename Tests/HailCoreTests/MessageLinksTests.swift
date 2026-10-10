import Foundation
import Testing
@testable import HailCore

/// #444: which parts of a conversation message become tappable links.
@Suite struct MessageLinksTests {
    private func url(_ string: String) -> URL { URL(string: string) ?? URL(fileURLWithPath: "/not-a-url") }
    private func link(_ label: String, _ string: String) -> MessageSegment { .link(label: label, url: url(string)) }

    @Test func bareHTTPAndHTTPSURLsBecomeLinks() {
        #expect(MessageLinks.segments("See https://github.com/mickdarling/hailing-station/pull/438 now") == [
            .text("See "), link("https://github.com/mickdarling/hailing-station/pull/438",
                                 "https://github.com/mickdarling/hailing-station/pull/438"), .text(" now")
        ])
        #expect(MessageLinks.links("a http://example.com b") == [url("http://example.com")])
    }

    @Test func trailingSentencePunctuationIsNotPartOfTheLink() {
        #expect(MessageLinks.segments("Done: https://example.com/a.") == [
            .text("Done: "), link("https://example.com/a", "https://example.com/a"), .text(".")
        ])
        #expect(MessageLinks.links("(see https://example.com/x), then") == [url("https://example.com/x")])
        // A parenthesis the URL opened stays part of it.
        #expect(MessageLinks.links("https://en.wikipedia.org/wiki/Swift_(programming_language)") ==
            [url("https://en.wikipedia.org/wiki/Swift_(programming_language)")])
    }

    @Test func markdownLinksShowTheirLabel() {
        #expect(MessageLinks.segments("Opened [PR 438](https://github.com/x/y/pull/438) for you") == [
            .text("Opened "), link("PR 438", "https://github.com/x/y/pull/438"), .text(" for you")
        ])
    }

    @Test func otherSchemesStayPlainText() {
        for text in ["[tap](javascript:alert(1))", "[file](file:///etc/passwd)", "[app](slack://open)",
                     "javascript:alert(1)", "file:///etc/passwd", "mailto:a@example.com", "example.com",
                     "[empty](https://)"] {
            #expect(MessageLinks.links(text).isEmpty, "\(text)")
            let plain = MessageLinks.segments(text).map { if case .text(let run) = $0 { run } else { "" } }
            #expect(plain.joined() == text)
        }
    }

    @Test func aBlankLabelShowsTheRealAddress() {
        #expect(MessageLinks.segments("[ ](https://example.com)") == [
            .text("[ ]("), link("https://example.com", "https://example.com"), .text(")")
        ])
    }

    @Test func plainTextIsUnchanged() {
        #expect(MessageLinks.segments("no links here") == [.text("no links here")])
        #expect(MessageLinks.segments("").isEmpty)
    }
}
