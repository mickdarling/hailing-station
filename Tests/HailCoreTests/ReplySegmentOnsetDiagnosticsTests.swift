import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import HailCore

@Suite struct ReplySegmentOnsetDiagnosticsTests {
    @Test func histogramBoundariesAreCountsOnly() {
        var histogram = ReplyOnsetHistogram()
        for level in [-Double.infinity, -61, -60, -45.1, -45, -35.1, -35, -25.1, -25, 0] {
            histogram.record(level)
        }
        #expect(histogram.counts == [2, 2, 2, 2, 2])
    }

    @Test(arguments: [-65.0, -50, -40, -30, -20])
    func floorAndAnalysedLevelHistograms(_ floor: Double) throws {
        let fixture = OnsetFixture()
        try fixture.calibrate(floor: floor)
        #expect(try !fixture.feed(floor))
        var expected = ReplyOnsetHistogram()
        expected.record(floor)
        #expect(fixture.gate.diagnostics.floors.counts == expected.counts)
        #expect(fixture.gate.diagnostics.levels.counts == expected.counts.map { $0 * 10 })
        #expect(fixture.gate.diagnostics.onsets == 0)
    }

    @Test func fiveSecondDeadlineUsesInjectedClockEvenAfterWindowCloses() throws {
        let fixture = OnsetFixture()
        try fixture.calibrate()
        #expect(try fixture.feed(-35, seconds: 0.3))
        fixture.gate.closeWindow()
        fixture.clock.advance(by: .milliseconds(4_999))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 0)
        fixture.clock.advance(by: .milliseconds(1))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
        fixture.gate.ambientRequestAdmitted() // Late admission cannot erase the expired outcome.
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
        #expect(fixture.gate.diagnostics.onsets == 1)
    }

    @Test func admittedRequestBeforeDeadlineSatisfiesPendingOnset() throws {
        let fixture = OnsetFixture()
        fixture.gate.ambientRequestAdmitted() // Earlier requests cannot satisfy a future onset.
        try fixture.calibrate()
        #expect(try fixture.feed(-35, seconds: 0.3))
        fixture.clock.advance(by: .milliseconds(4_999))
        fixture.gate.ambientRequestAdmitted()
        fixture.clock.advance(by: .seconds(20))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 0)
    }

    @Test func successiveWindowsKeepIndependentDeadlines() throws {
        let fixture = OnsetFixture()
        for _ in 0..<2 {
            fixture.open()
            try fixture.calibrate()
            #expect(try fixture.feed(-35, seconds: 0.3))
            fixture.gate.closeWindow()
        }
        fixture.clock.advance(by: .milliseconds(4_100))
        #expect(fixture.gate.diagnostics.onsets == 2)
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
        fixture.gate.ambientRequestAdmitted()
        fixture.clock.advance(by: .seconds(5))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
    }

    @MainActor
    @Test func existingCaptureTapObservesBeforeMaskingAndOnlyWhenOptedIn() async throws {
        let fixture = OnsetFixture()
        let calls = Mutex(0)
        let authorization = Mutex(fixture.input)
        fixture.guarder.configureSegmentOnset(input: { authorization.withLock { $0 } }, onOnset: {
            calls.withLock { $0 += 1 }
        })
        fixture.guarder.setReplyAudible(true)
        let capture = FakeAudioCapture()
        let masked = fixture.guarder.masking(capture)
        let stream = try masked.start()
        var iterator = stream.makeAsyncIterator()
        for index in 0..<9 {
            let level = index < 4 ? 0.0 : index < 6 ? -50.0 : -35.0
            fixture.clock.advance(by: .milliseconds(100))
            try capture.yield(onsetPCM(level))
            let received = try #require(await iterator.next())
            let samples = try #require(received.pcmBuffer.floatChannelData?[0])
            #expect((0..<Int(received.pcmBuffer.frameLength)).allSatisfy { samples[$0] == 0 })
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(fixture.guarder.isMasking)
        masked.stop()
        fixture.guarder.stopSegmentOnset()
        fixture.open()
        authorization.withLock { $0 = fixture.input }
        for _ in 0..<10 {
            fixture.clock.advance(by: .milliseconds(100))
            fixture.guarder.observeSegmentOnset(try onsetPCM(0))
        }
        #expect(calls.withLock { $0 } == 1)
    }
}
