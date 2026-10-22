#if os(macOS)
import Testing
@testable import HailDaemonKit

/// Privacy mode's entry matcher against a synthetic corpus (#735 S-2 rounds 2 and 3, intentional only): every
/// standalone command enters, every negated one is "Still recording.", a turn that starts with a command and goes on
/// is `partial` (the owner's is held back with a hint), and nothing else counts: mid-sentence mentions (code dictation
/// included), questions, leaving phrases, old duck phrases, unrelated speech. Who may say it is the consumer's rule.
/// Synthetic text only.
@Suite struct AmbientPrivacyCorpusTests {
    static let names: Set<String> = ["jarvis", "rightyo"]
    static let prefixes = ["", "Jarvis, ", "Hey Jarvis, ", "OK Jarvis, ", "Okay, ", "Um, ", "So ", "Please ",
                           "Jarvis please ", "Computer, ", "Can you ", "Could you please ", "Just ", "Alright, ",
                           "Wait, ", "No no ", "Jarvis can you "]
    static let commands = ["stop recording", "Stop listening", "privacy mode", "go private", "stop the recording",
                           "stop all recording", "stop the recordings", "stop listening to me", "turn on privacy mode",
                           "STOP RECORDING", "enable privacy mode", "activate privacy mode", "switch to privacy mode"]
    static let suffixes = ["", ".", " please.", " now!", ", thanks.", ", thank you", " for a minute", " right now",
                           " for now"]
    /// Every intentional standalone form: generated, plus key 2's round-3 list and a few more by hand.
    static let intentional = prefixes.flatMap { prefix in
        commands.flatMap { command in suffixes.map { prefix + command + $0 } }
    } + [
        "Stop recording, Jarvis.", "Privacy mode, Righty O.", "Go private now.", "Stop all the recordings!",
        "Privacy mode on.", "Enter privacy mode.", "Start privacy mode", "Uh, stop listening.", "stop-recording",
        "Jarvis. Stop recording.", "Okay. Privacy mode. Thanks.", "No, stop recording.",
        // Key 2's round-3 misses, now intentional.
        "could you please stop recording", "can you stop listening please", "stop recording for a minute",
        "Jarvis stop recording right now", "just stop recording", "no no stop recording", "wait, stop listening",
        "alright, go private please", "enable privacy mode", "activate privacy mode", "switch to privacy mode",
        "Can you stop recording?", "Would you go private for a bit?", "stop recording for a sec", "go private for now"
    ]
    static let negated = [
        "Don't stop recording.", "Jarvis, do not stop listening.", "Please don't go private.", "never stop recording",
        "Hey Jarvis, don't stop the recording, thanks.", "Dont privacy mode", "Do not stop all recording.",
        "Jarvis, never go private.", "Can you not stop recording?", "Just don't stop recording for now"
    ]
    /// Turns that start with a command and go on: the owner's is held back with a hint, anyone else's is a request.
    static let partial = [
        "stop recording, my wife is here", "stop listening to podcasts", "stop listening on 443",
        "go private on github", "stop recording my expenses", "stop recording the meeting", "stop listening to music",
        "privacy mode settings", "go private with the repo", "stop recording audio", "privacy mode toggle",
        "stop recording and then send it", "go private and quiet", "privacy mode and media mode",
        "stop the recording studio booking", "Jarvis, stop recording, the kids are home", "stop_recording returns early"
    ]
    static let nothing = [
        // Mid-sentence, code dictation included: never held.
        "we should go private", "I think I'll stop recording", "I think we should go private for a bit",
        "Let's go private", "maybe stop recording at some point", "I told her to stop recording",
        "you can stop listening whenever", "it's fine to go private later", "Don't worry, stop recording",
        "Don't stop. Stop recording.", "Okay so I want privacy mode", "I need privacy mode",
        "set the flag to stop listening on 443", "we should go private on github",
        "the function stop_recording returns",
        "add a test that checks stop recording", "call stopRecording then exit", "rename privacy_mode to privacyMode",
        "then the server will stop listening on the port", "the repo can go private after launch",
        "if the user says stop recording we pause", "make sure privacy mode is documented",
        // Questions and mentions.
        "What is privacy mode?", "what is privacy mode", "What's privacy mode", "how does privacy mode work",
        "is privacy mode on", "Is privacy mode on?", "tell me about privacy mode", "privacy mode?",
        "Jarvis, privacy mode?", "explain privacy mode", "what does stop recording do", "if I say stop listening",
        "how do I stop the recording", "are you recording", "Are you listening?", "what happens when you go private",
        "Stop recording?", "Go private?", "why don't you stop recording", "I never said stop recording",
        "I can't stop recording now", "what mode am I in", "stop listening to podcasts?",
        // Leaving phrases and states.
        "privacy mode off", "end privacy mode", "turn off privacy mode", "get out of privacy mode",
        "Privacy mode is off.", "no more privacy mode", "done with privacy mode", "privacy mode is over",
        "I'm not in privacy mode", "exit privacy mode", "Jarvis, I'm back", "start listening", "privacy off",
        "privacy mode was off",
        // Negations that are not standalone, and double negations.
        "I don't want you to stop recording", "don't not stop recording", "never not go private",
        "I didn't say stop recording", "without privacy mode", "don't stop", "do not stop the music",
        "don't stop recording the music",
        // Old duck phrases.
        "Jarvis, duck mode.", "Let me think out loud", "Jarvis, done thinking.", "duck mode on", "end duck mode",
        // Near misses.
        "", "Jarvis,", "Jarvis", "stop", "recording", "privacy", "private mode", "go privately", "stop that",
        "Jarvis, stop.", "the recording stopped", "stop recordin", "go privet", "privacy mood", "stop listen",
        "listening stopped", "recording stop", "mode privacy", "private go", "stop the the the recording",
        "can you", "could you please", "just", "wait", "no no",
        // Unrelated speech that contains the words.
        "The recording is great", "I was listening to the radio", "Privacy matters to me", "Going private equity",
        "She went private last year", "Stop by the store", "Keep recording", "Start recording", "Resume listening",
        "Turn the radio on", "Jarvis, archive the project.", "Rightyo, check our discussion.",
        "Well, stop recording.", "Actually, privacy mode.", "Yeah, stop listening.", "Listen, stop recording.",
        "Fine, go private.", "Oh, privacy mode.", "And stop recording", "The privacy mode feature shipped",
        "Recording stopped at noon", "We stopped listening to that band", "Private mode is on in the browser",
        "He said go private", "Mode: privacy", "Recording mode", "I'll stop listening now", "you should stop recording",
        "please never mind", "Can you play some music?", "Could you check the logs",
        "Could you stop recording the meeting?", "Can you go private on github?", "Just checking the recording",
        "Wait for the recording", "No recording today", "Alright, the privacy settings look fine",
        "Enable dark mode", "Activate the alarm", "Switch to media mode", "Turn on the lights",
        "stop the car", "stop the timer", "go to the store", "privately go", "the recordings are stopped",
        "listening to stop", "private, go away", "recording: stop", "mode", "please stop", "now stop",
        "stop now", "go", "private", "Hey Jarvis", "Okay Jarvis thanks", "Thank you",
        // The host's own clips, heard back: none may be a command.
        "To go private, say 'stop recording' on its own.", "Privacy on. I'm only listening for my name.",
        "I couldn't turn on privacy.", "Recording again.", "Still recording.", "Nothing was sent."
    ]

