import HailCore
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
}
