import Foundation
import Testing
@testable import HailCore

/// Synthetic tail safety and P4b2 handoff coverage; no physical audio.
@MainActor
@Suite struct ReplySegmentEchoTailYieldTests {
    @Test func audibleReplyCannotReleaseItsMask() throws {
        let fixture = OnsetFixture(length: 5)
        fixture.guarder.setReplyAudible(true)
        #expect(try !fixture.feed(-50, seconds: 1))
        #expect(!fixture.guarder.endReplyTailForYield())
        #expect(fixture.guarder.isMasking)
    }

    @Test(arguments: [0.05, 0.3, 2.0], [Duration.zero, .milliseconds(400), .milliseconds(700)])
    func exactSafeDeadlineUsesConfiguredTailAndOnset(_ onset: Double, _ tail: Duration) throws {
        let fixture = OnsetFixture(tail: tail, length: 5)
        fixture.settings = .init(sustainedOnset: onset)
        fixture.guarder.setReplyAudible(true)
        fixture.guarder.setReplyAudible(false)
        #expect(try !fixture.feed(-50, seconds: 0.001))
        let remaining = tail + .milliseconds(200) + .seconds(onset) - .milliseconds(1)
        fixture.clock.advance(by: remaining - .nanoseconds(1))
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.clock.advance(by: .nanoseconds(1))
        #expect(fixture.guarder.endReplyTailForYield())
        #expect(!fixture.guarder.isMasking)
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.clock.advance(by: .milliseconds(1))
        #expect(!fixture.guarder.endReplyTailForYield())
    }

    @Test func replyQuietEdgeMustAlsoBeOldEnough() throws {
        let fixture = OnsetFixture(length: 5)
        fixture.guarder.setReplyAudible(true)
        #expect(try !fixture.feed(-50, seconds: 1))
        fixture.guarder.setReplyAudible(false)
        #expect(!fixture.guarder.endReplyTailForYield())
        #expect(fixture.guarder.isMasking)
        fixture.clock.advance(by: .milliseconds(899))
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.clock.advance(by: .milliseconds(1))
        #expect(fixture.guarder.endReplyTailForYield())
    }

    @Test func windowMustAlsoBeOldEnough() throws {
        let fixture = OnsetFixture(length: 5)
        fixture.guarder.setReplyAudible(true)
        fixture.guarder.setReplyAudible(false)
        fixture.clock.advance(by: .seconds(1))
        fixture.open(length: 5)
        #expect(try !fixture.feed(-50, seconds: 0.899))
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.clock.advance(by: .milliseconds(1))
        #expect(fixture.guarder.endReplyTailForYield())
    }

    @Test(arguments: [false, true])
    func tapActiveAndTapQuietTailAreUntouched(_ active: Bool) throws {
        let fixture = OnsetFixture(length: 5)
        fixture.guarder.setReplyAudible(true)
        fixture.guarder.setReplyAudible(false)
        #expect(try !fixture.feed(-50, seconds: 0.9))
        fixture.guarder.setTapCaptureActive(true)
        if !active { fixture.guarder.setTapCaptureActive(false) }
        #expect(fixture.guarder.endReplyTailForYield())
        #expect(fixture.guarder.isMasking)
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.clock.advance(by: .milliseconds(399))
        #expect(fixture.guarder.isMasking)
        fixture.clock.advance(by: .milliseconds(1))
        #expect(fixture.guarder.isMasking == active)
        if active {
            fixture.guarder.setTapCaptureActive(false)
            fixture.clock.advance(by: .milliseconds(399))
            #expect(fixture.guarder.isMasking)
            fixture.clock.advance(by: .milliseconds(1))
            #expect(!fixture.guarder.isMasking)
        }
    }

