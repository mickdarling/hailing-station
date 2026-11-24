/// Interleaved signed 16-bit PCM. Sample rate is per channel, in Hz.
public struct EchoPCMFormat: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int

    public init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct EchoPCMFrame: Equatable, Sendable {
    public let format: EchoPCMFormat
    /// First per-channel sample on the capture run's sample clock, shared by render and capture.
    public let startSample: Int64
    public let samples: [Int16]

    public init(format: EchoPCMFormat, startSample: Int64, samples: [Int16]) {
        self.format = format
        self.startSample = startSample
        self.samples = samples
    }

    /// Exclusive end of a nonempty interval of complete channel groups, or nil for an invalid span.
    public var endSample: Int64? {
        guard format.channels > 0, !samples.isEmpty, samples.count.isMultiple(of: format.channels) else { return nil }
        let (end, overflow) = startSample.addingReportingOverflow(Int64(samples.count / format.channels))
        return overflow ? nil : end
    }
}

/// Closed error codes keep diagnostics independent of engine messages, audio and device identifiers.
public enum EchoCancellerError: Error, Equatable, Sendable {
    case unsupportedFormat, invalidFrame, unconfigured, processingFailed, graphUnavailable
    case unconfiguredRoute, unregisteredImplementation
}

public struct EchoDiagnostics: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unconfigured, adapting, outputUnavailable, ready, failed(EchoCancellerError)
    }

    public let state: State
    public let estimatedDelayMilliseconds: UInt32?
    /// Whole-decibel estimate of echo return loss enhancement, when available.
    public let coarseERLEDecibels: Int16?

    public init(state: State, estimatedDelayMilliseconds: UInt32? = nil, coarseERLEDecibels: Int16? = nil) {
        self.state = state
        self.estimatedDelayMilliseconds = estimatedDelayMilliseconds
        self.coarseERLEDecibels = coarseERLEDecibels
    }

    public var requiresMasking: Bool { state != .ready }
}

/// One instance belongs to one capture run, with calls serialized by its owner. On any error or
/// diagnostics requiring masking, the caller must mask the affected output interval.
/// Ready only describes this canceller. Route qualification, privacy and user masks still take precedence.
/// Reset at run teardown or route loss to discard configuration, history, metrics and previous errors.
public protocol EchoCanceller: AnyObject {
    var diagnostics: EchoDiagnostics { get }
    func reset()
}

/// Configure starts a new sample timeline. The caller maps actual reference playout onto the capture run's
/// sample clock. Render and capture callbacks can have different sizes. Align by per-channel sample position
/// across callbacks and treat uncovered reference positions as silence.
///
/// The caller delays the capture stream AND its capture-time masking decisions by outputLatencySamples.
/// Apply the saved mask for the returned interval together with its returned diagnostics and any current
/// privacy veto. A gap or overlap (capture.startSample differs from the previous exclusive end), reset or
/// reconfiguration flushes pending work. Treat retired intervals as masked placeholders, discard stale
/// completions even if positions repeat, and warm up on the new timeline. Mask discontinuous input when due.
public protocol FrameEchoCanceller: EchoCanceller {
    /// Constant per-channel sample delay for the configured run. Must be nonnegative; synchronous processors use zero.
    var outputLatencySamples: Int64 { get }
    func configure(format: EchoPCMFormat) throws(EchoCancellerError)
    func render(reference: EchoPCMFrame) throws(EchoCancellerError)
    /// Submit capture without waiting. Return its format and sample count at startSample - outputLatencySamples.
    /// Throw invalidFrame if the interval is unrepresentable. When any of the due interval is still warming up
    /// or its work is unfinished, return a placeholder at that same due interval with masking diagnostics.
    /// The disposition is final: discard output that misses its deadline.
    func process(capture: EchoPCMFrame) throws(EchoCancellerError)
        -> (frame: EchoPCMFrame, diagnostics: EchoDiagnostics)
}

/// Requirements are interpreted by the capture factory. Frame delivery is exclusive to FrameEchoCanceller.
public enum EchoGraphRequirement: Sendable {
    case voiceProcessingWithSameEngineReplies
}

public protocol GraphEchoCanceller: EchoCanceller {
    var requirement: EchoGraphRequirement { get }
    /// The graph owner must confirm the entire requirement after startup and revoke it on loss.
    func reportRequirementMet(_ met: Bool)
}
