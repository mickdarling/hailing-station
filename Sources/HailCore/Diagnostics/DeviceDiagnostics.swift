public import Foundation
public import HailProtocol
public import Observation

/// The phone's device diagnostics log (#234). Off by default and persisted: while off nothing is recorded or
/// sent, and turning it off clears the buffer. While on, events go into a bounded in-memory ring buffer (never to
/// disk) and are sent in small batches, paced to the host's own rate limit, only to a host that advertises
/// `device_diagnostics`. Events are `HailProtocol.DiagnosticEvent`s, so they can hold only enumerated names and
/// short scalar tokens: no audio, transcript, reply text or request contents.
@MainActor
@Observable
public final class DeviceDiagnostics {
    public static let enabledKey = "hailing-station.device-diagnostics.v1"
    public static let capacity = 500
    /// Recording: a burst of 60 events, then one per second. Excess is counted, not stored.
    public static let recordRate = (capacity: 60.0, perSecond: 1.0)
    /// Sending mirrors the host's per-session bucket (120 events, 2 per second), so the host never drops.
    public static let sendRate = (capacity: 120.0, perSecond: 2.0)

    public private(set) var isEnabled: Bool
    public private(set) var bufferedCount = 0

    @ObservationIgnored private var buffer: [DiagnosticEvent] = []
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var recordTokens: Double
    @ObservationIgnored private var sendTokens: Double
    @ObservationIgnored private var recordUpdated: ContinuousClock.Instant
    @ObservationIgnored private var sendUpdated: ContinuousClock.Instant
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appInfo: [DiagnosticField: DiagnosticValue]
    @ObservationIgnored private let wallNow: @Sendable () -> Int64
    @ObservationIgnored private let clock: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored var observers: [any NSObjectProtocol] = []
    @ObservationIgnored var lastPlayback: (busy: Bool, failures: Set<String>) = (false, [])
    /// Called after an event is buffered, so the connection store can schedule a send.
    @ObservationIgnored public var onPending: (@MainActor () -> Void)?

    public init(
        defaults: UserDefaults = .standard, appInfo: [DiagnosticField: DiagnosticValue]? = nil,
        wallNow: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down)) },
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.defaults = defaults
        self.appInfo = appInfo ?? Self.appInfo()
        self.wallNow = wallNow
        self.clock = clock
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        recordTokens = Self.recordRate.capacity
        sendTokens = Self.sendRate.capacity
        recordUpdated = clock()
        sendUpdated = recordUpdated
        if isEnabled { record(.appInfo, self.appInfo) }
    }

    /// Persists the choice. Off clears everything buffered; on starts with this build's `app_info`.
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        buffer.removeAll()
        dropped = 0
        bufferedCount = 0
        if enabled { record(.appInfo, appInfo) }
    }

    /// Buffers one event when logging is on. A value that fails the protocol's bounds, the rate limit or a full
    /// buffer (oldest first) only adds to the dropped count reported in the next batch.
    public func record(_ name: DiagnosticEventName, _ fields: [DiagnosticField: DiagnosticValue] = [:]) {
        guard isEnabled else { return }
        refill(&recordTokens, updated: &recordUpdated, rate: Self.recordRate)
        guard recordTokens >= 1, let event = try? DiagnosticEvent(name, timestamp: max(0, wallNow()), fields: fields)
        else {
            dropped += 1
            return
        }
        recordTokens -= 1
        buffer.append(event)
        if buffer.count > Self.capacity {
            buffer.removeFirst(buffer.count - Self.capacity)
            dropped += 1
        }
        bufferedCount = buffer.count
        onPending?()
    }

    /// The next batch the send budget allows, oldest first, led by an `events_dropped` count when anything was
    /// lost. Nil when off, empty or out of budget. A failed send hands the batch back with `requeue`.
    public func nextBatch() -> [DiagnosticEvent]? {
        guard isEnabled, !buffer.isEmpty || dropped > 0 else { return nil }
        refill(&sendTokens, updated: &sendUpdated, rate: Self.sendRate)
        let budget = min(Int(sendTokens), DiagnosticLimits.maxEventsPerBatch)
        guard budget >= 1 else { return nil }
        var batch: [DiagnosticEvent] = []
        if dropped > 0, let count = try? DiagnosticEvent(.eventsDropped, timestamp: max(0, wallNow()), fields: [
            .count: .integer(Int64(min(dropped, Int(Int32.max)))), .code: .token("app_buffer")
        ]) {
            batch.append(count)
            dropped = 0
        }
        let taken = min(budget - batch.count, buffer.count)
        batch += buffer.prefix(taken)
        buffer.removeFirst(taken)
        bufferedCount = buffer.count
        sendTokens -= Double(batch.count)
        return batch.isEmpty ? nil : batch
    }

    /// Puts an unsent batch back in front, within capacity, unless logging was turned off meanwhile.
    public func requeue(_ batch: [DiagnosticEvent]) {
        guard isEnabled else { return }
        buffer = Array((batch + buffer).suffix(Self.capacity))
        bufferedCount = buffer.count
    }

    public var hasPending: Bool { isEnabled && (!buffer.isEmpty || dropped > 0) }

    private func refill(
        _ tokens: inout Double, updated: inout ContinuousClock.Instant, rate: (capacity: Double, perSecond: Double)
    ) {
        let instant = clock()
        let elapsed = updated.duration(to: instant).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        tokens = min(rate.capacity, tokens + max(0, seconds) * rate.perSecond)
        updated = instant
    }
}

extension HostConnection {
    /// Sends one diagnostics batch; only to a ready host that advertises `device_diagnostics` (#234).
    public func sendDiagnostics(_ events: [DiagnosticEvent]) async throws {
        try requireReady(capability: DiagnosticLimits.capability)
        try await send(.diagnostic(events: events), generation: generation)
    }
}
