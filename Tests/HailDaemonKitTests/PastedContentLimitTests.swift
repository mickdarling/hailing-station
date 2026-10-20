import HailProtocol
import Testing
@testable import HailDaemonKit

/// #608: the caps and refusals of `PastedContent.frame`. Synthetic text only.
@Suite struct PastedContentLimitTests {
    /// #628 review: a paste must not widen the spoken request's own cap.
    @Test func theSpokenRequestKeepsItsOwnCap() {
        let spoken = String(repeating: "word ", count: 500) // 2,499 characters once trimmed
        #expect(throws: SanitizeError.tooLong(characters: 2_499, limit: 2_000)) {
            try PastedContent.frame(spoken: spoken, pasted: "x")
        }
    }

    @Test func hiddenCharactersAreRefusedNotStripped() {
        #expect(throws: SanitizeError.hiddenCharacters("bidirectional control")) {
            try PastedContent.frame(spoken: "", pasted: "abc\u{202E}def")
        }
        #expect(throws: SanitizeError.hiddenCharacters("zero-width character")) {
            try PastedContent.frame(spoken: "", pasted: "pass\u{200B}word")
        }
    }

    @Test func aPasteOfOnlyControlsAndSpaceIsEmpty() {
        #expect(throws: SanitizeError.empty) {
            try PastedContent.frame(spoken: "look", pasted: "\u{1B}[0m \n\t \u{07}")
        }
    }

    @Test func thePasteCapAndTheFramedCapAreBothEnforced() {
        let over = String(repeating: "p", count: PayloadLimits.maxPastedTextBytes + 1)
        #expect(throws: SanitizeError.tooManyBytes(bytes: over.utf8.count, limit: PayloadLimits.maxPastedTextBytes)) {
            try PastedContent.frame(spoken: "", pasted: over)
        }
        // Under the paste cap, but six bytes per `<` once escaped.
        let brackets = String(repeating: "<", count: 10_000)
        #expect(throws: SanitizeError.self) { try PastedContent.frame(spoken: "", pasted: brackets) }
    }

    @Test func refusalsAreShortPlainSentences() {
        let errors: [SanitizeError] = [
            .empty, .tooManyBytes(bytes: 70_000, limit: 49_152), .hiddenCharacters("zero-width character"),
            .containsLineBreak, .tooLong(characters: 2_499, limit: 2_000)
        ]
        for error in errors {
            let message = PastedContent.refusal(error)
            #expect(message.contains("paste"))
            #expect(message.utf8.count <= ControlLimits.maxErrorMessage)
        }
    }
}
