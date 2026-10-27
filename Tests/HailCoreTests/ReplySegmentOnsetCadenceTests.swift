import AVFAudio
import Foundation
import Testing
@testable import HailCore

@Suite struct ReplySegmentOnsetCadenceTests {
    @Test(arguments: [16_000.0, 44_100, 48_000], [160, 256, 512, 1024, 4800])
    func calibrationAndOnsetUseExactSampleCounts(_ rate: Double, _ size: Int) throws {
        let fixture = OnsetFixture(tail: .zero, length: 3)
        let calibration = Int(rate * 0.2)
        let required = Int(rate * 0.3)
        let start = fixture.clock.now
        var total = 0
        var fired = false
        while total < calibration + required + size * 2 {
            let buffer = try onsetPCM(-35, seconds: Double(size) / rate, rate: rate)
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<size where total + index < calibration { samples[index] = Float(pow(10, -50.0 / 20)) }
            total += size
            let end = start.advanced(by: .seconds(Double(total) / rate))
            fixture.clock.advance(by: fixture.clock.now.duration(to: end))
            let onset = fixture.gate.analyse(buffer, input: fixture.input)
            #expect(onset == (!fired && total >= calibration + required))
            fired = fired || onset
            if total >= calibration { #expect(fixture.gate.diagnostics.floors.counts == [0, 1, 0, 0, 0]) }
        }
        #expect(fired)
        #expect(fixture.gate.diagnostics.onsets == 1)
    }

    @Test func oneMillisecondFullScaleClickInLongBufferNeverFires() throws {
        let fixture = OnsetFixture()
        try fixture.calibrate()
        let buffer = try onsetPCM(-Double.infinity, seconds: 0.3)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48 { samples[index] = 1 }
        fixture.clock.advance(by: .milliseconds(300))
        #expect(!fixture.gate.analyse(buffer, input: fixture.input))
        #expect(fixture.gate.diagnostics.onsets == 0)
        #expect(try !fixture.feed(-35, seconds: 0.29))
    }

    @Test func continuousSpeechInLongBufferFires() throws {
        let fixture = OnsetFixture()
        try fixture.calibrate()
        #expect(try fixture.feed(-35, seconds: 0.3))
        #expect(fixture.gate.diagnostics.onsets == 1)
    }

    @Test func gapWithinLongBufferBreaksConsecutiveSustain() throws {
        let fixture = OnsetFixture()
        try fixture.calibrate()
        let buffer = try onsetPCM(-20, seconds: 0.32)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 7200..<8160 { samples[index] = 0 } // 150 ms + 20 ms gap + 150 ms.
        fixture.clock.advance(by: .milliseconds(320))
        #expect(!fixture.gate.analyse(buffer, input: fixture.input))
        #expect(fixture.gate.diagnostics.onsets == 0)
        #expect(try !fixture.feed(-20, seconds: 0.14))
        #expect(try fixture.feed(-20, seconds: 0.01))
    }
}
