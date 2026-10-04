public import Foundation
public import HailProtocol
import Observation
#if os(iOS)
import AVFAudio
import UIKit
#endif

/// What the phone itself reports (#234): its build and OS, audio route changes and interruptions, app
/// lifecycle, capture ended by the system, and reply playback. Each source is mapped to enumerated tokens here;
/// no system string is passed through unless it is already a short token (a route's port type).
extension DeviceDiagnostics {
    /// App version and build, OS version and device class. Never the device's name.
    public static func appInfo(bundle: Bundle = .main) -> [DiagnosticField: DiagnosticValue] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            .app: token(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            .build: token(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            .os: token("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            .device: .token(deviceClass)
        ]
    }

    /// `value` when it is already a valid token, else `"other"`.
    public nonisolated static func token(_ value: String?) -> DiagnosticValue {
        .token(value.flatMap { DiagnosticLimits.isToken($0) ? $0 : nil } ?? "other")
    }

    /// `AVAudioSession.RouteChangeReason` raw values.
    nonisolated static func routeChangeReason(_ raw: UInt) -> String {
        let names: [UInt: String] = [
            0: "unknown", 1: "new_device_available", 2: "old_device_unavailable", 3: "category_change",
            4: "override", 6: "wake_from_sleep", 7: "no_suitable_route", 8: "route_configuration_change"
        ]
        return names[raw] ?? "reason_\(raw)"
    }

    /// `AVAudioSession.InterruptionReason` raw values.
    nonisolated static func interruptionReason(_ raw: UInt) -> String {
        let names: [UInt: String] = [0: "default", 1: "app_was_suspended", 2: "built_in_mic_muted",
                                     3: "scene_was_backgrounded", 4: "route_disconnected"]
        return names[raw] ?? "reason_\(raw)"
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
            let input = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue
            record(.routeChange, [
                .reason: .token(Self.routeChangeReason(info[AVAudioSessionRouteChangeReasonKey] ?? 0)),
                .route: Self.token(input)
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
