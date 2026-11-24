import HailCore
import Testing

struct EchoCancellerWorkerTests {
    private let format = EchoPCMFormat(sampleRate: 16_000, channels: 2)

    private func frame(_ start: Int64, _ samples: [Int16]) -> EchoPCMFrame {
        EchoPCMFrame(format: format, startSample: start, samples: samples)
    }

    @Test func warmUpMasksTheEarlierInterval() throws {
        let worker = OneFrameWorker()
        try worker.configure(format: format)
        #expect(worker.outputLatencySamples == 2)
        let result = try worker.process(capture: frame(0, [80, -82, 84, -86]))
        #expect(result.frame == frame(-2, [0, 0, 0, 0]))
        #expect(result.diagnostics.requiresMasking)
    }

    @Test func completedCaptureIsDeliveredOneFrameLater() throws {
        let worker = OneFrameWorker()
        try worker.configure(format: format)
        _ = try worker.process(capture: frame(30, [80, -82, 84, -86]))
        let firstJob = try #require(worker.pending)
        #expect(firstJob.complete())

        let result = try worker.process(capture: frame(32, [10, 20, 30, 40]))
        #expect(result.frame == frame(30, [40, -41, 42, -43]))
        #expect(!result.diagnostics.requiresMasking)
        #expect(worker.diagnostics == result.diagnostics)
    }

    @Test func deadlineMissIsFinalAndNextJobCanSucceed() throws {
        let worker = OneFrameWorker()
        try worker.configure(format: format)
        _ = try worker.process(capture: frame(30, [80, -82, 84, -86]))
        let late = try #require(worker.pending)
        let missed = try worker.process(capture: frame(32, [10, 20, 30, 40]))
        #expect(missed.frame == frame(30, [0, 0, 0, 0]))
        #expect(missed.diagnostics == EchoDiagnostics(state: .outputUnavailable))
        #expect(missed.diagnostics.requiresMasking)
        #expect(!late.complete())
        let nextJob = try #require(worker.pending)
        #expect(nextJob.complete())
        let next = try worker.process(capture: frame(34, [99, 98, 97, 96]))
        #expect(next.frame == frame(32, [5, 10, 15, 20]))
        #expect(!next.diagnostics.requiresMasking)
    }

    @Test func resetFlushesWorkEvenWhenSamplePositionsRepeat() throws {
        let worker = OneFrameWorker()
        try worker.configure(format: format)
        _ = try worker.process(capture: frame(30, [80, -82, 84, -86]))
        let retired = try #require(worker.pending)
        worker.reset()
        #expect(worker.pending == nil)
        #expect(worker.diagnostics.requiresMasking)
        try worker.configure(format: format)
        let warmUp = try worker.process(capture: frame(30, [2, 4, 6, 8]))
        #expect(warmUp.frame == frame(28, [0, 0, 0, 0]))
        #expect(warmUp.diagnostics.requiresMasking)
        #expect(!retired.complete())
        let fresh = try #require(worker.pending)
        #expect(fresh.complete())
        let result = try worker.process(capture: frame(32, [10, 20, 30, 40]))
        #expect(result.frame == frame(30, [1, 2, 3, 4]))
        #expect(!result.diagnostics.requiresMasking)
    }

    @Test(arguments: [Int64(40), 30])
    func gapOrOverlapFlushesPendingCapture(restart: Int64) throws {
        let worker = OneFrameWorker()
        try worker.configure(format: format)
        _ = try worker.process(capture: frame(30, [80, -82, 84, -86]))
        let retired = try #require(worker.pending)
        let discontinuity = try worker.process(capture: frame(restart, [2, 4, 6, 8]))
        #expect(discontinuity.frame == frame(restart - 2, [0, 0, 0, 0]))
        #expect(discontinuity.diagnostics.requiresMasking)
        #expect(!retired.complete())
        let masked = try worker.process(capture: frame(restart + 2, [12, 14, 16, 18]))
        #expect(masked.frame == frame(restart, [0, 0, 0, 0]))
        #expect(masked.diagnostics.requiresMasking)
        let fresh = try #require(worker.pending)
        #expect(fresh.complete())
        let result = try worker.process(capture: frame(restart + 4, [10, 20, 30, 40]))
        #expect(result.frame == frame(restart + 2, [6, 7, 8, 9]))
        #expect(!result.diagnostics.requiresMasking)
    }
}

/// A manually stepped worker with one input block in flight. Tests can complete only a submitted job.
private final class OneFrameWorker: FrameEchoCanceller {
    let outputLatencySamples: Int64 = 2
    private let timing = PassthroughEchoCanceller()
    private(set) var pending: Job?
    private(set) var diagnostics = EchoDiagnostics(state: .unconfigured)

    final class Job {
        private var input: EchoPCMFrame?
        private(set) var output: EchoPCMFrame?

        init(_ capture: EchoPCMFrame) { input = capture }

        func complete() -> Bool {
            guard let input else { return false }
            let samples = input.samples.map { $0 / 2 }
            output = EchoPCMFrame(format: input.format, startSample: input.startSample, samples: samples)
            self.input = nil
            return true
        }

        func discard() {
            input = nil
            output = nil
        }
    }

    func configure(format: EchoPCMFormat) throws(EchoCancellerError) {
        reset()
        try timing.configure(format: format)
        diagnostics = EchoDiagnostics(state: .adapting)
    }

    func render(reference: EchoPCMFrame) throws(EchoCancellerError) {
        try timing.render(reference: reference)
    }

    func process(capture: EchoPCMFrame) throws(EchoCancellerError)
        -> (frame: EchoPCMFrame, diagnostics: EchoDiagnostics) {
        let checked = try timing.process(capture: capture)
        let (start, overflow) = capture.startSample.subtractingReportingOverflow(outputLatencySamples)
        guard !overflow, capture.samples.count / capture.format.channels == outputLatencySamples else {
            reset()
            diagnostics = EchoDiagnostics(state: .failed(.invalidFrame))
            throw EchoCancellerError.invalidFrame
        }
        let due = pending
        pending = nil
        defer { due?.discard() }
        if !checked.diagnostics.requiresMasking {
            pending = Job(capture)
            if let output = due?.output {
                diagnostics = EchoDiagnostics(state: .ready)
                return (output, diagnostics)
            }
        }
        let missingDeadline = due != nil && !checked.diagnostics.requiresMasking
        diagnostics = EchoDiagnostics(state: missingDeadline ? .outputUnavailable : .adapting)
        let silence = [Int16](repeating: 0, count: capture.samples.count)
        return (EchoPCMFrame(format: capture.format, startSample: start, samples: silence), diagnostics)
    }

    func reset() {
        pending?.discard()
        pending = nil
        timing.reset()
        diagnostics = EchoDiagnostics(state: .unconfigured)
    }
}
