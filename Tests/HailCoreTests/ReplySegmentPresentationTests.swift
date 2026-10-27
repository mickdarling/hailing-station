import Foundation
import Testing
@testable import HailCore

@Suite struct ReplySegmentPresentationTests {
    private func yield(id: UInt64 = 1) -> ReplySegmentYieldEvent {
        ReplySegmentYieldEvent(id: id, endpointID: "synthetic", replyID: UUID(), segment: 1)
    }

    @Test func noticeTextContainsNoReplyContent() {
        #expect(ReplySegmentNotice.text == "Paused — go ahead")
        #expect(ReplySegmentNotice.lifetime == .seconds(4))
        var notice = ReplySegmentNotice()
        #expect(!notice.isVisible)
        let announcement1 = notice.observe(nil, at: .now, voiceOverRunning: true)
        #expect(!announcement1)
        #expect(!notice.isVisible)
    }

    @Test func announcesOnceDespiteRepeatedUpdatesDismissalAndTimeout() {
        let event = yield(), now = ContinuousClock.now
        var notice = ReplySegmentNotice()
        let announcement2 = notice.observe(event, at: now, voiceOverRunning: true)
        #expect(announcement2)
        #expect(notice.isVisible)
        let announcement3 = notice.observe(event, at: now, voiceOverRunning: true)
        #expect(!announcement3)
        #expect(notice.deadline == now.advanced(by: .seconds(4)))
        notice.dismiss()
        #expect(!notice.isVisible)
        let announcement4 = notice.observe(event, at: now, voiceOverRunning: true)
        #expect(!announcement4)
        let announcement5 = notice.observe(nil, at: now, voiceOverRunning: true)
        #expect(!announcement5)
        let announcement6 = notice.observe(event, at: now, voiceOverRunning: true)
        #expect(!announcement6)
        #expect(!notice.isVisible)
        let announcement7 = notice.observe(yield(id: 2), at: now, voiceOverRunning: true)
        #expect(announcement7)
        notice.expire(at: now.advanced(by: .seconds(4)))
        #expect(!notice.isVisible)
    }

    @Test func enablingVoiceOverDoesNotReannounceAnOldEvent() {
        let event = yield(), now = ContinuousClock.now
        var notice = ReplySegmentNotice()
        let announcement8 = notice.observe(event, at: now, voiceOverRunning: false)
        #expect(!announcement8)
        #expect(notice.isVisible)
        let announcement9 = notice.observe(event, at: now, voiceOverRunning: true)
        #expect(!announcement9)
        notice.expire(at: now.advanced(by: .seconds(4)))
        let announcement10 = notice.observe(event, at: now.advanced(by: .seconds(5)), voiceOverRunning: true)
        #expect(!announcement10)
        #expect(!notice.isVisible)
    }

    @Test func timeoutBoundaryAndStaleTimeoutKeepNewerNotice() {
        let now = ContinuousClock.now
        var notice = ReplySegmentNotice()
        let announcement11 = notice.observe(yield(), at: now, voiceOverRunning: true)
        #expect(announcement11)
        notice.expire(at: now.advanced(by: .seconds(4) - .nanoseconds(1)))
        #expect(notice.isVisible)
        let announcement12 = notice.observe(yield(id: 2), at: now.advanced(by: .seconds(3)), voiceOverRunning: true)
        #expect(announcement12)
        notice.expire(at: now.advanced(by: .seconds(4)))
        #expect(notice.isVisible)
        notice.expire(at: now.advanced(by: .seconds(7)))
        #expect(!notice.isVisible)
    }

    @Test func identicalYieldsAfterReplayEachShowAndAnnounceOnce() {
        let first = yield(), now = ContinuousClock.now
        let replay = ReplySegmentYieldEvent(id: first.id + 1, endpointID: first.endpointID,
                                           replyID: first.replyID, segment: first.segment)
        var notice = ReplySegmentNotice()
        for (index, event) in [first, replay].enumerated() {
            let instant = now.advanced(by: .seconds(index))
            let announcement = notice.observe(event, at: instant, voiceOverRunning: true)
            #expect(announcement)
            #expect(notice.isVisible)
            #expect(notice.deadline == instant.advanced(by: ReplySegmentNotice.lifetime))
            let duplicate = notice.observe(event, at: instant, voiceOverRunning: true)
            #expect(!duplicate)
            notice.dismiss()
            let afterDismissal = notice.observe(event, at: instant, voiceOverRunning: true)
            #expect(!afterDismissal)
            #expect(!notice.isVisible)
        }
    }

    @Test func eventIDAloneControlsNoticeIdentity() {
        let first = yield(), now = ContinuousClock.now
        let changedPayload = ReplySegmentYieldEvent(id: first.id, endpointID: "other", replyID: UUID(), segment: 2)
        var notice = ReplySegmentNotice()
        let announcement = notice.observe(first, at: now, voiceOverRunning: true)
        #expect(announcement)
        notice.dismiss()
        let duplicate = notice.observe(changedPayload, at: now, voiceOverRunning: true)
        #expect(!duplicate)
        #expect(!notice.isVisible)
    }
}

