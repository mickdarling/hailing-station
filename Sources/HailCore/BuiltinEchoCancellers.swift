/// Identity processing for a qualified private output. The caller owns route qualification.
public final class PassthroughEchoCanceller: FrameEchoCanceller {
    public let outputLatencySamples: Int64 = 0
    private var format: EchoPCMFormat?
    private var nextCaptureSample: Int64?
    public private(set) var diagnostics = EchoDiagnostics(state: .unconfigured)

    public init() {}

    public func configure(format: EchoPCMFormat) throws(EchoCancellerError) {
        guard format.sampleRate > 0, format.channels > 0 else { throw fail(.unsupportedFormat) }
        self.format = format
        nextCaptureSample = nil
        diagnostics = EchoDiagnostics(state: .ready)
    }

    public func render(reference: EchoPCMFrame) throws(EchoCancellerError) {
        _ = try validatedEnd(of: reference)
    }

    public func process(capture: EchoPCMFrame) throws(EchoCancellerError)
        -> (frame: EchoPCMFrame, diagnostics: EchoDiagnostics) {
        let end = try validatedEnd(of: capture)
        let discontinuity = nextCaptureSample.map { $0 != capture.startSample } ?? false
        diagnostics = EchoDiagnostics(state: discontinuity ? .adapting : .ready)
        nextCaptureSample = end
        return (capture, diagnostics)
    }

    public func reset() {
        format = nil
        nextCaptureSample = nil
        diagnostics = EchoDiagnostics(state: .unconfigured)
    }

    private func validatedEnd(of frame: EchoPCMFrame) throws(EchoCancellerError) -> Int64 {
        if case .failed(let error) = diagnostics.state { throw error }
        guard let format else { throw fail(.unconfigured) }
        guard frame.format == format, let end = frame.endSample else { throw fail(.invalidFrame) }
        return end
    }

    private func fail(_ error: EchoCancellerError) -> EchoCancellerError {
        format = nil
        diagnostics = EchoDiagnostics(state: .failed(error))
        return error
    }
}

/// Describes hardware-graph wiring. Satisfying and observing the requirement belongs to the capture factory.
public final class AppleVoiceProcessingDescriptor: GraphEchoCanceller {
    public let requirement = EchoGraphRequirement.voiceProcessingWithSameEngineReplies
    public private(set) var diagnostics = EchoDiagnostics(state: .unconfigured)

    public init() {}

    public func reportRequirementMet(_ met: Bool) {
        diagnostics = EchoDiagnostics(state: met ? .ready : .failed(.graphUnavailable))
    }

    public func reset() {
        diagnostics = EchoDiagnostics(state: .unconfigured)
    }
}
