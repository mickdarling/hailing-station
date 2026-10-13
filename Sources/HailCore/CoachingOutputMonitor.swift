import Foundation
import Synchronization
#if os(iOS)
import AVFAudio
import UIKit
#endif

struct CoachingObservedPort: Sendable, Equatable {
    let uid: String
    let kind: AudioOutputKind
}

private struct CoachingRouteLatch: Sendable {
    var revision = UUID()
    var armed = false
    var uid: String?

    mutating func retire() -> UUID {
        revision = UUID()
        armed = false
        uid = nil
        return revision
    }
}

private final class CoachingOutputLatch: Sendable {
    let value = Mutex(CoachingRouteLatch())
}

/// Real iOS output observation. Only a single OS-classified wired headphone port is supported.
/// Bluetooth, names, spatial-audio flags and requested routes never establish headphone identity here.
/// The latch fences a notification on its posting thread before actor-delayed teardown runs.
@MainActor
public final class CoachingOutputMonitor {
    private let snapshot: () -> [CoachingObservedPort]
    private let center: NotificationCenter
    private let state = CoachingOutputLatch()
    private var observers: [any NSObjectProtocol] = []
    var onInvalidated: (() -> Void)?

    public convenience init() {
        self.init(snapshot: Self.liveSnapshot, center: .default, names: Self.liveNames)
    }

    init(snapshot: @escaping () -> [CoachingObservedPort], center: NotificationCenter,
         names: [Notification.Name]) {
        self.snapshot = snapshot
        self.center = center
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self, state] _ in
                let revision = state.value.withLock { $0.retire() }
                Task { @MainActor [weak self] in
                    guard let self, self.state.value.withLock({ !$0.armed && $0.revision == revision }) else { return }
                    self.onInvalidated?()
                }
            })
        }
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    /// Explicit host opt-in only. A notification racing the snapshot cannot arm a retired observation.
    func arm() throws {
        let revision = state.value.withLock { $0.revision }
        let outputs = snapshot()
        guard outputs.count == 1, outputs[0].kind == .wiredHeadphones, !outputs[0].uid.isEmpty else {
            disarm()
            throw CoachingSafetyError.unsafeOutput
        }
        let armed = state.value.withLock { value in
            guard value.revision == revision else { return false }
            value.revision = UUID()
            value.uid = outputs[0].uid
            value.armed = true
            return true
        }
        guard armed else { throw CoachingSafetyError.unsafeOutput }
    }

    public func observe() -> CoachingOutputObservation {
        let captured = state.value.withLock { $0 }
        guard captured.armed else { return .unqualified }
        let outputs = snapshot()
        guard outputs.count == 1, outputs[0].kind == .wiredHeadphones, outputs[0].uid == captured.uid else {
            disarm()
            return .unqualified
        }
        guard state.value.withLock({ $0.armed && $0.revision == captured.revision }) else { return .unqualified }
        return .verifiedHeadphones(captured.revision)
    }

    func disarm() { _ = state.value.withLock { $0.retire() } }

    private static func liveSnapshot() -> [CoachingObservedPort] {
        #if os(iOS)
        // Device UIDs remain transient private correlation, never emitted in logs or returned as tokens.
        AVAudioSession.sharedInstance().currentRoute.outputs.map {
            CoachingObservedPort(uid: $0.uid, kind: AudioOutputKind($0.portType))
        }
        #else
        [] // This adapter cannot classify native macOS hardware.
        #endif
    }

    private static var liveNames: [Notification.Name] {
        #if os(iOS)
        [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
         AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification,
         UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
         Notification.Name.AVAudioEngineConfigurationChange]
        #else
        [Notification.Name.AVAudioEngineConfigurationChange]
        #endif
    }
}
