#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore

@Suite("Native station scene lifetime", .serialized)
@MainActor
struct StationSceneLifetimeTests {
    init() { NativeShellLaunchContext.install() }

    @Test func nativeRootUsesTheGenuineDefaultOffLaunchSnapshot() {
        #expect(!NativeShellLaunchContext.optedIn, "Default-off fixtures run without the dedicated opt-in")
        #expect(!StationRedesignLaunch.flags.isOn(.shell), "The actual default snapshot must stay off")
    }

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
            NativeTalkWindow(audioSession: session, makeCapture: makeCapture)
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
private struct NativeTalkWindow: View {
    let station: StationTranscriptionView
    let labs: StationTranscriptionView
    @State var talkSession: StationTalkSession

    init(audioSession: ManagedAudioSession, makeCapture: @escaping @MainActor () -> FakeAudioCapture) {
        station = StationTranscriptionView(audioSession: audioSession, onFinalized: { _, _ in })
        labs = StationTranscriptionView(audioSession: audioSession)
        _talkSession = State(initialValue: StationTalkSession {
            TranscriptionResources(capture: makeCapture(), transcriber: TapLifecycleTranscriber())
        })
    }

    var body: some View {
        VStack {
            station
            labs
        }
        .sharingTalkSession(talkSession)
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
