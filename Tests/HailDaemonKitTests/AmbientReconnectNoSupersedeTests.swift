import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Host half of the #904 resumed-stream test: a new connection must leave another device's stream untouched.
@Suite struct AmbientReconnectNoSupersedeTests {
    @Test func freshConnectionResumeCannotSupersedeAnotherDevice() async {
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let dropped = UUID()
        let holder = UUID()
        let restored = UUID()
        let heldStream = UUID()
        _ = await gate.admission(ambientSegment(stream: UUID(), sequence: 0), frameTarget: "tmux:a",
                                 selectedTarget: "tmux:a", connection: dropped, device: "phone")
        await gate.end(connection: dropped)
        #expect(await gate.admission(ambientSegment(stream: heldStream, sequence: 0), frameTarget: "tmux:a",
                                     selectedTarget: "tmux:a", connection: holder, device: "pad") == .admitted)
        var resume = ambientSegment(stream: UUID(), sequence: 0)
        resume.isResume = true
        let before = sink.endings
        #expect(await gate.admission(resume, frameTarget: "tmux:a", selectedTarget: "tmux:a",
                                     connection: restored, device: "phone")
            == .refused(.notAllowed, "ambient moved to pad"))
        #expect(await gate.activeStream == heldStream)
        #expect(sink.endings == before)
    }
}
