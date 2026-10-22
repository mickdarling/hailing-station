import Foundation
import Testing
@testable import HailDaemonKit

/// H-2 and normal mode are unchanged by the duck buffer (#735 H-3): with duck mode off, or without a buffer, every
/// path behaves as before H-3, and H-2's transcript exit still exits. Synthetic text only.
extension RightyoInputConsumerTests {
    /// While duck mode is off, nothing is buffered and a cue-shaped request is typed exactly as before H-3.
    @Test func outsideDuckModeNothingIsBufferedAndCuesAreOrdinaryRequests() async throws {
        let session = DuckSession()
        let consumer = try duckConsumer(ducking: false, session: session, dispatcher: RecordingDispatcher())
        _ = try await consumer.consume(duckStart())
        try await say(["Owner synthetic words.", "What do you think?", "Discard that."], to: consumer)
        #expect(await consumer.lastDuckCue == nil && session.snapshot.turns.isEmpty)
        // A request says the same cue: the request path is unchanged, so it is typed with the ordinary block.
        let dispatcher = RecordingDispatcher()
        let plain = try duckConsumer(ducking: false, session: session, dispatcher: dispatcher)
        _ = try await plain.consume(start())
        var turn = self.turn()
        turn["text"] = "What do you think?"
        #expect(try await plain.consume(preparedRequest(plain, customTurn: turn)))
        let text = try #require(await dispatcher.calls.first?.text)
        #expect(text.hasSuffix(Self.replyBlock) && !text.contains(RightyoInputEvent.duckInstruction))
    }

    /// H-2's exit from the owner's transcript is unchanged with a buffer attached: still `.off`, never buffered.
    @Test func theTranscriptExitStillExitsAndIsNotBuffered() async throws {
        let session = DuckSession()
        let consumer = try duckConsumer(session: session, dispatcher: RecordingDispatcher())
        _ = try await consumer.consume(duckStart())
        #expect(try await !consumer.consume(duckTurn("Rightyo, done thinking.", sequence: 2)))
        #expect(await consumer.lastVoiceDuck == .off)
        #expect(await consumer.lastDuckCue == nil)
        #expect(session.snapshot.turns.isEmpty)
    }

    /// Without a buffer (H-2 alone) a ducking consumer treats cues as plain transcripts: nothing is sent.
    @Test func withoutABufferCuesDoNothing() async throws {
        let dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(session: nil, dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        try await say(["What do you think?", "Mute."], to: consumer)
        #expect(await dispatcher.calls.isEmpty)
        #expect(await consumer.lastVoiceMute == nil)
    }

    /// On an anonymous session no voice can be told apart, so nothing is buffered and no cue counts, even ducking.
    @Test func anAnonymousSessionNeverBuffersOrCues() async throws {
        let session = DuckSession(), dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(session: session, dispatcher: dispatcher)
        _ = try await consumer.consume(start())
        try await say(["Synthetic words.", "What do you think?"], to: consumer, role: nil)
        #expect(await dispatcher.calls.isEmpty)
        #expect(session.snapshot.turns.isEmpty)
    }
}
