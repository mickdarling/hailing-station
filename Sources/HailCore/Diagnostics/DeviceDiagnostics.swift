public import Foundation
public import HailProtocol
public import Observation
import Synchronization
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
    public nonisolated static let capacity = 500
    nonisolated let recordingState = DiagnosticRecordingState()
    /// Each recording budget allows a burst of 60 events, then one per second.
    public static let recordRate = (capacity: 60.0, perSecond: 1.0)
    /// Sending mirrors the host's per-session bucket (120 events, 2 per second), so the host never drops.
    public static let sendRate = (capacity: 120.0, perSecond: 2.0)

    public private(set) var isEnabled: Bool
    public private(set) var bufferedCount = 0
    /// Bumped on every enable and disable; a batch from an earlier generation is stale.
    public private(set) var generation: UInt64 = 0

    @ObservationIgnored private var buffer: [DiagnosticEvent] = []
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var recordBudget: DiagnosticTokenBucket
    @ObservationIgnored private var snapshotBudget: DiagnosticTokenBucket
    @ObservationIgnored private var sendBudget: DiagnosticTokenBucket
    @ObservationIgnored fileprivate weak var sendingStore: HostConnectionStore?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appInfo: [DiagnosticField: DiagnosticValue]
    @ObservationIgnored private let wallNow: @Sendable () -> Int64
    @ObservationIgnored private let clock: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored var observers: [any NSObjectProtocol] = []
    @ObservationIgnored var lastPlayback: (busy: Bool, failures: Set<String>) = (false, [])
    @ObservationIgnored private var routeSequence: Int64 = 0
    @ObservationIgnored var currentAudioRoute: @MainActor () -> AudioRouteSnapshot? = {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return AudioRouteSnapshot(ports: AudioRoutePorts(session.currentRoute), settings: AudioRouteSettings(session))
        #else
        return nil
        #endif
    }
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
        let now = clock()
        recordBudget = DiagnosticTokenBucket(rate: Self.recordRate, at: now)
        snapshotBudget = DiagnosticTokenBucket(rate: Self.recordRate, at: now)
        sendBudget = DiagnosticTokenBucket(rate: Self.sendRate, at: now)
        recordingState.update(isEnabled ? generation : nil)
        if isEnabled {
            updateRouteSink()
            record(.appInfo, self.appInfo)
        }
    }

    /// Persists the choice. Off clears everything buffered; on starts with this build's `app_info`.
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        generation &+= 1
        routeSequence = 0
        updateRouteSink()
        recordingState.update(enabled ? generation : nil)
        buffer.removeAll()
        dropped = 0
        bufferedCount = 0
        if enabled { record(.appInfo, appInfo) }
    }

    /// Snapshot-only records have their own allowance. Their loss is visible as a gap in the route sequence.
    public func record(
        _ name: DiagnosticEventName, _ fields: [DiagnosticField: DiagnosticValue] = [:], timestamp: Int64? = nil
    ) {
        guard isEnabled else { return }
        let supplementary = Self.isSupplementaryRouteSnapshot(fields)
        guard let event = try? DiagnosticEvent(name, timestamp: max(0, timestamp ?? wallNow()), fields: fields),
              takeRecordingToken(supplementary: supplementary) else {
            if !supplementary {
                dropped += 1
                onPending?()
            }
            return
        }
        buffer.append(event)
        trimToCapacity()
        onPending?()
    }

    private func takeRecordingToken(supplementary: Bool) -> Bool {
        if supplementary { return snapshotBudget.take(upTo: 1, at: clock()) == 1 }
        return recordBudget.take(upTo: 1, at: clock()) == 1
    }

    /// On append and requeue, evict snapshot-only records first, then count the oldest legacy losses.
    private func trimToCapacity() {
        var excess = buffer.count - Self.capacity
        if excess > 0 {
            buffer.removeAll { event in
                guard excess > 0, Self.isSupplementaryRouteSnapshot(event.fields) else { return false }
                excess -= 1
                return true
            }
            buffer.removeFirst(excess)
            dropped += excess
        }
        bufferedCount = buffer.count
    }
}

