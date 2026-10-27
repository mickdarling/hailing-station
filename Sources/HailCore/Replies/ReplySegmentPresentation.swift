/// Content-free transient notice. Retains only the latest event id, even after dismissal or timeout.
public struct ReplySegmentNotice: Sendable {
    public static let text = "Paused — go ahead"
    public static let lifetime: Duration = .seconds(4)
    private var lastEventID: UInt64?
    public private(set) var deadline: ContinuousClock.Instant?
    public var isVisible: Bool { deadline != nil }

    public init() {}

    /// The caller posts VoiceOver only when this returns true; rendering and dismissal never announce.
    public mutating func observe(
        _ event: ReplySegmentYieldEvent?, at now: ContinuousClock.Instant, voiceOverRunning: Bool
    ) -> Bool {
        guard let event, event.id != lastEventID else { return false }
        lastEventID = event.id
        deadline = now.advanced(by: Self.lifetime)
        return voiceOverRunning
    }

    public mutating func dismiss() { deadline = nil }

    /// Checking the current deadline prevents an older timeout from hiding a newer notice.
    public mutating func expire(at now: ContinuousClock.Instant) {
        if let deadline, now >= deadline { dismiss() }
    }
}

/// The two Station tools bindings use the same validation as persisted/controller settings.
public enum ReplySegmentSetting: Sendable {
    case pause, threshold

    public var bounds: ClosedRange<Double> {
        switch self {
        case .pause: 0.1...10
        case .threshold: -60 ... -15
        }
    }

    public func value(in settings: ReplySegmentSettings) -> Double {
        switch self {
        case .pause: settings.pauseAfterSegment
        case .threshold: settings.onsetThresholdDBFS
        }
    }

    public func updating(_ settings: ReplySegmentSettings, to value: Double) -> ReplySegmentSettings {
        ReplySegmentSettings(
            pauseAfterSegment: self == .pause ? value : settings.pauseAfterSegment,
            sustainedOnset: settings.sustainedOnset,
            onsetThresholdDBFS: self == .threshold ? value : settings.onsetThresholdDBFS
        )
    }
}

/// Plain counts only; no reply text, endpoint, identity, audio or timestamps enter these rows.
public struct ReplySegmentDiagnosticRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let count: String
}

public enum ReplySegmentDiagnosticsPresentation {
    public static func counters(_ diagnostics: ReplyOnsetDiagnostics) -> [ReplySegmentDiagnosticRow] {
        [ReplySegmentDiagnosticRow(id: "Yield signals", count: String(diagnostics.onsets)),
         ReplySegmentDiagnosticRow(id: "No request within 5 s", count: String(diagnostics.withoutAdmittedRequest))]
    }

    public static func histogram(_ histogram: ReplyOnsetHistogram) -> [ReplySegmentDiagnosticRow] {
        let labels = ["Below −60 dBFS", "−60 to below −45 dBFS", "−45 to below −35 dBFS",
                      "−35 to below −25 dBFS", "−25 to 0 dBFS"]
        return zip(labels, histogram.counts).map { ReplySegmentDiagnosticRow(id: $0, count: String($1)) }
    }
}
