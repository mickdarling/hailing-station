import Foundation
import Testing
@testable import HailCore

/// The default order and saved value behind the Bluetooth headset microphone setting, and the output-route
/// guarantees (#879, #890) across the category changes a toggle causes (#905).
struct BluetoothHFPRouteTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test func defaultOrderPutsAnAllowedHeadsetAfterUSBAndWiredButBeforeBuiltIn() {
        let wired = AudioPort(id: "wired", name: "Headset", kind: .wired)
        let allowed = AudioInputPreferences(allowsBluetoothHFP: true)
        #expect(allowed.resolve(from: [.builtIn, .hfp]) == .hfp)
        #expect(allowed.resolve(from: [.builtIn, .hfp, .usb]) == .usb)
        #expect(allowed.resolve(from: [.hfp, wired, .builtIn]) == wired)
        #expect(AudioInputPreferences().resolve(from: [.hfp, .builtIn]) == .builtIn)
        #expect(AudioInputPreferences().resolve(from: [.hfp]) == nil)
    }

    @Test func savedSettingIsOffUntilTheOwnerTurnsItOn() throws {
        let suite = "BluetoothHFPRouteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AudioInputPreferences.saved(in: defaults) == AudioInputPreferences())

        defaults.set(true, forKey: AudioInputPreferences.bluetoothHFPDefaultsKey)
        #expect(AudioInputPreferences.saved(in: defaults) == AudioInputPreferences(allowsBluetoothHFP: true))
        defaults.set(false, forKey: AudioInputPreferences.bluetoothHFPDefaultsKey)
        #expect(AudioInputPreferences.saved(in: defaults).allowsBluetoothHFP == false)
    }

    @Test func togglingNeverUndoesAnOwnersSpeakerChoice() {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.bluetoothA2DP],
                           previousInputs: [.builtInMic], reason: .override))
        #expect(session.state.userChoseBuiltIn)

        for available in [[Policy.Port.builtInMic, .bluetoothHFP], [.builtInMic], [.builtInMic, .bluetoothHFP]] {
            session.send(Self.toggle(available: available))
            session.drainEchoes()
        }
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
    }

    @Test func togglingNeitherRepairsNorSpendsTheNextEpisodesRepair() {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(Self.toggle(available: [.builtInMic]))
        session.send(Self.toggle(available: [.builtInMic, .bluetoothHFP]))
        session.drainEchoes()
        #expect(session.effects.isEmpty)

        let connected = Policy.Route(
            outputs: [.speaker], inputs: [.builtInMic], availableInputs: [.builtInMic, .bluetoothHFP],
            previousOutputs: [.speaker], previousInputs: [.builtInMic], reason: .newDeviceAvailable
        )
        session.overrideOutputs = [.bluetoothA2DP]
        session.send(connected)
        session.drainEchoes()
        let repair: [AudioOutputRouteDriver.Effect] = [.setCategory(.init()), .clearOverride]
        #expect(session.effects == repair)

        for available in [[Policy.Port.builtInMic], [.builtInMic, .bluetoothHFP]] {
            session.send(Self.toggle(available: available, outputs: [.bluetoothA2DP]))
            session.drainEchoes()
        }
        #expect(session.effects == repair)
        #expect(!session.state.userChoseBuiltIn)
    }

    /// The route notification a settings toggle causes: a category change, with the headset listed only while on.
    private static func toggle(available: [Policy.Port], outputs: [Policy.Port] = [.speaker]) -> Policy.Route {
        .init(outputs: outputs, inputs: [.builtInMic], availableInputs: available,
              previousOutputs: outputs, previousInputs: [.builtInMic], reason: .categoryChange)
    }
}
