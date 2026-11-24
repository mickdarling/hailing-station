import HailCore
import Testing

struct EchoCancellerTimelineTests {
    let mono = EchoPCMFormat(sampleRate: 16_000, channels: 1)

    @Test func referenceIsPairedBySamplePositionAcrossUnequalCallbacks() throws {
        let probe = ReferencePairingProbe()
        try probe.configure(format: mono)
        #expect(probe.outputLatencySamples == 0)
        try probe.render(reference: EchoPCMFrame(format: mono, startSample: 20, samples: [11, 12, 13]))
        try probe.render(reference: EchoPCMFrame(format: mono, startSample: 25, samples: [14, 15]))

        // First capture starts inside the first reference. The second crosses a gap into the next reference.
        let first = EchoPCMFrame(format: mono, startSample: 21, samples: [91])
        let second = EchoPCMFrame(format: mono, startSample: 22, samples: [92, 93, 94, 95, 96, 97])
        let expectedFirst = EchoPCMFrame(format: mono, startSample: 21, samples: [12])
        let expectedSecond = EchoPCMFrame(format: mono, startSample: 22, samples: [13, 0, 0, 14, 15, 0])
        let result = try probe.process(capture: first)
        #expect(result.frame == expectedFirst)
        let next = try probe.process(capture: second)
        #expect(next.frame == expectedSecond)
        #expect(probe.pairedReferences == [expectedFirst, expectedSecond])
        #expect(!result.diagnostics.requiresMasking && !next.diagnostics.requiresMasking)
    }

    @Test func captureGapsAndOverlapsMaskThenReanchorInPerChannelSamples() throws {
        let processor = PassthroughEchoCanceller()
        let stereo = EchoPCMFormat(sampleRate: 48_000, channels: 2)
        try processor.configure(format: stereo)
        func check(_ start: Int64, requiresMasking: Bool) throws {
            let frame = EchoPCMFrame(format: stereo, startSample: start, samples: [1, -1, 2, -2])
            let result = try processor.process(capture: frame)
            #expect(result.frame == frame)
            #expect(result.diagnostics.requiresMasking == requiresMasking)
            #expect(processor.diagnostics == result.diagnostics)
        }
        try check(-2, requiresMasking: false)
        try check(0, requiresMasking: false)
        try check(8, requiresMasking: true)
        try check(10, requiresMasking: false)
        try check(11, requiresMasking: true)
        try check(13, requiresMasking: false)
        processor.reset()
        try processor.configure(format: stereo)
        try check(200, requiresMasking: false)
    }

    @Test func unrepresentableExclusiveEndFailsClosed() throws {
        let processor = PassthroughEchoCanceller()
        try processor.configure(format: mono)
        let frame = EchoPCMFrame(format: mono, startSample: .max, samples: [1])
        #expect(frame.endSample == nil)
        #expect(throws: EchoCancellerError.invalidFrame) { try processor.process(capture: frame) }
        #expect(processor.diagnostics.requiresMasking)
    }
}

/// Mono test processor that exposes the reference paired with each capture interval as its output.
final class ReferencePairingProbe: FrameEchoCanceller {
    private let timing = PassthroughEchoCanceller()
    let outputLatencySamples: Int64 = 0
    private var referenceSamples: [Int64: Int16] = [:]
    private(set) var pairedReferences: [EchoPCMFrame] = []
    private(set) var diagnostics = EchoDiagnostics(state: .unconfigured)

    func configure(format: EchoPCMFormat) throws(EchoCancellerError) {
        reset()
        guard format.channels == 1 else { throw EchoCancellerError.unsupportedFormat }
        try timing.configure(format: format)
        diagnostics = EchoDiagnostics(state: .adapting)
    }

    func render(reference: EchoPCMFrame) throws(EchoCancellerError) {
        try timing.render(reference: reference)
        for (offset, sample) in reference.samples.enumerated() {
            referenceSamples[reference.startSample + Int64(offset)] = sample
        }
    }

    func process(capture: EchoPCMFrame) throws(EchoCancellerError)
        -> (frame: EchoPCMFrame, diagnostics: EchoDiagnostics) {
        let checked = try timing.process(capture: capture)
        diagnostics = checked.diagnostics
        guard !diagnostics.requiresMasking else { return checked }
        let samples = capture.samples.indices.map { referenceSamples[capture.startSample + Int64($0)] ?? 0 }
        let paired = EchoPCMFrame(format: capture.format, startSample: capture.startSample, samples: samples)
        pairedReferences.append(paired)
        diagnostics = EchoDiagnostics(state: .ready, estimatedDelayMilliseconds: 20, coarseERLEDecibels: 10)
        return (paired, diagnostics)
    }

    func reset() {
        timing.reset()
        referenceSamples.removeAll()
        pairedReferences.removeAll()
        diagnostics = EchoDiagnostics(state: .unconfigured)
    }
}
