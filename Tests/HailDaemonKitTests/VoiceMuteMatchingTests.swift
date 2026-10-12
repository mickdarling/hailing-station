#if os(macOS)
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Which whole turns are the owner's spoken mute or unmute (#404), and the one-at-a-time order they are carried out
/// in. Synthetic only; not device hearing.
@Suite struct VoiceMuteMatchingTests {
    static let names: Set<String> = ["jarvis", "friday", "rightyo"]

    @Test(arguments: [
        ("Jarvis, mute.", true), ("mute", true), ("Hey Jarvis, go quiet please.", true), ("Text only.", true),
        ("Jarvis please mute", true), ("Jarvis, unmute.", false), ("You can talk again.", false),
        ("Friday, talk again", false)
    ])
    func aWholeTurnMutePhraseIsRecognised(_ heard: String, _ muted: Bool) {
        #expect(VoiceMute.command(in: heard, names: Self.names) == (muted ? .mute : .unmute))
    }

    /// Only the session's own addressing names may lead the phrase; any other first word makes it a request.
    @Test(arguments: [
        "Don't mute.", "Jarvis, don't mute.", "Mute the TV in the other room.", "Can you mute", "Is it muted?",
        "Jarvis, mute the meeting notes", "", "Jarvis", "Not text only", "Okay, so then mute", "Press mute",
        "Hit mute", "Why mute?", "Just mute", "Let's talk again", "Okay, let's talk again", "Siri, mute"
    ])
    func anythingElseIsNotAMute(_ heard: String) {
        #expect(VoiceMute.command(in: heard, names: Self.names) == nil)
    }

    @Test func theNamesAreTheAdvertisedAddressingNamesWithTheirSpellings() {
        let addressing = JSONValue.object([
            "names": .array([.string("Rightyo"), .string("Jarvis")]),
            "variants": .object(["Rightyo": .array([.string("Righty O")])])
        ])
        let names = VoiceMute.names(in: addressing)
        #expect(names == ["rightyo", "jarvis"])
        #expect(VoiceMute.command(in: "Righty O, mute.", names: names) == .mute)
        #expect(VoiceMute.command(in: "Jarvis, mute.", names: []) == nil) // a session that advertised no names
        #expect(VoiceMute.command(in: "Mute.", names: []) == .mute)
    }

    /// A quick "mute" then "unmute" ends unmuted: the second command waits for the first, however long it takes.
    @Test func voiceMuteCommandsRunOneAtATimeInOrder() async {
        let chain = SerialTaskChain(), order = Mutex<[String]>([])
        chain.enqueue {
            try? await Task.sleep(for: .milliseconds(100))
            order.withLock { $0.append("mute") }
        }
        chain.enqueue { order.withLock { $0.append("unmute") } }
        #expect(await eventually { order.withLock { $0.count == 2 } })
        #expect(order.withLock { $0 } == ["mute", "unmute"])
    }
}
#endif