extension DeviceDiagnostics {
    /// Use the store's current collector, or legacy capabilities when dequeuing a standalone log.
    public func nextBatch() -> DiagnosticBatch? {
        let collector = sendingStore.flatMap { $0.diagnostics === self ? $0.diagnosticsCollectingHost : nil }
        return nextBatch(for: collector?.capabilities ?? [])
    }

    /// Dequeue for a collecting host using its advertised capabilities. Drop incompatible whole records
    /// before charging the send bucket. Keep eligible records intact for retry against a different host.
    public func nextBatch(for capabilities: [String]) -> DiagnosticBatch? {
        guard isEnabled, !buffer.isEmpty || dropped > 0 else { return nil }
        let routes = capabilities.contains(DiagnosticLimits.routeSnapshotCapability)
        let masking = capabilities.contains(DiagnosticLimits.replyMaskingCapability)
        buffer.removeAll { Self.shouldOmit($0, routeSnapshots: routes, masking: masking) }
        bufferedCount = buffer.count
        let pending = buffer.count + (dropped > 0 ? 1 : 0)
        let budget = sendBudget.take(upTo: min(pending, DiagnosticLimits.maxEventsPerBatch), at: clock())
        guard budget >= 1 else { return nil }
        let reportedDrops = min(dropped, Int(Int32.max))
        var events: [DiagnosticEvent] = []
        if reportedDrops > 0 {
            guard let marker = try? DiagnosticEvent(.eventsDropped, timestamp: max(0, wallNow()), fields: [
                .count: .integer(Int64(reportedDrops)), .code: .token("app_buffer")
            ]) else { return nil }
            events.append(marker)
            dropped -= reportedDrops
        }
        let taken = min(budget - events.count, buffer.count)
        events += buffer.prefix(taken)
        buffer.removeFirst(taken)
        bufferedCount = buffer.count
        return DiagnosticBatch(events: events, generation: generation, reportedDrops: reportedDrops)
    }

    /// True while logging is on and has not been turned off since `batch` was taken. Check before sending.
    public func isCurrent(_ batch: DiagnosticBatch) -> Bool { isEnabled && batch.generation == generation }

    /// Puts an unsent batch back in front, unless logging was turned off (or off and on) since it was taken.
    public func requeue(_ batch: DiagnosticBatch) {
        guard isCurrent(batch) else { return }
        dropped += batch.reportedDrops
        buffer.insert(contentsOf: batch.events.dropFirst(batch.reportedDrops > 0 ? 1 : 0), at: 0)
        trimToCapacity()
        onPending?()
    }

    public var hasPending: Bool { isEnabled && (!buffer.isEmpty || dropped > 0) }
}

private struct DiagnosticTokenBucket {
    let rate: (capacity: Double, perSecond: Double)
    var tokens: Double
    var updated: ContinuousClock.Instant

    init(rate: (capacity: Double, perSecond: Double), at instant: ContinuousClock.Instant) {
        self.rate = rate
        tokens = rate.capacity
        updated = instant
    }

    mutating func take(upTo limit: Int, at instant: ContinuousClock.Instant) -> Int {
        let elapsed = updated.duration(to: instant).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        tokens = min(rate.capacity, tokens + max(0, seconds) * rate.perSecond)
        updated = instant
        let taken = min(limit, Int(tokens))
        tokens -= Double(taken)
        return taken
    }
}

/// Events taken for one send, with the enable generation they were taken under.
public struct DiagnosticBatch: Sendable, Equatable {
    public let events: [DiagnosticEvent]
    public let generation: UInt64
    /// Only the queue-generated leading marker is folded back into the pending count on retry.
    fileprivate let reportedDrops: Int
}

extension HostConnectionStore {
    /// Assigning the log schedules its first flush here. Keep a weak link so later timed flushes
    /// consult the same live collector selection as the store, even if the original host disconnected.
    func scheduleDiagnosticsFlush() {
        diagnostics?.sendingStore = self
        scheduleDiagnosticsFlush(after: .seconds(2))
    }
}

