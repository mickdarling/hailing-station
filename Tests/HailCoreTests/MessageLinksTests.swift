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

    @Test func aLabelNamingAnotherSchemeOrPortShowsTheRealOrigin() {
        // Codex P2: the label's whole origin (scheme, host, effective port) must match to hide the hint.
        #expect(MessageLinks.destinationHint(label: "https://example.com", url: url("http://example.com"))
            == "http://example.com")
        #expect(MessageLinks.destinationHint(label: "https://example.com", url: url("https://example.com:8443"))
            == "example.com:8443")
        #expect(MessageLinks.destinationHint(label: "https://example.com", url: url("https://example.com:443")) == nil)
        #expect(MessageLinks.destinationHint(label: "http://example.com", url: url("http://example.com:80/a")) == nil)
        #expect(MessageLinks.destinationHint(label: "Docs", url: url("http://example.com:8080")) ==
            "http://example.com:8080")
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

    @Test func hostsWithPercentEscapesOrOtherCharactersAreNeverLinked() {
        // Review round 3: a decoded host could spell a lookalike, a path, an "@" or invisible controls.
        for target in ["https://%D0%B0pple.com", "https://paypal.com%2F.evil.com", "https://paypal.com%40evil.com",
                       "https://evil%E2%80%AE.com", "https://ev%E2%80%8Bil.com", "https://%65vil.com/x"] {
            #expect(MessageLinks.webURL(target) == nil, "\(target)")
            #expect(MessageLinks.links("[x](\(target))").isEmpty, "\(target)")
        }
        #expect(MessageLinks.links("see https://%D0%B0pple.com/x").isEmpty)
        #expect(MessageLinks.links("https://[2001:db8::1]/status") == [url("https://[2001:db8::1]/status")])
        #expect(MessageLinks.links("https://example-1.co.uk/a") == [url("https://example-1.co.uk/a")])
    }

    @Test func markdownTargetsMayHoldBalancedParentheses() {
        #expect(MessageLinks.segments("[Swift](https://en.wikipedia.org/wiki/Swift_(programming_language)).") == [
            link("Swift", "https://en.wikipedia.org/wiki/Swift_(programming_language)"), .text(".")
        ])
    }

    @Test func userinfoIsNeverLinkedAndAnAtInALabelShowsTheHost() {
        // Review round 2: everything before "@" is a user name, not the site.
        #expect(MessageLinks.links("log in at https://paypal.com@evil.com/login").isEmpty)
        #expect(MessageLinks.webURL("https://user:secret@example.com") == nil)
        for label in ["https://paypal.com@evil.com", "https://paypal.com @evil.com", "https://paypal.com\\@evil.com"] {
            let segments = MessageLinks.segments("[\(label)](https://evil.com)")
            #expect(segments == [link(label, "https://evil.com")], "\(label)")
            #expect(MessageLinks.destinationHint(label: label, url: url("https://evil.com")) == "evil.com", "\(label)")
        }
    }

    @Test func internationalizedHostsAlwaysShowTheirPunycode() {
        // Review round 2: a Cyrillic "a" (U+0430) makes the host look like apple.com. Whether a non-ASCII host is
        // detected and IDN-encoded at all depends on the Foundation version (CI's older one links nothing). Every
        // outcome must be safe: no link, or a link to the punycode host whose hint shows that punycode. Never
        // "apple.com".
        let cyrillic = "https://\u{0430}pple.com"
        for text in ["\(cyrillic)/login", "[\(cyrillic)/login](\(cyrillic)/login)", "[apple](\(cyrillic))"] {
            let segments = MessageLinks.segments(text)
            let hosts = MessageLinks.links(segments).map { MessageLinks.host(of: $0) }
            #expect(hosts.allSatisfy { $0 == "xn--pple-43d.com" }, "\(text)")
            for case .link(let label, let link) in segments {
                #expect(MessageLinks.destinationHint(label: label, url: link) == "xn--pple-43d.com", "\(text)")
            }
        }
        // Platform-independent: an already-punycoded target always links and always shows its punycode.
        #expect(MessageLinks.segments("[https://apple.com](https://xn--pple-43d.com)") ==
            [link("https://apple.com", "https://xn--pple-43d.com")])
        #expect(MessageLinks.destinationHint(label: "https://apple.com", url: url("https://xn--pple-43d.com"))
            == "xn--pple-43d.com")
        #expect(MessageLinks.destinationHint(label: "https://\u{0430}pple.com", url: url("https://xn--pple-43d.com"))
            == "xn--pple-43d.com")
        #expect(MessageLinks.destinationHint(label: "https://xn--pple-43d.com", url: url("https://xn--pple-43d.com"))
            == "xn--pple-43d.com")
    }

    @Test func formatCharactersAreRemovedFromLabels() {
        #expect(MessageLinks.visible("a\u{200B}b\u{200D}c\u{FEFF}d\u{00AD}e") == "abcde")
    }

    @Test func linkTitlesAreDistinctWhenHostsRepeat() {
        // Codex P2: Copy Link and Share Link for two links on one host must be told apart, by sight and VoiceOver.
        #expect(MessageLinks.titles([url("https://github.com/a"), url("https://example.com/b")]) ==
            ["github.com", "example.com"])
        // Codex P2: hosts differing only in case are the same site, so they get paths (and numbers if those repeat).
        #expect(MessageLinks.titles([url("https://GitHub.com/a"), url("https://github.com/b")]) ==
            ["GitHub.com/a", "github.com/b"])
        #expect(MessageLinks.titles([url("https://GitHub.com/a"), url("https://github.com/a")]) ==
            ["GitHub.com/a (1)", "github.com/a (2)"])
        #expect(MessageLinks.titles([url("https://github.com/x/y/pull/438"), url("https://github.com/x/y/issues/444"),
                                     url("https://example.com/")]) ==
            ["github.com/…/pull/438", "github.com/…/issues/444", "example.com"])
        #expect(MessageLinks.titles([url("https://github.com/a"), url("https://github.com/a?tab=files")]) ==
            ["github.com/a (1)", "github.com/a (2)"])
        let long = MessageLinks.titles([url("https://example.com/" + String(repeating: "x", count: 80)),
                                        url("https://example.com/b")])
        #expect(long[0] == "example.com/" + String(repeating: "x", count: 31) + "…")
        #expect(Set(long).count == 2)
        // Review round 5: the host is never shortened, so a long one keeps its real domain at the end.
        let host = "paypal.com.secure-account-verification-login-update.evil.com"
        let spoof = MessageLinks.titles([url("https://\(host)/" + String(repeating: "y", count: 60)),
                                         url("https://\(host)/b")])
        #expect(spoof.allSatisfy { $0.hasPrefix(host + "/") })
        #expect(Set(spoof).count == 2)
    }

    @Test func plainTextIsUnchanged() {
        #expect(MessageLinks.segments("no links here") == [.text("no links here")])
        #expect(MessageLinks.segments("").isEmpty)
    }
}
