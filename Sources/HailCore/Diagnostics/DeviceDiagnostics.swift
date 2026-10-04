public import Foundation
public import HailProtocol
public import Observation
#if os(iOS)
import AVFAudio
import UIKit
#endif

// The log, its sender contract and its system sources stay in one file so the privacy rules are one review.
// swiftlint:disable file_length

/// The phone's device diagnostics log (#234). Off by default and persisted: while off nothing is recorded or
/// sent, and turning it off clears the buffer. While on, events go into a bounded in-memory ring buffer (never to
/// disk) and are sent in small batches, paced to the host's own rate limit, only to a host that advertises
/// `device_diagnostics`. Events are `HailProtocol.DiagnosticEvent`s, so they can hold only enumerated names, tokens
/// from each field's closed vocabulary, version numbers and scalars: no audio, transcript, reply text or request
/// contents. Every batch carries the enable generation it was taken under; once logging is turned off (or off and
/// on again) that batch is neither sent nor requeued.
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
    /// Bumped on every enable and disable; a batch from an earlier generation is stale.
    public private(set) var generation: UInt64 = 0

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
        generation &+= 1
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
            onPending?()
            return
        }
        recordTokens -= 1
        buffer.append(event)
        trimToCapacity()
        onPending?()
    }

    /// Keeps the newest `capacity` events and counts the rest as dropped.
    private func trimToCapacity() {
        if buffer.count > Self.capacity {
            dropped += buffer.count - Self.capacity
            buffer.removeFirst(buffer.count - Self.capacity)
        }
        bufferedCount = buffer.count
    }

    /// The next batch the send budget allows, oldest first, led by an `events_dropped` count when anything was
    /// lost. Nil when off, empty or out of budget. A failed send hands the batch back with `requeue`.
    public func nextBatch() -> DiagnosticBatch? {
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
        return batch.isEmpty ? nil : DiagnosticBatch(events: batch, generation: generation)
    }

    /// True while logging is on and has not been turned off since `batch` was taken. Check before sending.
    public func isCurrent(_ batch: DiagnosticBatch) -> Bool { isEnabled && batch.generation == generation }

    /// Puts an unsent batch back in front, unless logging was turned off (or off and on) since it was taken.
    /// Anything over capacity is counted as dropped.
    public func requeue(_ batch: DiagnosticBatch) {
        guard isCurrent(batch) else { return }
        buffer = batch.events + buffer
        trimToCapacity()
        onPending?()
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

/// Events taken for one send, with the enable generation they were taken under.
public struct DiagnosticBatch: Sendable, Equatable {
    public let events: [DiagnosticEvent]
    public let generation: UInt64
}

extension HostConnection {
    /// Sends one diagnostics batch; only to a ready host that advertises `device_diagnostics` (#234).
    public func sendDiagnostics(_ events: [DiagnosticEvent]) async throws {
        try requireReady(capability: DiagnosticLimits.capability)
        try await send(.diagnostic(events: events), generation: generation)
    }
}

/// What the phone itself reports (#234): its build and OS, audio route changes and interruptions, app
/// lifecycle, capture ended by the system, and reply playback. Each source is mapped to enumerated tokens here;
/// no system string is passed through unless it is already a short token (a route's port type).
extension DeviceDiagnostics {
    /// App version and build, OS version and device class. Never the device's name.
    public static func appInfo(bundle: Bundle = .main) -> [DiagnosticField: DiagnosticValue] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            .app: version(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            .build: version(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            .os: version("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            .device: token(deviceClass, for: .device)
        ].compactMapValues { $0 }
    }

    /// `value` when it is in `field`'s vocabulary, else `other`.
    public nonisolated static func token(_ value: String?, for field: DiagnosticField) -> DiagnosticValue {
        .token(value.flatMap { field.tokens.contains($0) ? $0 : nil } ?? "other")
    }

    /// `value` when it is a plain version number; nil (the field is left out) otherwise.
    public nonisolated static func version(_ value: String?) -> DiagnosticValue? {
        value.flatMap { DiagnosticLimits.isVersion($0) ? .token($0) : nil }
    }

    /// `AVAudioSession.RouteChangeReason` raw values.
    nonisolated static func routeChangeReason(_ raw: UInt) -> String {
        let names: [UInt: String] = [
            0: "unknown", 1: "new_device_available", 2: "old_device_unavailable", 3: "category_change",
            4: "override", 6: "wake_from_sleep", 7: "no_suitable_route", 8: "route_configuration_change"
        ]
        return names[raw] ?? "other"
    }

    /// `AVAudioSession.InterruptionReason` raw values.
    nonisolated static func interruptionReason(_ raw: UInt) -> String {
        let names: [UInt: String] = [0: "default", 1: "app_was_suspended", 2: "built_in_mic_muted",
                                     3: "scene_was_backgrounded", 4: "route_disconnected"]
        return names[raw] ?? "other"
    }

    /// Reply-status strings the playback controller sets on failure, as tokens. Other statuses are not failures.
    nonisolated static func playbackFailure(_ status: String) -> String? {
        [
            "Playback failed": "playback_failed", "Playback could not resume": "resume_failed",
            "Replay failed": "replay_failed", "Audio format is not yet playable": "format_unplayable",
            "Conflicting audio segment refused": "conflicting_segment"
        ][status]
    }

    private static var deviceClass: String {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: "phone"
        case .pad: "pad"
        default: "other"
        }
        #else
        "mac"
        #endif
    }

    /// Reply playback start and end (busy rising and falling) with the echo guard that follows it, and new
    /// playback failures. The guard masks while busy and for its tail after, so `echo_guard` records both edges.
    public func watch(_ playback: ReplyPlaybackController) {
        let (busy, failures) = withObservationTracking {
            (playback.isReplyAudioOutputBusy, Set(playback.presentationStatuses.compactMap { id, status in
                Self.playbackFailure(status).map { "\(id)|\($0)" }
            }))
        } onChange: { [weak self, weak playback] in
            Task { @MainActor in
                guard let self, let playback else { return }
                self.watch(playback)
            }
        }
        if busy != lastPlayback.busy {
            record(busy ? .replyPlaybackStart : .replyPlaybackEnd)
            let tail = Int64(AmbientReplyEchoGuard.defaultTail / .milliseconds(1))
            record(.echoGuard, busy ? [.on: .boolean(true)] : [.on: .boolean(false), .ms: .integer(tail)])
        }
        for failure in failures.subtracting(lastPlayback.failures).sorted() {
            record(.replyPlaybackError, [.code: .token(String(failure.split(separator: "|").last ?? "other"))])
        }
        lastPlayback = (busy, failures)
    }

    static let backgroundNotification = Notification.Name("UIApplicationDidEnterBackgroundNotification")
    static let foregroundNotification = Notification.Name("UIApplicationWillEnterForegroundNotification")

    /// Route changes, interruptions, media-services resets, app background and foreground, and capture ended by
    /// the system, from `center`. Call once; the observers live as long as this log.
    public func observeSystem(center: NotificationCenter = .default) {
        guard observers.isEmpty else { return }
        var names = [AVAudioEngineCapture.endedBySystem, Self.backgroundNotification, Self.foregroundNotification]
        #if os(iOS)
        names += [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                  AVAudioSession.mediaServicesWereResetNotification]
        #endif
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                let info = Self.scalars(note.userInfo)
                MainActor.assumeIsolated { self?.handle(name, info) }
            })
        }
    }

    /// Only unsigned-integer `userInfo` values are kept: the reason, type and option codes read below.
    nonisolated static func scalars(_ info: [AnyHashable: Any]?) -> [String: UInt] {
        var kept: [String: UInt] = [:]
        for (key, value) in info ?? [:] {
            if let key = key as? String, let value = value as? UInt { kept[key] = value }
        }
        return kept
    }

    #if os(iOS)
    /// An input or output port as a `route` token, compared against the system constants.
    nonisolated static func route(_ port: AVAudioSession.Port) -> String {
        let names: [AVAudioSession.Port: String] = [
            .builtInMic: "built_in_mic", .builtInSpeaker: "built_in_speaker", .builtInReceiver: "built_in_receiver",
            .headphones: "headphones", .headsetMic: "headset_mic", .lineIn: "line_in", .lineOut: "line_out",
            .bluetoothA2DP: "bluetooth_a2dp", .bluetoothHFP: "bluetooth_hfp", .bluetoothLE: "bluetooth_le",
            .airPlay: "airplay", .HDMI: "hdmi", .carAudio: "car_audio", .usbAudio: "usb_audio"
        ]
        return names[port] ?? "other"
    }
    #endif

    func handle(_ name: Notification.Name, _ info: [String: UInt]) {
        switch name {
        case AVAudioEngineCapture.endedBySystem: record(.captureState, [.state: .token("ended_by_system")])
        case Self.backgroundNotification: record(.appBackground)
        case Self.foregroundNotification: record(.appForeground)
        default: handleAudioSession(name, info)
        }
    }

    private func handleAudioSession(_ name: Notification.Name, _ info: [String: UInt]) {
        #if os(iOS)
        switch name {
        case AVAudioSession.routeChangeNotification:
            let input = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType
            record(.routeChange, [
                .reason: .token(Self.routeChangeReason(info[AVAudioSessionRouteChangeReasonKey] ?? 0)),
                .route: .token(input.map(Self.route) ?? "none")
            ])
        case AVAudioSession.interruptionNotification:
            if info[AVAudioSessionInterruptionTypeKey] == AVAudioSession.InterruptionType.began.rawValue {
                let reason = Self.interruptionReason(info[AVAudioSessionInterruptionReasonKey] ?? 0)
                record(.interruptionBegin, [.reason: .token(reason)])
            } else {
                let options = info[AVAudioSessionInterruptionOptionKey] ?? 0
                let resume = options & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
                record(.interruptionEnd, [.on: .boolean(resume)])
            }
        case AVAudioSession.mediaServicesWereResetNotification:
            record(.captureError, [.code: .token("media_services_reset")])
        default: break
        }
        #endif
    }
}