    @Test func everyIntentionalCommandEnters() {
        let misses = Self.intentional.filter { PrivacyEntry.match($0, names: Self.names) != .enter }
        #expect(Self.intentional.count >= 1900)
        #expect(misses.isEmpty, "false negatives: \(misses)")
    }

    @Test func everyNegatedCommandIsStillRecording() {
        let misses = Self.negated.filter { PrivacyEntry.match($0, names: Self.names) != .negated }
        #expect(misses.isEmpty, "misread negations: \(misses)")
    }

    @Test func aCommandThatGoesOnIsPartial() {
        let misses = Self.partial.filter { PrivacyEntry.match($0, names: Self.names) != .partial }
        #expect(misses.isEmpty, "not partial: \(misses)")
    }

    @Test func nothingElseIsACommandOrHeld() {
        let hits = Self.nothing.filter { PrivacyEntry.match($0, names: Self.names) != nil }
        #expect(Self.nothing.count >= 150)
        #expect(hits.isEmpty, "false positives or held: \(hits)")
    }

    /// A name said alone is no command; the standalone command in the next turn enters.
    @Test func aSplitNameEntersOnTheSecondTurn() {
        #expect(PrivacyEntry.match("Jarvis,", names: Self.names) == nil)
        #expect(PrivacyEntry.match("stop recording", names: Self.names) == .enter)
    }
}
#endif
