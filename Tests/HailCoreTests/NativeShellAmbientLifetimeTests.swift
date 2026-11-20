#if os(macOS)
import HailCore
import Testing

/// Opt-in, separate process only. AppKit proves the Mac shell; it cannot prove UIKit's iPad stack collapse.
@MainActor
@Suite(.enabled(if: NativeShellLaunchContext.optedIn), .serialized, .timeLimit(.minutes(1)))
struct NativeShellAmbientLifetimeTests {
    @Test func flagOnNativeSectionsKeepTheSameCaptureAndContinueFrameDelivery() async throws {
        let fixture = try await NativeShellLifetimeFixture.start()
        do {
            try await fixture.assertContinuedDelivery()
            for section in [StationSection.devices, .settings, .sessions, .station] {
                try await fixture.select(section)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func actualCardDisappearanceRemountAndSidebarIntentsDoNotStopTheOwner() async throws {
        let fixture = try await NativeShellLifetimeFixture.start()
        do {
            try await removeAndRemountCard(fixture)
            for hidden in [true, false] {
                fixture.root.navigation.apply(.setSidebarHidden(hidden))
                await fixture.host.render()
                try await fixture.assertContinuedDelivery()
            }
            // This exercises the real state model, not an assertion that AppKit displayed an iPad compact stack.
            fixture.root.navigation.apply(.setCompactColumn(.sidebar))
            #expect(fixture.root.navigation.sidebarSelection(collapsed: true) == nil)
            await fixture.host.render()
            try await fixture.assertContinuedDelivery()
            fixture.root.navigation.apply(.setCompactColumn(.detail))
            await fixture.host.render()
            try await fixture.assertContinuedDelivery()
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func removeAndRemountCard(_ fixture: NativeShellLifetimeFixture) async throws {
        let appearances = fixture.probe.appearances
        let disappearances = fixture.probe.disappearances
        fixture.probe.toolShown = true // Removes the actual ambient surface/card and pushes the inert destination.
        await fixture.host.render()
        try await waitUntil { await MainActor.run { fixture.probe.disappearances > disappearances } }
        try await fixture.assertContinuedDelivery()
        fixture.probe.toolShown = false
        await fixture.host.render()
        try await waitUntil { await MainActor.run { fixture.probe.appearances > appearances } }
        try await fixture.assertContinuedDelivery()
    }
}
#endif