    @Test func nextReplyRemasksOnItsFirstAudibleFrameAndKeepsItsOwnTail() throws {
        let fixture = OnsetFixture(length: 5)
        fixture.guarder.setReplyAudible(true)
        fixture.guarder.setReplyAudible(false)
        #expect(try !fixture.feed(-50, seconds: 0.9))
        #expect(fixture.guarder.endReplyTailForYield())
        fixture.guarder.setReplyAudible(false) // A repeated idle observation cannot restore the retired tail.
        #expect(!fixture.guarder.isMasking)
        fixture.guarder.setReplyAudible(true)
        #expect(fixture.guarder.isMasking)
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.guarder.setReplyAudible(false)
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.clock.advance(by: .milliseconds(399))
        #expect(fixture.guarder.isMasking)
        fixture.clock.advance(by: .milliseconds(1))
        #expect(!fixture.guarder.isMasking)
    }

    @Test func missingClosedOrExpiredWindowCannotRetireATail() throws {
        let fixture = OnsetFixture()
        #expect(!fixture.guarder.endReplyTailForYield())
        fixture.guarder.setReplyAudible(true)
        fixture.guarder.setReplyAudible(false)
        fixture.clock.advance(by: .seconds(1))
        #expect(!fixture.guarder.endReplyTailForYield()) // No analysed window/settings.
        #expect(try !fixture.feed(-50, seconds: 0.001))
        fixture.gate.closeWindow()
        #expect(!fixture.guarder.endReplyTailForYield())
        #expect(try !fixture.feed(-50, seconds: 0.001))
        fixture.clock.advance(by: .seconds(1))
        #expect(!fixture.guarder.endReplyTailForYield())
    }
}

@MainActor @Suite struct ReplySegmentWiredTailTests {
    @Test(arguments: [false, true])
    func safeTailReleasePrecedesWindowCloseAndPreservesTapMask(_ active: Bool) async throws {
        let fixture = SegmentWireFixture()
        try await fixture.open()
        fixture.guarder.setReplyAudible(true)
        fixture.guarder.setReplyAudible(false)
        try await fixture.calibrate()
        fixture.guarder.setTapCaptureActive(true)
        if !active { fixture.guarder.setTapCaptureActive(false) }
        try await fixture.feed(-20, seconds: 0.3)
        #expect(fixture.controller.lastSegmentYield != nil)
        // The safe API can return true only while the analysed window still exists.
        #expect(fixture.store.segmentWiring?.lastTailReleased == true)
        #expect(fixture.store.segmentWiring?.captureInput().window == nil)
        #expect(!fixture.guarder.endReplyTailForYield())
        #expect(fixture.guarder.isMasking)
        fixture.clock.advance(by: .milliseconds(99))
        #expect(fixture.guarder.isMasking)
        fixture.clock.advance(by: .milliseconds(1))
        #expect(fixture.guarder.isMasking == active)
    }

    @Test func unsafeReleaseKeepsTheNormalReplyTail() async throws {
        let fixture = SegmentWireFixture()
        try await fixture.open()
        fixture.guarder.setReplyAudible(true)
        try await fixture.detect()
        #expect(fixture.controller.lastSegmentYield != nil)
        #expect(fixture.store.segmentWiring?.lastTailReleased == false)
        #expect(fixture.guarder.isMasking)
        fixture.clock.advance(by: .milliseconds(399))
        #expect(fixture.guarder.isMasking)
        fixture.clock.advance(by: .milliseconds(1))
        #expect(!fixture.guarder.isMasking)
    }

    @Test(arguments: [false, true])
    func unauthorizedCaptureDoesNotDetectOrYield(_ privacy: Bool) async throws {
        let fixture = SegmentWireFixture()
        try await fixture.open()
        if privacy { fixture.privacy = true } else { fixture.ambient = false }
        try await fixture.detect()
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.onsets == 0)
        #expect(fixture.controller.lastSegmentYield == nil)
        #expect(fixture.store.segmentWiring?.lastTailReleased == nil)
        #expect(fixture.player.cancelCount == 0)
    }
}
