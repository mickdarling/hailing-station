import Foundation
import HailCore
import HailProtocol
import Testing
@testable import haild

@MainActor private final class AuthoredSpeechSource: CoachingSpeechSource {
    var chunks: [Data] = []
    var cancelled = 0, cleanups: [Bool] = [], finishes = 0
    var duringConsume: (() -> Void)?
    var cleanupWait: CheckedContinuation<Void, Never>?
    var delayCleanup = false, failFinish = false, failCleanup = false
    func consume(_ receive: (Data) throws -> Void) async throws {
        duringConsume?()
        for chunk in chunks { try receive(chunk) }
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
    @Test func nonzeroPCMRetainsOrderAndFinalWaitsForOwnedCleanup() async throws {
        let source = AuthoredSpeechSource(); source.chunks = [Data([17]), Data([0, 18, 0]), Data([19, 0])]
        let renderer = CoachingSpeechRenderer(source: { _ in source })
        var output: [AudioPayload] = []
        try await renderer.render("authored suggestion") { payload in
            if payload.isFinal { #expect(source.cleanups == [false]) }
            output.append(payload)
        }
        #expect(output.map(\.sequence) == [0, 1] && output.map(\.isFinal) == [false, true])
        #expect(output.reduce(Data()) { $0 + $1.bytes } == Data([17, 0, 18, 0, 19, 0]))
        #expect(output.allSatisfy { $0.sampleRate == 24_000 && $0.channels == 1 && $0.codec == .pcm16 })
        #expect(source.finishes == 1 && source.cancelled == 0)
    }

    @Test func cancellationDuringFactoryCannotEmitAndJoinsCleanupBeforeReentry() async throws {
        let source = AuthoredSpeechSource(); source.chunks = [Data([17, 0])]; source.delayCleanup = true
        var owner: CoachingSpeechRenderer?
        let renderer = CoachingSpeechRenderer { _ in owner?.cancel(); return source }; owner = renderer
        let task = Task { try await renderer.render("authored") { _ in Issue.record("Cancelled render emitted") } }
        for _ in 0..<100 where source.cleanupWait == nil { await Task.yield() }
        #expect(source.cleanupWait != nil && source.cleanups == [true])
        await #expect(throws: ForegroundCoachingError.busy) { try await renderer.render("other") { _ in } }
        source.cleanupWait?.resume(); source.cleanupWait = nil
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(source.cancelled == 1)
    }

    @Test func downstreamRevocationRejectsLateChunksAndRetiresSource() async throws {
        let source = AuthoredSpeechSource(); source.chunks = [Data([17, 0]), Data([18, 0]), Data([19, 0])]
        let renderer = CoachingSpeechRenderer(source: { _ in source }); var effects = 0
        await #expect(throws: CancellationError.self) {
            try await renderer.render("authored") { _ in effects += 1; renderer.cancel() }
        }
        #expect(effects == 1 && source.cleanups == [true] && source.finishes == 0)
    }

    @Test func emptyOddOversizedAndFailedSourcesCannotComplete() async throws {
        for chunks in [[], [Data([1])], [Data(repeating: 17, count: 96_002)]] {
            let source = AuthoredSpeechSource(); source.chunks = chunks
            let renderer = CoachingSpeechRenderer(source: { _ in source })
            await #expect(throws: ForegroundCoachingError.invalidSpeech) {
                try await renderer.render("authored") { _ in Issue.record("Invalid audio emitted") }
            }
            #expect(source.cleanups == [true] && source.cancelled == 1)
        }
        for cleanupFailure in [false, true] {
            let source = AuthoredSpeechSource(); source.chunks = [Data([17, 0])]
            source.failFinish = !cleanupFailure; source.failCleanup = cleanupFailure
            let renderer = CoachingSpeechRenderer(source: { _ in source })
            await #expect(throws: ForegroundCoachingError.invalidSpeech) {
                try await renderer.render("authored") { _ in Issue.record("Failed source finalized") }
            }
            #expect(source.cancelled == 1 && source.cleanups.last == true)
        }
    }

    @Test func cancellationWhileCleanupIsSuspendedCannotFinalizeOrReleaseSlot() async throws {
        let source = AuthoredSpeechSource(); source.chunks = [Data([17, 0])]; source.delayCleanup = true
        let renderer = CoachingSpeechRenderer(source: { _ in source }); var effects = 0
        let task = Task { try await renderer.render("authored") { _ in effects += 1 } }
        for _ in 0..<100 where source.cleanupWait == nil { await Task.yield() }
        #expect(source.cleanups == [false] && source.cleanupWait != nil && effects == 0)
        renderer.cancel()
        await #expect(throws: ForegroundCoachingError.busy) { try await renderer.render("other") { _ in } }
        source.delayCleanup = false; source.cleanupWait?.resume(); source.cleanupWait = nil
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(effects == 0 && source.cleanups == [false, true])
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

    @Test func boundedChunksAndDownstreamErrorsRetainOwnershipUntilCleanup() async throws {
        let source = AuthoredSpeechSource(); source.chunks = [Data(repeating: 17, count: 96_000)]
        let renderer = CoachingSpeechRenderer(source: { _ in source }); var output: [AudioPayload] = []
        try await renderer.render("authored") { output.append($0) }
        #expect(output.count == 2 && output.allSatisfy { $0.bytes.count == 48_000 })
        source.chunks = Array(repeating: Data([17, 0]), count: 34)
        await #expect(throws: ForegroundCoachingError.invalidSpeech) {
            try await renderer.render("authored") { _ in }
        }
        #expect(source.cleanups.last == true)
        await #expect(throws: ForegroundCoachingError.transportFailed) {
            try await renderer.render("authored") { _ in throw ForegroundCoachingError.transportFailed }
        }
        #expect(source.cleanups.last == true)
    }
}
