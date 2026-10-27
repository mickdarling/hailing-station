import AVFAudio
import Foundation
import Testing
@testable import HailCore

@Suite struct ReplySegmentOnsetTests {
    @Test(arguments: [-35.0, -30, -20])
    func sustainedThresholdFiresOnceAndKeepsMask(_ level: Double) throws {
        let fixture = OnsetFixture()
        fixture.guarder.setReplyAudible(true)
        try fixture.calibrate()
        #expect(try !fixture.feed(level, seconds: 0.299))
        #expect(try fixture.feed(level, seconds: 0.001))
        #expect(try !fixture.feed(level))
        #expect(fixture.gate.diagnostics.onsets == 1)
        #expect(fixture.guarder.isMasking)
    }

    @Test func thresholdAndMarginAreBothRequired() throws {
        let fixture = OnsetFixture()
        try fixture.calibrate(floor: -45)
        #expect(try !fixture.feed(-36, seconds: 0.3)) // Above floor+6, below absolute threshold.
        #expect(try fixture.feed(-35, seconds: 0.3))
    }

    @Test func shortBurstAndInterruptedBurstsNeverAccumulate() throws {
        let fixture = OnsetFixture(length: 3)
        try fixture.calibrate()
        #expect(try !fixture.feed(-20, seconds: 0.299))
        #expect(try !fixture.feed(-50, seconds: 0.001))
        #expect(try !fixture.feed(-20, seconds: 0.299))
        #expect(try !fixture.feed(-50, seconds: 0.1))
        #expect(fixture.gate.diagnostics.onsets == 0)
    }

    @Test func loudTVFloorRequiresSixDBRise() throws {
        let fixture = OnsetFixture(length: 3)
        try fixture.calibrate(floor: -30)
        #expect(try !fixture.feed(-30, seconds: 0.5))
        #expect(try !fixture.feed(-24.1, seconds: 0.3))
        #expect(try fixture.feed(-24, seconds: 0.3))
    }

    @Test func calibrationIsAfterTailAndNeverAnOnset() throws {
        let fixture = OnsetFixture()
        #expect(try !fixture.feed(0, seconds: 0.4))
        #expect(fixture.gate.diagnostics.floors.counts == [0, 0, 0, 0, 0])
        #expect(try !fixture.feed(-30, seconds: 0.2))
        #expect(fixture.gate.diagnostics.floors.counts == [0, 0, 0, 1, 0])
        #expect(try !fixture.feed(-30, seconds: 0.3))
        #expect(try fixture.feed(-24, seconds: 0.3))
    }

    @Test func bufferCrossingTailExcludesEchoSamplesFromFloor() throws {
        let fixture = OnsetFixture()
        let buffer = try onsetPCM(-50, seconds: 0.7)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<19_200 { samples[index] = 1 } // First 400 ms is reply echo.
        fixture.clock.advance(by: .milliseconds(700))
        #expect(!fixture.gate.analyse(buffer, input: fixture.input))
        #expect(fixture.gate.diagnostics.floors.counts == [0, 1, 0, 0, 0])
        #expect(try fixture.feed(-35, seconds: 0.3))
    }

    @Test func nonDefaultTailComesFromGuard() throws {
        let fixture = OnsetFixture(tail: .milliseconds(700), length: 2)
        #expect(try !fixture.feed(0, seconds: 0.7))
        #expect(try !fixture.feed(-50, seconds: 0.2))
        #expect(try fixture.feed(-35, seconds: 0.3))
    }

    @Test func exactMinimumWindowFitsButDuplicatePCMDoesNotAccumulate() throws {
        let fixture = OnsetFixture(length: 0.9)
        try fixture.calibrate()
        let buffer = try onsetPCM(-35, seconds: 0.2)
        fixture.clock.advance(by: .milliseconds(200))
        #expect(!fixture.gate.analyse(buffer, input: fixture.input))
        #expect(!fixture.gate.analyse(buffer, input: fixture.input))
        #expect(try fixture.feed(-35, seconds: 0.1))
    }

    @Test(arguments: [0.4, 0.6, 0.899])
    func tooShortWindowNeverFires(_ length: Double) throws {
        let fixture = OnsetFixture(length: length)
        for index in 0..<15 {
            let level = index < 4 ? 0.0 : index < 6 ? -50.0 : -20.0
            #expect(try !fixture.feed(level))
        }
        #expect(fixture.gate.diagnostics.onsets == 0)
    }

    @Test(arguments: [0, 1, 2])
    func freshAuthorizationRefusesLoudPCM(_ mode: Int) throws {
        let fixture = OnsetFixture(length: 3)
        try fixture.calibrate()
        #expect(try !fixture.feed(-20, seconds: 0.2))
        if mode == 0 { fixture.window = nil }
        if mode == 1 { fixture.privacy = true }
        if mode == 2 { fixture.ambient = false }
        for _ in 0..<5 { #expect(try !fixture.feed(0)) }
        #expect(fixture.gate.diagnostics.onsets == 0)
        #expect(fixture.gate.diagnostics.levels.counts == [0, 0, 0, 0, 1])
        fixture.privacy = false
        fixture.ambient = true
        fixture.open()
        try fixture.calibrate()
        #expect(try !fixture.feed(-20, seconds: 0.299))
        #expect(try fixture.feed(-20, seconds: 0.001))
    }

    @Test func closeDiscardsFloorAndSustainWithoutRetainingPCM() throws {
        let fixture = OnsetFixture(length: 3)
        try fixture.calibrate(floor: -30)
        #expect(try !fixture.feed(-20, seconds: 0.2))
        fixture.gate.closeWindow()
        fixture.open()
        weak var released: AVAudioPCMBuffer?
        do {
            let buffer = try onsetPCM(0, seconds: 0.4)
            released = buffer
            fixture.clock.advance(by: .milliseconds(400))
            #expect(!fixture.gate.analyse(buffer, input: fixture.input))
        }
        #expect(released == nil)
        #expect(try !fixture.feed(-50, seconds: 0.2))
        #expect(try !fixture.feed(-35, seconds: 0.299))
        #expect(try fixture.feed(-35, seconds: 0.001))
    }

    @Test func missingOrInvalidCaptureBreaksSustain() throws {
        let fixture = OnsetFixture(length: 3)
        try fixture.calibrate()
        #expect(try !fixture.feed(-20, seconds: 0.2))
        fixture.clock.advance(by: .milliseconds(100))
        #expect(try !fixture.feed(-20, seconds: 0.2))
        #expect(try !fixture.feed(.nan))
        #expect(try !fixture.feed(-20, seconds: 0.2))
        #expect(try fixture.feed(-20, seconds: 0.1))
    }
}