/// Station tools bindings and diagnostics formatting for reply segments (#932).
@Suite struct ReplySegmentSettingsPresentationTests {
    @Test func settingsBindingsExposeInclusiveBoundsAndDefaults() {
        #expect(ReplySegmentSetting.pause.bounds == 0.1...10)
        #expect(ReplySegmentSetting.threshold.bounds == -60 ... -15)
        let defaults = ReplySegmentSettings()
        #expect(ReplySegmentSetting.pause.value(in: defaults) == 1.5)
        #expect(ReplySegmentSetting.threshold.value(in: defaults) == -35)
        for value in [0.1, 10] {
            #expect(ReplySegmentSetting.pause.updating(defaults, to: value).pauseAfterSegment == value)
        }
        for value in [-60.0, -15] {
            #expect(ReplySegmentSetting.threshold.updating(defaults, to: value).onsetThresholdDBFS == value)
        }
    }

    @Test(arguments: [-0.1, 0, 10.1, Double.infinity, -.infinity, .nan])
    func pauseBindingValidatesIndependently(_ value: Double) {
        let old = ReplySegmentSettings(pauseAfterSegment: 3, sustainedOnset: 0.7, onsetThresholdDBFS: -40)
        let new = ReplySegmentSetting.pause.updating(old, to: value)
        #expect(new == ReplySegmentSettings(pauseAfterSegment: 1.5, sustainedOnset: 0.7, onsetThresholdDBFS: -40))
    }

    @Test(arguments: [-60.1, -14.9, Double.infinity, -.infinity, .nan])
    func thresholdBindingValidatesIndependently(_ value: Double) {
        let old = ReplySegmentSettings(pauseAfterSegment: 3, sustainedOnset: 0.7, onsetThresholdDBFS: -40)
        let new = ReplySegmentSetting.threshold.updating(old, to: value)
        #expect(new == ReplySegmentSettings(pauseAfterSegment: 3, sustainedOnset: 0.7, onsetThresholdDBFS: -35))
    }

    @Test func consecutiveBindingEditsSaveAndPreserveKeys() throws {
        let suite = "ReplySegmentPresentationTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["future": 42, "sustainedOnset": 0.7], forKey: ReplySegmentSettings.defaultsKey)
        var settings = ReplySegmentSettings.saved(in: defaults)
        settings = ReplySegmentSetting.pause.updating(settings, to: 2.4)
        settings.save(in: defaults)
        settings = ReplySegmentSetting.threshold.updating(settings, to: -42)
        settings.save(in: defaults)
        #expect(ReplySegmentSettings.saved(in: defaults) == settings)
        #expect(settings.pauseAfterSegment == 2.4)
        #expect(settings.sustainedOnset == 0.7)
        #expect(settings.onsetThresholdDBFS == -42)
        #expect(defaults.dictionary(forKey: ReplySegmentSettings.defaultsKey)?["future"] as? Int == 42)
    }

    @Test func histogramFormatsAllBucketsAsPlainCounts() {
        var histogram = ReplyOnsetHistogram()
        for level in [-70.0, -60, -45, -35, -25, 0] { histogram.record(level) }
        let rows = ReplySegmentDiagnosticsPresentation.histogram(histogram)
        #expect(rows.map(\.id) == ["Below −60 dBFS", "−60 to below −45 dBFS", "−45 to below −35 dBFS",
                                  "−35 to below −25 dBFS", "−25 to 0 dBFS"])
        #expect(rows.map(\.count) == ["1", "1", "1", "1", "2"])
    }

    @Test func diagnosticsFormatRealGateCountsAndFiveSecondExpiry() throws {
        let fixture = OnsetFixture()
        let initial = ReplySegmentDiagnosticsPresentation.counters(fixture.gate.diagnostics)
        #expect(initial.map(\.id) == ["Yield signals", "No request within 5 s"])
        #expect(initial.map(\.count) == ["0", "0"])
        try fixture.calibrate()
        #expect(try fixture.feed(-35, seconds: 0.3))
        #expect(ReplySegmentDiagnosticsPresentation.counters(fixture.gate.diagnostics).map(\.count) == ["1", "0"])
        fixture.clock.advance(by: .seconds(5))
        let expired = ReplySegmentDiagnosticsPresentation.counters(fixture.gate.diagnostics)
        #expect(expired.map(\.count) == ["1", "1"])
        let floors = ReplySegmentDiagnosticsPresentation.histogram(fixture.gate.diagnostics.floors)
        #expect(floors.map(\.count) == ["0", "1", "0", "0", "0"])
    }
}
