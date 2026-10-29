#if os(macOS)
import AppKit
import Observation
import SwiftUI
import HailCore
import HailProtocol

/// The real native root retains its scene owner, bindings and observer. Only its surrounding station layout varies.
@MainActor @Observable
final class NativeSceneAmbientProbe {
    var toolShown = false
    var disappearances = 0
    @ObservationIgnored var root: StationRootView?
    private let binding: AmbientAudioBinding

    init(binding: AmbientAudioBinding) { self.binding = binding }

    func install(_ root: StationRootView) {
        guard self.root == nil else { return }
        self.root = root
        root.selectedHostID = binding.hostID
        root.selectedTargetID = binding.targetID
        root.authorizedConnectionGeneration = binding.connectionGeneration
        root.selectionAuthorizedForReadyConnection = true
    }
}

struct NativeSceneStationContent: View {
    let root: StationRootView
    @Environment(NativeSceneAmbientProbe.self) private var probe: NativeSceneAmbientProbe?

    var body: some View {
        Group {
            if let probe {
                // macOS retains navigation roots; model the iOS card's visibility while using the real root stack.
                if probe.toolShown {
                    Text("Station")
                } else {
                    root.ambientListeningSurface.onDisappear { probe.disappearances += 1 }
                }
            } else { Text("Station") }
        }
        .navigationDestination(isPresented: Binding(get: { probe?.toolShown == true },
                                                   set: { probe?.toolShown = $0 })) { Text("Station tool") }
        .onAppear { probe?.install(root) }
    }
}

@MainActor
final class NativeSceneAmbientHost {
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init(resources: StationResources, probe: NativeSceneAmbientProbe) {
        _ = NSApplication.shared
        hosting = NSHostingView(rootView: AnyView(StationRootView(selectionStore: RootSelectionStore(),
            makeResources: { resources }).environment(probe).environment(\.scenePhase, .active)
            .environment(\.accessibilityEnabled, true)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
    }

    /// Flush actual view updates and queued MainActor observer tasks, without elapsed-time waits or sleeps.
    func render() async {
        for _ in 0..<4 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func visibleText() -> [String] { accessibilityText(hosting) }
    func finish() { window.close() }
}

@MainActor
private func accessibilityText(_ value: Any) -> [String] {
    guard let object = value as? NSObject else { return [] }
    func attribute(_ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    let own = [attribute("accessibilityLabel") as? String,
               attribute("accessibilityValue") as? String].compactMap { $0 }
    return own + ((attribute("accessibilityChildren") as? [Any]) ?? []).flatMap(accessibilityText)
}
#endif
