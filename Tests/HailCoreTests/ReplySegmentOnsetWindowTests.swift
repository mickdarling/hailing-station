import Synchronization
import Testing
@testable import HailCore

@Suite struct ReplySegmentOnsetWindowTests {
    @Test func closedWindowSkipsInputBeforeOpenAfterCloseAndAfterStop() throws {
        let fixture = OnsetFixture()
        let guarder = fixture.guarder
        let input = fixture.input
        let calls = Mutex(0)
        let read: @Sendable () -> ReplySegmentOnsetInput = {
            calls.withLock { $0 += 1 }
            return input
        }
        guarder.configureSegmentOnset(input: read, onOnset: {})
        let buffer = try onsetPCM(-50)
        for _ in 0..<50 { guarder.observeSegmentOnset(buffer) }
        #expect(calls.withLock { $0 } == 0)
        fixture.gate.openWindow()
        guarder.observeSegmentOnset(buffer)
        #expect(calls.withLock { $0 } == 1)
        fixture.gate.closeWindow()
        for _ in 0..<50 { guarder.observeSegmentOnset(buffer) }
        #expect(calls.withLock { $0 } == 1)
        fixture.gate.openWindow()
        guarder.observeSegmentOnset(buffer)
        #expect(calls.withLock { $0 } == 2)
        guarder.stopSegmentOnset()
        #expect(!fixture.gate.isWindowOpen)
        for _ in 0..<50 { guarder.observeSegmentOnset(buffer) }
        #expect(calls.withLock { $0 } == 2)
        guarder.configureSegmentOnset(input: read, onOnset: {})
        for _ in 0..<50 { guarder.observeSegmentOnset(buffer) }
        #expect(calls.withLock { $0 } == 2)
        fixture.gate.openWindow()
        guarder.configureSegmentOnset(input: read, onOnset: {})
        for _ in 0..<50 { guarder.observeSegmentOnset(buffer) }
        #expect(calls.withLock { $0 } == 2)
    }
}
