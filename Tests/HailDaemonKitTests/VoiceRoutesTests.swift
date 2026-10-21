#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// The owner's allow-list of named sessions and the opening-name parser (#636, slice 1). Synthetic only. Route
/// targets pass `validateTarget`, whose guard budget is frozen so scheduler load cannot refuse a valid id (#208).
@Suite(.frozenGuardBudget, .timeLimit(.minutes(1))) struct VoiceRoutesTests {
    static let names: Set<String> = ["jarvis", "rightyo"]
    static let scratch = VoiceRoutes.Route(target: "tmux:hailing-test", name: "Hailing Scratch", aliases: ["Scratch"])
    static let voice = VoiceRoutes.Route(target: "tmux:voicework11", name: "Voice Work", aliases: ["Voice Walk"])
    static let deck = VoiceRoutes.Route(target: "tmux:deck", name: "Deck")
    static func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: scratch.target, routes: [scratch, voice, deck])
    }

    @Test(arguments: [
        ("Voice Work, check the build.", "tmux:voicework11", "check the build."),
        ("voicework , run the tests", "tmux:voicework11", "run the tests"),
        ("Deck: add a slide on pricing", "tmux:deck", "add a slide on pricing"),
        ("Hey Deck - what's next?", "tmux:deck", "what's next?"),
        ("Okay scratch: status please", "tmux:hailing-test", "status please"),
        ("Hailing Scratch, are you there?", "tmux:hailing-test", "are you there?"),
        ("Voice Walk, look at the logs", "tmux:voicework11", "look at the logs")
    ])
    func aNamedRouteTakesTheWordsAfterItsName(_ heard: String, _ target: String, _ text: String) throws {
        guard case .routed(let route, let words) = try Self.routes().match(heard, names: Self.names) else {
            Issue.record("not routed: \(heard)")
            return
        }
        #expect(route.target == target && words == text)
    }

    /// A name is an address only when a mark follows it; anywhere else, or after an addressing name, it is a word.
    @Test(arguments: [
        "What's the build status?", "Jarvis, what's the build status?", "Check, the build is red",
        "Decks are stacked", "deck.md needs work", "Can Voice Work look at this?", "Ok", "",
        "Please ask Deck to add a slide", "Work, voice the build", "Deck the halls", "Jarvis, deck is still stopped",
        "Voice Work run the tests", "Deck-building is next", "Deck. Add a slide", "Jarvis, Voice Work, open it",
        "Hey RightyO, scratch, status please", "Jarvis, Deck."
    ])
    func anythingElseIsUnaddressed(_ heard: String) throws {
        #expect(try Self.routes().match(heard, names: Self.names) == .unaddressed)
    }

    /// A misheard name that is no listed spelling sends nothing, rather than guessing or falling back.
    @Test(arguments: ["Voice Wok, run it", "Hey Voice Word, run it", "Hailing Scratcher, hi", "Vice Work, go"])
    func aNearMissFollowedByACommaIsUnclear(_ heard: String) throws {
        #expect(try Self.routes().match(heard, names: Self.names) == .unclear)
    }

    @Test(arguments: ["Voice Wok run it", "Duck, quack", "Desk, please", "Jarvis, Voice Word, run it"])
    func aNearMissWithoutACommaOfAShortNameOrAfterAnAddressingNameIsUnaddressed(_ heard: String) throws {
        #expect(try Self.routes().match(heard, names: Self.names) == .unaddressed)
    }

    /// A common-word name is the riskiest: only "Sales, …" addresses the session, not a sentence about sales.
    @Test func aCommonWordNameRoutesOnlyWhenAddressed() throws {
        let sales = VoiceRoutes.Route(target: "tmux:sales", name: "Sales")
        let routes = try VoiceRoutes(defaultTarget: Self.scratch.target, routes: [Self.scratch, sales])
        #expect(routes.match("Sales are slow this week", names: Self.names) == .unaddressed)
        #expect(routes.match("Jarvis, sales are slow", names: Self.names) == .unaddressed)
        #expect(routes.match("Sales, how is the week?", names: Self.names) == .routed(sales, text: "how is the week?"))
    }

    /// A word window never crosses a mark (Codex review on #646): with routes "Voice" and "Voice Work", "Voice, …" is
    /// Voice addressed, and only "Voice Work, …" is Voice Work.
    @Test func aShorterRouteMarkedBeforeALongerOnesWordsIsTheOneAddressed() throws {
        let voice = VoiceRoutes.Route(target: "tmux:v", name: "Voice")
        let routes = try VoiceRoutes(defaultTarget: Self.voice.target, routes: [Self.voice, voice])
        #expect(routes.match("Voice, Work is blocked") == .routed(voice, text: "Work is blocked"))
        #expect(routes.match("Voice, Work, status") == .routed(voice, text: "Work, status"))
        #expect(routes.match("Voice Work, status") == .routed(Self.voice, text: "status"))
        #expect(routes.match("Okay voice: status") == .routed(voice, text: "status"))
        // A heard word that keys to nothing is never skipped over to reach a name.
        #expect(routes.match("東京 Voice, status") == .unaddressed)
    }

    @Test func aNameWithAnApostropheOrDigitIsSayable() throws {
        let micks = VoiceRoutes.Route(target: "tmux:m", name: "Mick's Deck 2")
        let routes = try VoiceRoutes(defaultTarget: micks.target, routes: [micks])
        #expect(routes.match("mick's deck 2, status") == .routed(micks, text: "status"))
    }

    @Test func anAddressingNameIsNeverANearMiss() throws {
        #expect(try Self.routes().match("Voice Word, run it", names: ["voiceword"]) == .unaddressed)
    }

    @Test(arguments: ["Deck", "Deck?", "Hey deck - ", "Deck:"])
    func aNameAloneHasNothingToSay(_ heard: String) throws {
        #expect(try Self.routes().match(heard, names: Self.names) == .nothingToSay(Self.deck))
    }

    @Test func aRouteMayShareASpellingWithAnAddressingName() throws {
        let jarvis = VoiceRoutes.Route(target: "tmux:hailing-test", name: "Jarvis")
        let routes = try VoiceRoutes(defaultTarget: jarvis.target, routes: [jarvis, Self.deck])
        #expect(routes.match("Jarvis, status", names: Self.names) == .routed(jarvis, text: "status"))
        #expect(routes.match("Jarvis, Deck, status", names: Self.names) == .routed(jarvis, text: "Deck, status"))
    }

    @Test func aReplyIsLabelledOnlyByAnExactTarget() throws {
        let routes = try Self.routes()
        #expect(routes.route(for: "tmux:voicework11")?.name == "Voice Work")
        #expect(routes.route(for: "tmux:voicework") == nil && routes.route(for: "tmux-reply:deck") == nil)
    }

    @Test(arguments: [
        ([deck], "tmux:hailing-test", VoiceRoutes.LoadError.unknownDefault),
        ([VoiceRoutes.Route(target: "deck", name: "Deck")], "deck", .invalidTarget),
        ([VoiceRoutes.Route(target: "tmux:a b", name: "Deck")], "tmux:a b", .invalidTarget),
        ([deck, VoiceRoutes.Route(target: "tmux:deck", name: "Slides")], "tmux:deck", .duplicateTarget),
        ([deck, VoiceRoutes.Route(target: "tmux:d2", name: "DECK!")], "tmux:deck", .duplicateName),
        ([deck, VoiceRoutes.Route(target: "tmux:d2", name: "Slides", aliases: ["deck"])], "tmux:deck", .duplicateName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "One two three four")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "!!")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "Hey")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "Okay Deck")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "Hey' Deck")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "O'K Deck")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "One-Two-Three-Four")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "Voice-Work")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "東京 Deck")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "Café")], "tmux:deck", .invalidName),
        ([VoiceRoutes.Route(target: "tmux:deck", name: "De\nck")], "tmux:deck", .invalidName),
        ([], "tmux:deck", .malformed)
    ])
    func anInvalidAllowListIsRefused(_ routes: [VoiceRoutes.Route], _ fallback: String,
                                     _ error: VoiceRoutes.LoadError) {
        #expect(throws: error) { try VoiceRoutes(defaultTarget: fallback, routes: routes) }
    }

    @Test func aRouteMayHaveAtMostEightAliases() {
        let aliases = (1...9).map { "Alias \($0)" }
        #expect(throws: VoiceRoutes.LoadError.invalidName) {
            let route = VoiceRoutes.Route(target: "tmux:deck", name: "Deck", aliases: aliases)
            _ = try VoiceRoutes(defaultTarget: "tmux:deck", routes: [route])
        }
    }
}
#endif
