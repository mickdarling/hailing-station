#if os(macOS)
import Testing
@testable import HailDaemonKit

/// Privacy mode's entry matcher against a synthetic corpus (#735 S-2 round 2, intentional only): every standalone
/// command enters, every negated one is "Still recording.", and nothing else (embedded, questions, mentions, objects,
/// leaving phrases, old duck phrases, unrelated speech) is a command. Synthetic text only.
@Suite struct AmbientPrivacyCorpusTests {
    static let names: Set<String> = ["jarvis", "rightyo"]
    static let prefixes = ["", "Jarvis, ", "Hey Jarvis, ", "OK Jarvis, ", "Okay, ", "Um, ", "So ", "Please ",
                           "Jarvis please ", "Computer, "]
    static let commands = ["stop recording", "Stop listening", "privacy mode", "go private", "stop the recording",
                           "stop all recording", "stop the recordings", "stop listening to me", "turn on privacy mode",
                           "STOP RECORDING"]
    static let suffixes = ["", ".", " please.", " now!", ", thanks.", ", thank you"]
    /// Every intentional standalone form: 600 generated, plus a few by hand.
    static let intentional = prefixes.flatMap { prefix in
        commands.flatMap { command in suffixes.map { prefix + command + $0 } }
    } + [
        "Stop recording, Jarvis.", "Privacy mode, Righty O.", "Go private now.", "Stop all the recordings!",
        "Privacy mode on.", "Enter privacy mode.", "Start privacy mode", "Uh, stop listening.", "stop-recording",
        "Jarvis. Stop recording.", "Okay. Privacy mode. Thanks."
    ]
    static let negated = [
        "Don't stop recording.", "Jarvis, do not stop listening.", "Please don't go private.", "never stop recording",
        "Hey Jarvis, don't stop the recording, thanks.", "Dont privacy mode", "Do not stop all recording.",
        "Jarvis, never go private."
    ]
    static let nothing = [
        // Embedded mid-sentence.
        "we should go private", "I think I'll stop recording", "I think we should go private for a bit",
        "Let's go private", "maybe stop recording at some point", "I told her to stop recording",
        "you can stop listening whenever", "it's fine to go private later", "No, stop recording.",
        "Don't worry, stop recording", "Don't stop. Stop recording.", "Okay so I want privacy mode",
        "can you stop recording", "Could you go private", "would you stop listening", "I need privacy mode",
        // Objects after the phrase.
        "stop listening to podcasts", "stop listening on 443", "go private on github", "stop recording my expenses",
        "stop recording the meeting", "stop listening to music", "privacy mode settings", "go private with the repo",
        "stop recording audio", "stop the recording studio booking", "privacy mode toggle",
        // Questions and mentions.
        "What is privacy mode?", "what is privacy mode", "What's privacy mode", "how does privacy mode work",
        "is privacy mode on", "Is privacy mode on?", "tell me about privacy mode", "privacy mode?",
        "Jarvis, privacy mode?", "explain privacy mode", "what does stop recording do", "if I say stop listening",
        "how do I stop the recording", "are you recording", "Are you listening?", "what happens when you go private",
        "Stop recording?", "Go private?", "Can you stop recording?", "why don't you stop recording",
        "I never said stop recording", "I can't stop recording now", "what mode am I in",
        // Leaving phrases and states.
        "privacy mode off", "end privacy mode", "turn off privacy mode", "get out of privacy mode",
        "Privacy mode is off.", "no more privacy mode", "done with privacy mode", "privacy mode is over",
        "I'm not in privacy mode", "exit privacy mode", "Jarvis, I'm back", "start listening", "privacy off",
        // Negations that are not standalone, and double negations.
        "I don't want you to stop recording", "don't not stop recording", "never not go private",
        "I didn't say stop recording", "without privacy mode", "don't stop", "do not stop the music",
        // Old duck phrases.
        "Jarvis, duck mode.", "Let me think out loud", "Jarvis, done thinking.", "duck mode on", "end duck mode",
        // Near misses.
        "", "Jarvis,", "Jarvis", "stop", "recording", "privacy", "private mode", "go privately", "stop that",
        "Jarvis, stop.", "the recording stopped", "stop recordin", "go privet", "privacy mood", "stop listen",
        "listening stopped", "recording stop", "mode privacy", "private go", "stop the the the recording",
        // Unrelated speech that contains the words.
        "The recording is great", "I was listening to the radio", "Privacy matters to me", "Going private equity",
        "She went private last year", "Stop by the store", "Keep recording", "Start recording", "Resume listening",
        "Turn the radio on", "Jarvis, archive the project.", "Rightyo, check our discussion.",
        "Well, stop recording.", "Wait, go private.", "Actually, privacy mode.", "Yeah, stop listening.",
        "Listen, stop recording.", "Fine, go private.", "Oh, privacy mode.", "And stop recording",
        "The privacy mode feature shipped", "Recording stopped at noon", "We stopped listening to that band",
        "Private mode is on in the browser", "He said go private", "Mode: privacy", "Recording mode",
        "stop recording and then send it", "go private and quiet", "privacy mode and media mode",
        "I'll stop listening now", "you should stop recording", "please never mind"
    ]

    @Test func everyIntentionalCommandEnters() {
        let misses = Self.intentional.filter { PrivacyEntry.match($0, names: Self.names) != .enter }
        #expect(Self.intentional.count >= 600)
        #expect(misses.isEmpty, "false negatives: \(misses)")
    }

    @Test func everyNegatedCommandIsStillRecording() {
        let misses = Self.negated.filter { PrivacyEntry.match($0, names: Self.names) != .negated }
        #expect(misses.isEmpty, "misread negations: \(misses)")
    }

    @Test func nothingElseIsACommand() {
        let hits = Self.nothing.filter { PrivacyEntry.match($0, names: Self.names) != nil }
        #expect(Self.nothing.count >= 120)
        #expect(hits.isEmpty, "false positives: \(hits)")
    }

    /// A name said alone is no command; the standalone command in the next turn enters.
    @Test func aSplitNameEntersOnTheSecondTurn() {
        #expect(PrivacyEntry.match("Jarvis,", names: Self.names) == nil)
        #expect(PrivacyEntry.match("stop recording", names: Self.names) == .enter)
    }
}
#endif
