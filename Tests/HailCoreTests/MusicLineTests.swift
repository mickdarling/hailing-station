import Foundation
@testable import HailCore
import Testing

/// #823: a transcribed line wrapped in note marks is music; anything else is speech.
@Suite struct MusicLineTests {
    @Test(arguments: [
        ("♪ la la la ♪", "la la la"),
        ("♪la♪", "la"),
        ("♪♪", ""),
        ("♪", ""),
        ("  ♪  walking  on\nsunshine ♪  ", "walking on sunshine"),
        ("♫ hey jude ♫", "hey jude"),
        ("♪ one ♪ two ♪", "one two"),
        ("♫ mixed marks ♪", "mixed marks")
    ])
    func aLineWrappedInNoteMarksIsMusic(text: String, lyrics: String) {
        #expect(MusicLine.lyrics(text) == lyrics)
    }

    @Test(arguments: ["Turn on the lights", "", "   ", "♪ only starts", "only ends ♪", "a ♪ in the middle"])
    func anythingElseIsSpeech(text: String) {
        #expect(MusicLine.lyrics(text) == nil)
    }

    /// #823 review: only an overheard turn shows as music, from the owner or a guest. A request the owner sent stays
    /// their bubble even wrapped in notes, and Haili's replies never become music.
    @Test func onlyAnOverheardTurnIsMusic() {
        func entry(_ speaker: ConversationEntry.Speaker, overheard: Bool) -> ConversationEntry {
            var entry = ConversationEntry(
                id: "1", speaker: speaker, text: "♪ la la ♪", endpointID: "mac", targetID: "tmux:a", date: .now
            )
            entry.overheard = overheard
            return entry
        }
        #expect(MusicLine.lyrics(of: entry(.you, overheard: true)) == "la la")
        #expect(MusicLine.lyrics(of: entry(.someone, overheard: true)) == "la la")
        #expect(MusicLine.lyrics(of: entry(.you, overheard: false)) == nil)
        #expect(MusicLine.lyrics(of: entry(.haili, overheard: false)) == nil)
        #expect(MusicLine.lyrics(of: entry(.haili, overheard: true)) == nil)
    }
}