/// A capture thread may prepare diagnostics only under the current opt-in generation.
final class DiagnosticRecordingState: Sendable {
    private let enabledGeneration = Mutex<UInt64?>(nil)
    var generation: UInt64? { enabledGeneration.withLock { $0 } }
    func update(_ generation: UInt64?) { enabledGeneration.withLock { $0 = generation } }
}

extension HostConnection {
    /// Sends one diagnostics batch; only to a ready host that advertises `device_diagnostics` (#234). A host that
    /// does not also advertise `device_diagnostics_stream_abandoned` gets `other` for that code (#469): an older
    /// host decodes an unknown token as a malformed frame and closes the connection.
    public func sendDiagnostics(_ events: [DiagnosticEvent]) async throws {
        try requireReady(capability: DiagnosticLimits.capability)
        let accepted = snapshot.capabilities.contains(DiagnosticLimits.streamAbandonedCapability)
        let streamFields = snapshot.capabilities.contains(DiagnosticLimits.playbackStreamCapability)
        let masking = snapshot.capabilities.contains(DiagnosticLimits.replyMaskingCapability)
        let routeSnapshots = snapshot.capabilities.contains(DiagnosticLimits.routeSnapshotCapability)
        let sendable = events.compactMap { event -> DiagnosticEvent? in
            guard !DeviceDiagnostics.shouldOmit(event, routeSnapshots: routeSnapshots, masking: masking),
                  let projected = routeSnapshots ? event : DeviceDiagnostics.withoutRouteSnapshotFields(event)
            else { return nil }
            let compatible = streamFields ? projected : DeviceDiagnostics.withoutPlaybackStreamFields(projected)
            return accepted ? compatible : DeviceDiagnostics.withoutStreamAbandoned(compatible)
        }
        guard !sendable.isEmpty else { return }
        try await send(.diagnostic(events: sendable), generation: generation)
    }
}

