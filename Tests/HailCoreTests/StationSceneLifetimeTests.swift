#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore

@Suite("Native station scene lifetime", .serialized)
@MainActor
struct StationSceneLifetimeTests {
    @Test func discardedNativeRootInitializersDoNotConstructResources() {
        var count = 0
        for _ in 0..<17 {
            let root = StationRootView(makeResources: { count += 1; return resources() })
            withExtendedLifetime(root) { #expect(count == 0) }
        }
    }

    @Test func nativeRootReevaluationRetainsOneResourceFactoryPerScene() {
        var count = 0
        let makeResources = { count += 1; return resources() }
        let first = NSHostingView(rootView: StationRootView(makeResources: makeResources))
        render(first)
        #expect(count == 1)
        for _ in 0..<17 {
            first.rootView = StationRootView(makeResources: makeResources)
            render(first)
            #expect(count == 1)
        }
        let second = NSHostingView(rootView: StationRootView(makeResources: makeResources))
        render(second)
        #expect(count == 2)
        withExtendedLifetime((first, second)) {}
    }

    @Test func nativeTranscriptionInitializersAndReevaluationDeferCaptureFactory() {
        var count = 0
        let session = ManagedAudioSession(backend: FakeAudioSessionBackend(inputs: []))
        let makeCapture = { count += 1; return FakeAudioCapture() }
        let makeView = {
            StationTranscriptionView(audioSession: session, capture: makeCapture(),
                                     transcriber: TapLifecycleTranscriber())
        }
        for _ in 0..<17 {
            let view = makeView()
            withExtendedLifetime(view) { #expect(count == 0) }
        }
        let first = NSHostingView(rootView: makeView())
        render(first)
        #expect(count == 1)
        for _ in 0..<17 {
            first.rootView = makeView()
            render(first)
            #expect(count == 1)
        }
        let second = NSHostingView(rootView: makeView())
        render(second)
        #expect(count == 2)
        withExtendedLifetime((first, second)) {}
    }
}

@MainActor
private func resources() -> StationResources {
    StationResources(backend: FakeAudioSessionBackend(inputs: []), player: FormatTestPlayer(),
                     keepaliveRenderer: FakeKeepaliveRenderer())
}

@MainActor
private func render<Content: View>(_ host: NSHostingView<Content>) {
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
    host.layoutSubtreeIfNeeded()
}
#endif
