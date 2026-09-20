import Testing
@testable import HailCore

struct InputPreferenceResolverTests {
    private let usb = AudioPort(id: "usb", name: "Wireless Mic Rx", kind: .usb)
    private let wired = AudioPort(id: "wired", name: "Headset", kind: .wired)
    private let hfp = AudioPort(id: "hfp", name: "AirPods", kind: .bluetoothHFP)
    private let builtIn = AudioPort(id: "built-in", name: "iPad Microphone", kind: .builtIn)

    @Test func externalUSBWinsRegardlessOfPortOrder() {
        let result = AudioInputPreferences().resolve(from: [builtIn, wired, usb])
        #expect(result == usb)
    }

    @Test func unavailableUSBFallsBackToWiredThenBuiltIn() {
        let preferences = AudioInputPreferences()
        #expect(preferences.resolve(from: [builtIn, wired]) == wired)
        #expect(preferences.resolve(from: [builtIn]) == builtIn)
    }

    @Test func bluetoothHFPRequiresExplicitOptIn() {
        let disabled = AudioInputPreferences(order: [.bluetoothHFP, .builtIn])
        let enabled = AudioInputPreferences(order: [.bluetoothHFP, .builtIn], allowsBluetoothHFP: true)
        #expect(disabled.resolve(from: [hfp, builtIn]) == builtIn)
        #expect(enabled.resolve(from: [hfp, builtIn]) == hfp)
    }

    @Test func noSupportedPortReturnsNilForSystemDefault() {
        let other = AudioPort(id: "other", name: "Unknown", kind: .other)
        #expect(AudioInputPreferences().resolve(from: [other]) == nil)
    }
}
