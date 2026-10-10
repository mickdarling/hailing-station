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

    @Test func aLabelThatOnlyMentionsAHostStillShowsTheRealOne() {
        // Review round 1 bypasses: a substring of the label must never hide the destination.
        #expect(MessageLinks.destinationHint(label: "https://evil.com.paypal.com/login", url: url("https://evil.com"))
            == "evil.com")
        #expect(MessageLinks.destinationHint(label: "paypal.com", url: url("https://aypal.com")) == "aypal.com")
        #expect(MessageLinks.destinationHint(label: "PR 438", url: url("https://github.com/x/y/pull/438"))
            == "github.com")
    }

    @Test func aLabelThatIsTheDestinationNeedsNoHint() {
        #expect(MessageLinks.destinationHint(label: "https://example.com/a", url: url("https://example.com/a")) == nil)
        #expect(MessageLinks.destinationHint(label: "https://Example.com/other", url: url("https://example.com/a"))
            == nil)
        for case .link(let label, let link) in MessageLinks.segments("see https://example.com/a.") {
            #expect(MessageLinks.destinationHint(label: label, url: link) == nil)
        }
    }

    @Test func bidiControlsAreRemovedFromLabels() {
        let segments = MessageLinks.segments("[Docs\u{202E}moc.elgoog](https://evil.com)")
        #expect(segments == [link("Docsmoc.elgoog", "https://evil.com")])
        #expect(MessageLinks.visible("a\u{200E}b\u{2066}c\u{2069}d\u{061C}e") == "abcde")
    }

    @Test func hostsAreShownDecoded() {
        #expect(MessageLinks.destinationHint(label: "Docs", url: url("https://%65vil.com/x")) == "evil.com")
    }

    @Test func markdownTargetsMayHoldBalancedParentheses() {
        #expect(MessageLinks.segments("[Swift](https://en.wikipedia.org/wiki/Swift_(programming_language)).") == [
            link("Swift", "https://en.wikipedia.org/wiki/Swift_(programming_language)"), .text(".")
        ])
    }

    @Test func plainTextIsUnchanged() {
        #expect(MessageLinks.segments("no links here") == [.text("no links here")])
        #expect(MessageLinks.segments("").isEmpty)
    }
}
