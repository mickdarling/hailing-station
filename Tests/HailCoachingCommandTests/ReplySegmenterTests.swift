import Foundation
import Testing
@testable import haild

struct ReplySegmenterTests {
    @Test func defaultsAndOverrides() throws {
        let defaults = try ReplySegmentation.load(environment: [:])
        #expect(defaults.maxSentences == 2 && defaults.maxWords == 30)
        #expect(ReplySegmenter(configuration: defaults).segments("First. Second. Third.")
                == ["First. Second.", "Third."])
        let custom = try ReplySegmentation.load(environment: [
            "HAILD_REPLY_SEGMENT_MAX_SENTENCES": "1", "HAILD_REPLY_SEGMENT_MAX_WORDS": "4"
        ])
        #expect(ReplySegmenter(configuration: custom).segments("One two. Three four. Five six.")
                == ["One two.", "Three four.", "Five six."])
        #expect(ReplySegmenter(configuration: custom).segments("one two three four five six")
                == ["one two three four", "five six"])
    }

    @Test func validatedBounds() throws {
        for invalid in [0, -1, 21, Int.max] {
            #expect(throws: (any Error).self) { try ReplySegmentation(maxSentences: invalid) }
        }
        for invalid in [0, -1, 301, Int.max] {
            #expect(throws: (any Error).self) { try ReplySegmentation(maxWords: invalid) }
        }
        for raw in ["", "-1", "1.5", " 2", "x", "999999999999999999999", "٠٢"] {
            #expect(throws: (any Error).self) {
                try ReplySegmentation.load(environment: ["HAILD_REPLY_SEGMENT_MAX_WORDS": raw])
            }
            #expect(throws: (any Error).self) {
                try ReplySegmentation.load(environment: ["HAILD_REPLY_SEGMENT_MAX_SENTENCES": raw])
            }
        }
        #expect(try ReplySegmentation(maxSentences: 20, maxWords: 300).maxWords == 300)
        #expect(try ReplySegmentation(maxSentences: 1, maxWords: 1).maxWords == 1)
    }

    @Test func abbreviationsDecimalsVersionsURLsAndPaths() throws {
        let segmenter = ReplySegmenter(configuration: try ReplySegmentation(maxSentences: 1))
        let sentence = "Dr. Example uses e.g. U.S. v3.5.1 at https://example.invalid/a.b and /tmp/a.txt for 3.5 units."
        #expect(segmenter.segments(sentence + " Next sentence.") == [sentence, "Next sentence."])
        #expect(segmenter.segments("A. Example uses i.e. small words. Done!")
                == ["A. Example uses i.e. small words.", "Done!"])
    }

    @Test func punctuationEllipsesAndClosers() throws {
        let segmenter = ReplySegmenter(configuration: try ReplySegmentation(maxSentences: 1))
        #expect(segmenter.segments("Wait... maybe later. Really? Yes! “Done.” (Again.) [End.] {Last.}")
                == ["Wait... maybe later.", "Really?", "Yes!", "“Done.”", "(Again.)", "[End.]", "{Last.}"])
        #expect(segmenter.segments("Wait... Next thought. Done…") == ["Wait...", "Next thought.", "Done…"])
        #expect(segmenter.segments("Wait… Next thought.") == ["Wait…", "Next thought."])
        #expect(segmenter.segments("Wait... “Next.”") == ["Wait...", "“Next.”"])
    }

    @Test func newlinesAndLists() throws {
        let segmenter = ReplySegmenter(configuration: try ReplySegmentation(maxSentences: 1))
        #expect(segmenter.segments("1. first item\n2. second item\n\n- third item\r\n• fourth item")
                == ["1. first item", "2. second item", "- third item", "• fourth item"])
    }

    @Test func lastClauseWithinLimitThenWords() throws {
        let segmenter = ReplySegmenter(configuration: try ReplySegmentation(maxWords: 5))
        for punctuation in [",", ";", ":", "—"] {
            let sentence = "one\(punctuation) two three\(punctuation) four five six seven eight."
            #expect(segmenter.segments(sentence) == ["one\(punctuation) two three\(punctuation)",
                                                     "four five six seven eight."])
        }
        #expect(segmenter.segments("one two three four five six seven.")
                == ["one two three four five", "six seven."])
    }

    @Test func identityAndNoEmptySegments() throws {
        let segmenter = ReplySegmenter(configuration: try ReplySegmentation())
        for text in ["A short sentence.", "  First.\t Second! \n", "one", "A  repeated   space."] {
            #expect(segmenter.segments(text) == [text])
        }
        #expect(segmenter.segments("").isEmpty)
        #expect(segmenter.segments(" \t\n ").isEmpty)
        let thirty = Array(repeating: "word", count: 30).joined(separator: " ")
        #expect(segmenter.segments(thirty) == [thirty])
        #expect(segmenter.segments(thirty + " extra").count == 2)
    }

    @Test func generatedSentencesPreserveJoinAndBounds() throws {
        // Small exhaustive deterministic property test; no random seed, logs or content-bearing diagnostics.
        for sentenceLimit in 1...3 {
            for wordLimit in 1...9 {
                let segmenter = ReplySegmenter(configuration: try ReplySegmentation(
                    maxSentences: sentenceLimit, maxWords: wordLimit
                ))
                for count in 1...12 {
                    let text = (0..<count).map { index in
                        Array(repeating: "word", count: 1 + index % 11).joined(separator: " ") + "."
                    }.joined(separator: " \n ")
                    let pieces = segmenter.segments(text)
                    #expect(!pieces.isEmpty)
                    #expect(pieces.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    #expect(pieces.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= wordLimit })
                    #expect(pieces.allSatisfy { $0.filter { $0 == "." }.count <= sentenceLimit })
                    #expect(pieces.joined(separator: " ").split(whereSeparator: \.isWhitespace)
                            == text.split(whereSeparator: \.isWhitespace))
                    #expect(segmenter.segments(text) == pieces)
                }
            }
        }
    }
}
