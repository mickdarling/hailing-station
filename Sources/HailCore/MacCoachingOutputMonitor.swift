#if os(macOS)
import AppKit
import CoreAudio
import Foundation
import OSLog
import Synchronization

@MainActor struct MacCoachingPropertyRegistration {
    var install: (@escaping @Sendable () -> Void) throws -> (@MainActor () -> Void)

    static func live(object: UInt32, selector: UInt32,
                     scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> Self {
        Self(install: { handler in
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                      mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            guard AudioObjectAddPropertyListenerBlock(object, &address, nil, block) == noErr else {
                throw CoachingSafetyError.unsafeOutput
            }
            return { _ = AudioObjectRemovePropertyListenerBlock(object, &address, nil, block) }
        })
    }
}

private struct MacCoachingLatchState: Sendable {
    var revision = UUID()
    var armed = false
    mutating func retire() -> UUID { revision = UUID(); armed = false; return revision }
}

private final class MacCoachingLatch: Sendable {
    let value = Mutex(MacCoachingLatchState())
}

/// Observes actual fixed bindings and OS terminal evidence, not default-device names or Bluetooth transport.
/// Core Audio property listeners fence on their calling thread before MainActor cleanup.
@MainActor final class MacCoachingOutputMonitor: CoachingOutputMonitoring {
    private let bound: () -> Bool
    private let center: NotificationCenter
    private let state = MacCoachingLatch()
    private var removals: [@MainActor () -> Void] = []
    private var observers: [any NSObjectProtocol] = []
    var onInvalidated: (() -> Void)?

    init(bound: @escaping () -> Bool, registrations: [MacCoachingPropertyRegistration],
         center: NotificationCenter, names: [Notification.Name] = [.AVAudioEngineConfigurationChange],
         workspaceCenter: NotificationCenter? = nil) throws {
        self.bound = bound
        self.center = center
        let log = Logger(subsystem: "com.mickdarling.Hail", category: "coaching-route")
        let handler: @Sendable (String) -> Void = { [weak self, state] cause in
            let (revision, armed) = state.value.withLock { value in
                let armed = value.armed
                return (value.retire(), armed)
            }
            if armed { log.notice("Route event: \(cause, privacy: .public)") }
            Task { @MainActor [weak self] in
                guard let self, self.state.value.withLock({ !$0.armed && $0.revision == revision }) else { return }
                self.onInvalidated?()
            }
        }
        do {
            for registration in registrations {
                removals.append(try registration.install { handler("device-property") })
            }
            for name in names {
                observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    handler("audio-engine-configuration")
                })
            }
            if let workspaceCenter {
                for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                    let cause = name == NSWorkspace.willSleepNotification ? "workspace-sleep" : "workspace-inactive"
                    let observer = workspaceCenter.addObserver(
                        forName: name, object: nil, queue: nil) { _ in handler(cause) }
                    removals.append { workspaceCenter.removeObserver(observer) }
                }
            }
            guard bound() else { throw CoachingSafetyError.unsafeOutput }
        } catch {
            removals.forEach { $0() }
            removals.removeAll()
            observers.forEach(center.removeObserver)
            observers.removeAll()
            throw error
        }
    }

    isolated deinit {
        disarm()
        removals.forEach { $0() }
        observers.forEach(center.removeObserver)
    }

    func arm() throws {
        let revision = state.value.withLock { $0.revision }
        guard bound() else { disarm(ifRevision: revision); throw CoachingSafetyError.unsafeOutput }
        let armed = state.value.withLock { value in
            guard value.revision == revision else { return false }
            value.revision = UUID()
            value.armed = true
            return true
        }
        guard armed else { throw CoachingSafetyError.unsafeOutput }
    }

    func observe() -> CoachingOutputObservation {
        let captured = state.value.withLock { $0 }
        guard captured.armed else { return .unqualified }
        let valid = bound()
        let current = state.value.withLock { $0.armed && $0.revision == captured.revision }
        guard current else { return .unqualified }
        guard valid else { disarm(ifRevision: captured.revision); return .unqualified }
        return .verifiedHeadphones(captured.revision)
    }

    func disarm() { _ = state.value.withLock { $0.retire() } }

    func retains(_ token: UUID) -> Bool { state.value.withLock { $0.armed && $0.revision == token } }

    private func disarm(ifRevision revision: UUID) {
        state.value.withLock { value in
            guard value.revision == revision else { return }
            _ = value.retire()
        }
    }

    static func live(owner: MacCoachingAudioOwner, output: MacCoachingDeviceEvidence) throws -> Self {
        var registrations: [MacCoachingPropertyRegistration] = []
        for device in [output.deviceID, owner.input.deviceID] {
            for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyClass,
                             kAudioDevicePropertyTransportType, kAudioDevicePropertyDeviceUID] {
                registrations.append(.live(object: device, selector: selector))
            }
        }
        registrations.append(.live(object: output.deviceID, selector: kAudioDevicePropertyStreams,
                                   scope: kAudioObjectPropertyScopeOutput))
        registrations.append(.live(object: owner.input.deviceID, selector: kAudioDevicePropertyStreams,
                                   scope: kAudioObjectPropertyScopeInput))
        for stream in output.streams + owner.input.streams {
            registrations.append(.live(object: stream, selector: kAudioStreamPropertyDirection))
            registrations.append(.live(object: stream, selector: kAudioStreamPropertyTerminalType))
        }
        // Output default changes are not selection; retire conservatively while retaining fixed HAL bindings.
        registrations.append(.live(object: UInt32(kAudioObjectSystemObject),
                                   selector: kAudioHardwarePropertyDefaultOutputDevice))
        // A desktop coach must keep listening while the meeting app has focus. Sleep/logout and
        // audio/device changes still revoke it; ordinary application focus is not an audio route.
        return try Self(bound: { owner.isStillBound() }, registrations: registrations,
            center: .default, workspaceCenter: NSWorkspace.shared.notificationCenter)
    }
}
#endif
