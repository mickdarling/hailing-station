import Foundation
import HailCore
import HailProtocol
import Testing
@testable import haild
@testable import HailCoaching

@MainActor private final class AuthoredSpeechSource: CoachingSpeechSource {
    var chunks: [Data] = []
    var cancelled = 0, cleanups: [Bool] = [], finishes = 0
    var duringConsume: (() -> Void)?
    var afterChunk: (() -> Void)?
    var cleanupWait: CheckedContinuation<Void, Never>?
    var delayCleanup = false, failFinish = false, failCleanup = false
    func consume(_ receive: (Data) throws -> Void) async throws {
        duringConsume?()
        for chunk in chunks { try receive(chunk); afterChunk?() }
    }
    func finish() async throws {
        finishes += 1
        if failFinish { throw ForegroundCoachingError.invalidSpeech }
    }
    func cancel() { cancelled += 1 }
    func cleanup(cancel: Bool) async throws {
        cleanups.append(cancel)
        if delayCleanup { await withCheckedContinuation { cleanupWait = $0 } }
        if failCleanup { throw ForegroundCoachingError.invalidSpeech }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct CoachingSpeechRendererTests {
    @Test func completePCMRetainsOrderAndWaitsForOwnedCleanupBeforeAnyEmission() async throws {
        let source = AuthoredSpeechSource(); source.chunks = [Data([17]), Data([0, 18, 0]), Data([19, 0])]
        var output: [AudioPayload] = []
        source.afterChunk = { #expect(output.isEmpty) }
        let renderer = CoachingSpeechRenderer(source: { _ in source })
        try await renderer.render("authored suggestion") { payload in
            #expect(source.finishes == 1 && source.cleanups == [false])
            output.append(payload)
        }
        #expect(output.count == 1 && output[0].sequence == 0 && output[0].isFinal)
        #expect(output[0].bytes == Data([17, 0, 18, 0, 19, 0]))
        #expect(output[0].sampleRate == 24_000 && output[0].channels == 1 && output[0].codec == .pcm16)
    }

    @Test func validPhraseLongerThanTwoSecondsEmitsWholeAndTwelveSecondsIsTheHardBound() async throws {
        for size in [134_144, CoachingSpeechBudget.pcmBytes] {
            let source = AuthoredSpeechSource(); source.chunks = [Data(repeating: 17, count: size)]
            let renderer = CoachingSpeechRenderer(source: { _ in source }); var output: [AudioPayload] = []
            try await renderer.render("authored longer phrase") { output.append($0) }
            #expect(output.reduce(0) { $0 + $1.bytes.count } == size)
            #expect(output.map(\.sequence) == Array(0..<output.count) && output.count <= 12)
            #expect(output.last?.isFinal == true && output.dropLast().allSatisfy { !$0.isFinal })
            #expect(source.cleanups == [false])
        }
    }

    @Test func invalidOrOverflowingCompleteSourcesNeverEmitPartialPCM() async throws {
        for chunks in [[], [Data([1])], [Data(repeating: 17, count: CoachingSpeechBudget.pcmBytes + 2)],
                       [Data(repeating: 17, count: 96_000),
                        Data(repeating: 17, count: CoachingSpeechBudget.pcmBytes - 95_998)]] {
            let source = AuthoredSpeechSource(); source.chunks = chunks
            let renderer = CoachingSpeechRenderer(source: { _ in source })
            await #expect(throws: CoachingSpeechFailure.self) {
                try await renderer.render("authored") { _ in Issue.record("Invalid partial PCM escaped") }
            }
            #expect(source.cleanups == [true] && source.cancelled == 1)
        }
    }

    @Test func cleanupFailureCannotMaskInitiatingDurationLimit() async throws {
        let source = AuthoredSpeechSource()
        source.chunks = [Data(repeating: 17, count: CoachingSpeechBudget.pcmBytes + 2)]
        source.failCleanup = true
        let renderer = CoachingSpeechRenderer(source: { _ in source })
        await #expect(throws: CoachingSpeechFailure.durationExceeded) {
            try await renderer.render("authored") { _ in Issue.record("Oversized speech escaped") }
        }
        #expect(source.cleanups == [true])
    }

    @Test func fourSecondClockOrTimeoutCallbackRejectsBeforePlayback() async throws {
        for timerFires in [false, true] {
            let source = AuthoredSpeechSource(); source.chunks = [Data([17, 0])]
            var now = ContinuousClock.now
            var fire: (() -> Void)?
            let clock = CoachingClock(now: { now }, schedule: { _, callback in fire = callback; return {} })
            source.duringConsume = { if timerFires { fire?() } else { now = now.advanced(by: .seconds(4)) } }
            let renderer = CoachingSpeechRenderer(clock: clock, source: { _ in source })
            await #expect(throws: CoachingSpeechFailure.renderTimedOut) {
                try await renderer.render("authored") { _ in Issue.record("Timed-out speech escaped") }
            }
            #expect(source.cancelled > 0 && source.cleanups.last == true)
        }
    }

    @Test func failedExitAndFailedCleanupCannotPublishPCM() async throws {
        for cleanupFailure in [false, true] {
            let source = AuthoredSpeechSource(); source.chunks = [Data([17, 0])]
            source.failFinish = !cleanupFailure; source.failCleanup = cleanupFailure
            let renderer = CoachingSpeechRenderer(source: { _ in source })
            await #expect(throws: ForegroundCoachingError.invalidSpeech) {
                try await renderer.render("authored") { _ in Issue.record("Failed source emitted") }
            }
            #expect(source.cancelled == 1 && source.cleanups.last == true)
        }
    }

    @Test func cancelledFactoryAndSuspendedCleanupRetainSlotUntilJoined() async throws {
        for duringFactory in [false, true] {
            let source = AuthoredSpeechSource(); source.chunks = [Data([17, 0])]; source.delayCleanup = true
            var owner: CoachingSpeechRenderer?
            let renderer = CoachingSpeechRenderer { _ in if duringFactory { owner?.cancel() }; return source }
            owner = renderer
            let task = Task { try await renderer.render("authored") { _ in Issue.record("Cancelled speech escaped") } }
            for _ in 0..<100 where source.cleanupWait == nil { await Task.yield() }
            #expect(source.cleanupWait != nil)
            renderer.cancel()
            await #expect(throws: ForegroundCoachingError.busy) { try await renderer.render("other") { _ in } }
            source.delayCleanup = false; source.cleanupWait?.resume(); source.cleanupWait = nil
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test func downstreamRevocationRejectsRemainingPCMAndStillJoinsCleanup() async throws {
        let source = AuthoredSpeechSource(); source.chunks = [Data(repeating: 17, count: 96_000)]
        let renderer = CoachingSpeechRenderer(source: { _ in source }); var effects = 0
        await #expect(throws: CancellationError.self) {
            try await renderer.render("authored") { _ in effects += 1; renderer.cancel() }
        }
        #expect(effects == 1 && source.cleanups == [false, true] && source.finishes == 1)
    }

    @Test func invalidTextNeverConstructsSource() async throws {
        var starts = 0
        let renderer = CoachingSpeechRenderer { _ in starts += 1; return AuthoredSpeechSource() }
        for text in ["", "   ", "authored\ncontrol", "hidden\u{200b}format", "non\u{00a0}breaking",
                     "line\u{2028}separator", String(repeating: "a", count: 281),
                     Array(repeating: "a", count: 46).joined(separator: " ")] {
            await #expect(throws: ForegroundCoachingError.invalidSpeech) {
                try await renderer.render(text) { _ in }
            }
        }
        #expect(starts == 0)
    }
}
