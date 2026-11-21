#if os(macOS)
import Foundation
import HailProtocol
import SwiftUI
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct NativeAdvancedSettingsTests {
    @Test(arguments: [false, true])
    func mountingAndLeavingPreserveTheExistingDiagnosticsOwner(initiallyEnabled: Bool) async throws {
        let suite = "hail-advanced-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if initiallyEnabled { defaults.set(true, forKey: DeviceDiagnostics.enabledKey) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [.app: .token("1.2.3")])
        if initiallyEnabled { log.record(.ambientStart) }
        let originalCount = log.bufferedCount
        let originalGeneration = log.generation
        var pendingNotifications = 0
        log.onPending = { pendingNotifications += 1 }
        let page = overview(log)
        #expect(page.diagnostics === log)
        let host = NativeStationToolHost(page)
        defer { host.finish() }
        try await host.appeared()
        await host.render()
        host.push() // The actual overview disappears beneath an unrelated destination.
        await host.render()
        #expect(log.isEnabled == initiallyEnabled)
        #expect(log.bufferedCount == originalCount)
        #expect(log.generation == originalGeneration)
        #expect(log.observers.isEmpty, "The Settings page must not install system observers")
        #expect(pendingNotifications == 0, "Opening and leaving must not record or flush diagnostic events")
        if initiallyEnabled {
            #expect(defaults.bool(forKey: DeviceDiagnostics.enabledKey))
        } else {
            #expect(defaults.object(forKey: DeviceDiagnostics.enabledKey) == nil,
                    "Visiting the page must not write even the default preference")
        }
    }

    @Test func onlyTheExplicitIntentChangesTheRootSuppliedLogAndClearsItsBuffer() throws {
        let suite = "hail-advanced-intent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [.app: .token("1.2.3")])
        let page = overview(log)
        #expect(!log.isEnabled && log.generation == 0)
        page.apply(.setDiagnosticsEnabled(true))
        #expect(log.isEnabled && log.generation == 1 && log.bufferedCount == 1)
        #expect(defaults.bool(forKey: DeviceDiagnostics.enabledKey))
        log.record(.ambientStart)
        #expect(log.bufferedCount == 2)
        page.apply(.setDiagnosticsEnabled(false))
        #expect(!log.isEnabled && log.generation == 2 && log.bufferedCount == 0)
        #expect(!defaults.bool(forKey: DeviceDiagnostics.enabledKey))
        #expect(!log.hasPending)
    }

    private func overview(_ log: DeviceDiagnostics) -> AdvancedSettingsOverview<Text> {
        AdvancedSettingsOverview(
            diagnostics: log, collectingHostName: nil,
            buildInfo: StationBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "456"
            ])
        ) { Text("Existing tools") }
    }
}
#endif
