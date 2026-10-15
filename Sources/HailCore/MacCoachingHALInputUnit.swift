#if os(macOS)
import AudioToolbox
import AVFAudio
import OSLog

private let inputLifetimeLog = Logger(subsystem: "com.mickdarling.Hail", category: "coaching-route")

/// Dedicated input-only AUHAL. Successful disposal closes ownership; failed disposal quarantines it.
@MainActor final class MacCoachingHALInputUnit {
    let unit: AudioUnit
    private let driver: MacCoachingHALInputDriver
    private let cleanup: MacCoachingInputCleanup
    private enum Lifetime { case open, closing, closed, quarantined }
    private var lifetime = Lifetime.open
    private var context: MacCoachingHALInputDelivery?
    private var prepared = false
    private var started = false

    init(driver: MacCoachingHALInputDriver = .live, cleanup: MacCoachingInputCleanup = .shared) throws {
        guard !cleanup.requiresAppRestart else { throw CoachingSafetyError.unsafeOutput }
        self.driver = driver; self.cleanup = cleanup
        unit = try driver.create()
        do {
            guard driver.setScalar(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, 1) == noErr,
                  driver.setScalar(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, 0) == noErr,
                  driver.scalar(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1) == 1,
                  driver.scalar(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0) == 0,
                  running() == 0 else { throw CoachingSafetyError.unsafeOutput }
        } catch { close(); throw error }
    }
    isolated deinit { close() }

    var binding: MacCoachingBindingOperations {
        .init(running: { self.started || self.running() != 0 }, setDevice: { device in
            guard self.lifetime == .open, !self.prepared, !self.started,
                  self.driver.setScalar(self.unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, device) == noErr else { throw CoachingSafetyError.unsafeOutput }
        }, currentDevice: {
            guard self.lifetime == .open, !self.started || self.running() == 1 else { return nil }
            return self.driver.scalar(self.unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0)
        })
    }

    func inputFormat() throws -> AVAudioFormat {
        guard lifetime == .open, !prepared, !started,
              let hardware = driver.format(unit), hardware.mSampleRate.isFinite,
              (16_000...192_000).contains(hardware.mSampleRate), (1...2).contains(hardware.mChannelsPerFrame),
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate,
                                         channels: hardware.mChannelsPerFrame) else {
            throw CoachingSafetyError.unsafeOutput
        }
        return format
    }

    func prepare(format: AVAudioFormat, callback: AURenderCallbackStruct,
                 context: MacCoachingHALInputDelivery) throws {
        guard lifetime == .open, !prepared, !started else { throw CoachingSafetyError.unsafeOutput }
        self.context = context // Retain before native code can store or invoke the callback.
        guard driver.prepare(unit, format, callback) == noErr, driver.initialize(unit) == noErr else {
            close(); throw CoachingSafetyError.unsafeOutput
        }
        prepared = true
    }

    func start() throws {
        guard lifetime == .open, prepared, !started, running() == 0 else { throw CoachingSafetyError.unsafeOutput }
        started = true
        guard driver.start(unit) == noErr, running() == 1 else { close(); throw CoachingSafetyError.unsafeOutput }
    }

    @discardableResult func close() -> Bool {
        guard lifetime == .open else { return lifetime == .closed }
        lifetime = .closing // Retire native authority before any callback-capable teardown operation.
        context?.retire()
        let stopped = driver.stop(unit), uninitialized = driver.uninitialize(unit)
        let disposed = driver.dispose(unit)
        if disposed == noErr {
            lifetime = .closed; started = false; context = nil
            if stopped != noErr || uninitialized != noErr {
                inputLifetimeLog.notice("Microphone teardown recovered through successful disposal")
            }
            return true
        }
        lifetime = .quarantined // Never claim disposed, release callback ownership or retry an uncertain unit.
        cleanup.hold(unit, driver: driver, context: context)
        context = nil // The process-lifetime quarantine now owns the native capability and callback context.
        inputLifetimeLog.error("Microphone disposal unconfirmed; retained until app exit")
        return false
    }

    private func running() -> UInt32? {
        guard lifetime == .open,
              let value = driver.scalar(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0),
              value <= 1 else { return nil }
        return value
    }
}
#endif