/// What the phone itself reports (#234): its build and OS, audio route changes and interruptions, app
/// lifecycle, capture ended by the system, and reply playback. Each source is mapped to enumerated tokens here;
/// no system string is passed through: port types are compared against the `AVAudioSession` constants and every
/// value is checked byte for byte against its field's vocabulary, with `other` for anything else.
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
        .token(value.flatMap { value in field.tokens.contains { DiagnosticLimits.sameBytes($0, value) } ? value : nil }
            ?? "other")
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

    /// An NSError domain as a diagnostics token.
    nonisolated static func errorDomain(_ domain: String) -> String {
        switch domain {
        case NSOSStatusErrorDomain: "coreaudio"
        case "AVFoundationErrorDomain", "com.apple.coreaudio.avfaudio": "avfoundation"
        case NSPOSIXErrorDomain: "posix"
        default: "other"
        }
    }

    /// Reply-status strings the playback controller sets on failure, as tokens. Other statuses are not failures.
    nonisolated static let streamAbandoned = "stream_abandoned"

    /// `event` with `stream_abandoned` replaced by `other`, for a host whose vocabulary predates it.
    nonisolated static func withoutStreamAbandoned(_ event: DiagnosticEvent) -> DiagnosticEvent {
        guard event.fields[.code] == .token(streamAbandoned) else { return event }
        var fields = event.fields
        fields[.code] = .token("other")
        return (try? DiagnosticEvent(event.name, timestamp: event.timestamp, fields: fields)) ?? event
    }

    /// Drop the entire new report for an older strict decoder, including the new reason tokens.
    nonisolated static func isReplyMaskingReport(_ event: DiagnosticEvent) -> Bool {
        event.fields[.masking] != nil || event.fields[.capture] != nil
            || event.fields[.reason].map { value in
                DiagnosticLimits.replyMaskingReasons.contains { value == .token($0) }
            } == true
    }

    nonisolated static func withoutPlaybackStreamFields(_ event: DiagnosticEvent) -> DiagnosticEvent {
        let fields = event.fields.filter { !DiagnosticLimits.playbackStreamFields.contains($0.key) }
        // Removing validated fields cannot invalidate the event.
        return (try? DiagnosticEvent(event.name, timestamp: event.timestamp, fields: fields)) ?? event
    }

    nonisolated static func playbackFailure(_ status: String) -> String? {
        [
            ReplyPlaybackController.playbackFailed: "playback_failed", "Playback could not resume": "resume_failed",
            "Replay failed": "replay_failed", ReplyPlaybackController.audioFormatNotPlayable: "format_unplayable",
            ReplyPlaybackController.audioCouldNotBeDecoded: "format_unplayable",
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

    /// Playback busy edges retain their legacy `on` shape. Effective masking is a separate, gated report
    /// from the capture guard; busy alone does not imply that samples were zeroed.
    public func watch(_ playback: ReplyPlaybackController) {
        // A stream ended for want of its terminal marker (#469) is recorded when it happens, not from its status,
        // which a presentation trim can drop before this observer runs. Its own code, `stream_abandoned`, goes
        // only to a host that advertises it (#476); `sendDiagnostics` sends `other` to any other host.
        playback.onStreamAbandoned = { [weak self, weak playback] in
            self?.recordStreamAbandoned(playback)
        }
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
        (playback.player as? EchoGuardedReplyPlayer)?.flushMaskingDiagnostics()
        if busy != lastPlayback.busy {
            // Gaps heard since playback began (#737), from a player that counts them: how many, and their total
            // length. Anything counted while not busy (idle) was never heard, so a start drops it.
            let reporter = (playback.player as? any PlayoutGapReporting)
                ?? (playback.player as? EchoGuardedReplyPlayer)?.gapReporter
            let gaps = reporter?.takePlayoutGaps()
            if busy {
                recordPlaybackStart(playback)
            } else if let gaps {
                record(.replyPlaybackEnd, [.count: .integer(Int64(gaps.count)), .ms: .integer(gaps.milliseconds)])
            } else {
                record(.replyPlaybackEnd)
            }
            let tail = Int64(AmbientReplyEchoGuard.defaultTail / .milliseconds(1))
            record(.echoGuard, busy ? [.on: .boolean(true)] : [.on: .boolean(false), .ms: .integer(tail)])
        }
        for failure in failures.subtracting(lastPlayback.failures).sorted() {
            let code = String(failure.split(separator: "|").last ?? "other")
            var fields: [DiagnosticField: DiagnosticValue] = [.code: .token(code)]
            // Which call failed, by domain and numeric code only, so a device failure can be diagnosed (#282).
            if code == "playback_failed", let error = playback.lastPlaybackError {
                fields[.domain] = .token(Self.errorDomain(error.domain))
                fields[.error] = .integer(Int64(error.code))
            }
            record(.replyPlaybackError, fields)
        }
        lastPlayback = (busy, failures)
    }

    private func recordStreamAbandoned(_ playback: ReplyPlaybackController?) {
        var fields = playback?.abandonedStreamDiagnostics() ?? [:]
        fields[.code] = .token(Self.streamAbandoned)
        fields[.ms] = .integer(Int64(ReplyPlaybackController.streamIdleTimeout / .milliseconds(1)))
        record(.replyPlaybackError, fields)
    }

    static let backgroundNotification = Notification.Name("UIApplicationDidEnterBackgroundNotification")
    static let foregroundNotification = Notification.Name("UIApplicationWillEnterForegroundNotification")

    /// Route changes, interruptions, media-services resets, app background and foreground, and capture ended by
    /// the system, from `center`. Call once; the observers live as long as this log.
    public func observeSystem(center: NotificationCenter = .default) {
        guard observers.isEmpty else { return }
        var names = [AVAudioEngineCapture.endedBySystem, AVAudioEngineCapture.stalled,
                     Self.backgroundNotification, Self.foregroundNotification]
        #if os(iOS)
        names += [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                  AVAudioSession.mediaServicesWereResetNotification]
        #endif
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                #if os(iOS)
                if name == AVAudioSession.routeChangeNotification {
                    guard self?.recordingState.generation != nil else { return }
                    let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                    let previous = AudioRoutePorts(
                        note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
                    )
                    MainActor.assumeIsolated { self?.recordRouteNotification(reason: reason, previous: previous) }
                    return
                }
                #endif
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
        AudioRoutePorts.port(port).rawValue
    }
    #endif

    func handle(_ name: Notification.Name, _ info: [String: UInt]) {
        switch name {
        case AVAudioEngineCapture.endedBySystem: record(.captureState, [.state: .token("ended_by_system")])
        // A capture stall (#443). It reuses the existing vocabulary, so older hosts accept it: `capture_error` with
        // code `other` plus how long nothing arrived and which restart this is. A dedicated token needs a capability.
        case AVAudioEngineCapture.stalled:
            record(.captureError, [
                .code: .token("other"),
                .ms: .integer(Int64(min(info[AVAudioEngineCapture.stalledMillisecondsKey] ?? 0, UInt(Int32.max)))),
                .attempt: .integer(Int64(min(info[AVAudioEngineCapture.restartAttemptKey] ?? 0, UInt(Int32.max))))
            ])
        case Self.backgroundNotification: record(.appBackground)
        case Self.foregroundNotification: record(.appForeground)
        default: handleAudioSession(name, info)
        }
    }

    private func handleAudioSession(_ name: Notification.Name, _ info: [String: UInt]) {
        #if os(iOS)
        switch name {
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

extension DeviceDiagnostics: AudioRouteObservationSink {
    private func updateRouteSink() {
        #if os(iOS)
        AudioRouteObservations.shared.setObserving(self, enabled: isEnabled)
        #endif
    }

    func beginRouteObservation() -> RouteObservationStamp? {
        guard isEnabled, routeSequence < DiagnosticLimits.integers.upperBound else { return nil }
        routeSequence += 1
        return RouteObservationStamp(sequence: routeSequence, timestamp: wallNow(), generation: generation,
                                    hfpPreference: defaults.bool(forKey: AudioInputPreferences.bluetoothHFPDefaultsKey))
    }

    func observe(_ observation: AudioRouteObservation, at stamp: RouteObservationStamp) {
        guard isEnabled, stamp.generation == generation else { return }
        var fields: [DiagnosticField: DiagnosticValue]
        switch observation {
        case .configure(let before, let result, let policyApply, let succeeded):
            fields = result.fields
            before.add(to: &fields, input: .preInput, output: .preOutput,
                       inputCount: .preInputCount, outputCount: .preOutputCount)
            fields[.phase] = .token("configure")
            fields[.policyApply] = .boolean(policyApply)
            fields[.writeSucceeded] = .boolean(succeeded)
        case .decision(let change, let reason, let choseBuiltIn, let appAttributed):
            fields = change.fields
            fields[.decision] = .token(reason.diagnosticToken)
            fields[.userChoseBuiltIn] = .boolean(choseBuiltIn)
            fields[.appAttributed] = .boolean(appAttributed)
        }
        recordRoute(.routeChange, fields: fields, at: stamp)
    }

    /// Even when the backend skips a nested notification or has no active observer, preserve the legacy input.
    func recordRouteNotification(reason: UInt, previous: AudioRoutePorts) {
        guard isEnabled, let current = currentAudioRoute() else { return }
        guard let stamp = beginRouteObservation() else {
            record(.routeChange, [.reason: .token(Self.routeChangeReason(reason)),
                                  .route: .token(current.ports.input.rawValue)])
            return
        }
        let change = AudioRouteChange(reasonRaw: reason, current: current, previous: previous)
        recordRoute(.routeChange, fields: change.fields, at: stamp)
    }

    private func recordPlaybackStart(_ playback: ReplyPlaybackController) {
        guard isEnabled else { return }
        guard let current = currentAudioRoute() else { return record(.replyPlaybackStart) }
        guard let stamp = beginRouteObservation() else {
            return record(.replyPlaybackStart, [.route: .token(current.ports.output.rawValue)])
        }
        var fields = current.fields
        fields[.route] = .token(current.ports.output.rawValue)
        let routed = (playback.player as? any CaptureRoutedReplies)
            ?? (playback.player as? EchoGuardedReplyPlayer)?.gapReporter as? any CaptureRoutedReplies
        if let routed { fields[.captureOwnsEngine] = .boolean(routed.isRoutedThroughCapture) }
        recordRoute(.replyPlaybackStart, fields: fields, at: stamp)
    }

    private func recordRoute(
        _ name: DiagnosticEventName, fields: [DiagnosticField: DiagnosticValue], at stamp: RouteObservationStamp
    ) {
        var fields = fields
        fields[.routeSequence] = .integer(stamp.sequence)
        fields[.hfpPreference] = .boolean(stamp.hfpPreference)
        record(name, fields, timestamp: stamp.timestamp)
    }

    private nonisolated static func isSupplementaryRouteSnapshot(_ fields: [DiagnosticField: DiagnosticValue]) -> Bool {
        fields[.phase] == .token("configure") || fields[.decision] != nil
    }

    fileprivate nonisolated static func shouldOmit(
        _ event: DiagnosticEvent, routeSnapshots: Bool, masking: Bool
    ) -> Bool {
        (!routeSnapshots && isSupplementaryRouteSnapshot(event.fields)) || (!masking && isReplyMaskingReport(event))
    }

    /// Strip the new fields from a notification or playback start that has a legacy shape.
    fileprivate nonisolated static func withoutRouteSnapshotFields(_ event: DiagnosticEvent) -> DiagnosticEvent? {
        guard !DiagnosticLimits.routeSnapshotFields.isDisjoint(with: event.fields.keys) else { return event }
        let fields = event.fields.filter { !DiagnosticLimits.routeSnapshotFields.contains($0.key) }
        return try? DiagnosticEvent(event.name, timestamp: event.timestamp, fields: fields)
    }
}

private extension AudioRoutePorts {
    func add(to fields: inout [DiagnosticField: DiagnosticValue],
             input inputKey: DiagnosticField = .input, output outputKey: DiagnosticField = .output,
             inputCount inputCountKey: DiagnosticField = .inputCount,
             outputCount outputCountKey: DiagnosticField = .outputCount) {
        fields[inputKey] = .token(input.rawValue)
        fields[outputKey] = .token(output.rawValue)
        fields[inputCountKey] = .integer(Int64(inputCount))
        fields[outputCountKey] = .integer(Int64(outputCount))
    }
}

private extension AudioRouteSettings {
    var fields: [DiagnosticField: DiagnosticValue] {
        let categoryToken = switch category {
        case .playAndRecord: "play_and_record"
        case .playback: "playback"
        case .other: "other"
        }
        return [.category: .token(categoryToken), .defaultToSpeaker: .boolean(defaultToSpeaker),
                .allowA2DP: .boolean(allowA2DP), .allowHFP: .boolean(allowHFP), .mixWithOthers: .boolean(mixWithOthers)]
    }
}

private extension AudioRouteSnapshot {
    var fields: [DiagnosticField: DiagnosticValue] {
        var fields = settings.fields
        ports.add(to: &fields)
        return fields
    }
}

private extension AudioRouteChange {
    var fields: [DiagnosticField: DiagnosticValue] {
        var fields = current.fields
        fields[.phase] = .token("change")
        fields[.route] = .token(current.ports.input.rawValue)
        fields[.reason] = .token(DeviceDiagnostics.routeChangeReason(reasonRaw))
        previous.add(to: &fields, input: .previousInput, output: .previousOutput,
                     inputCount: .previousInputCount, outputCount: .previousOutputCount)
        return fields
    }
}

private extension AudioOutputRoutePolicy.DecisionReason {
    var diagnosticToken: String {
        switch self {
        case .repairRequested: "repair_requested"
        case .userChoiceAssumed: "user_choice_assumed"
        case .noHardwareEpisode: "no_hardware_episode"
        case .keepalive: "keepalive"
        case .unsupportedCategory: "unsupported_category"
        case .noExternalEvidence: "no_external_evidence"
        case .externalOutputActive: "external_output_active"
        case .awaitingRoute: "awaiting_route"
        }
    }
}
