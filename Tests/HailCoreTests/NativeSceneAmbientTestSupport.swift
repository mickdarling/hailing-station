#if os(macOS)
import AppKit
import Observation
import SwiftUI
import HailCore
import HailProtocol

/// The real native root retains its scene owner, bindings and observer. Only its surrounding station layout varies.
@MainActor @Observable
final class NativeSceneAmbientProbe {
    enum StationVisibility: Equatable { case unobserved, visible, hidden }
    struct SurfaceMounts: Equatable {
        let appearances: Int
        let disappearances: Int
    }

    var toolShown = false
    var disappearances = 0
    var appearances = 0
    var stationVisibility = StationVisibility.unobserved
    @ObservationIgnored var root: StationRootView?
    private let binding: AmbientAudioBinding

    var surfaceMounts: SurfaceMounts {
        SurfaceMounts(appearances: appearances, disappearances: disappearances)
    }

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
    @Environment(\.stationAccessibilityHidden) private var stationHidden

    var body: some View {
        Group {
            if let probe {
                // macOS retains navigation roots; model the iOS card's visibility while using the real root stack.
                if probe.toolShown {
                    Text("Station")
                } else {
                    root.ambientListeningSurface
                        .onAppear { probe.appearances += 1 }
                        .onDisappear { probe.disappearances += 1 }
                }
            } else { Text("Station") }
        }
        .navigationDestination(isPresented: Binding(get: { probe?.toolShown == true },
                                                   set: { probe?.toolShown = $0 })) { Text("Station tool") }
        .onAppear { probe?.install(root) }
        .onChange(of: stationHidden, initial: true) { _, hidden in
            probe?.stationVisibility = hidden ? .hidden : .visible
        }
    }
}

@MainActor
final class NativeSceneAmbientHost {
    private let hosting: NSHostingView<AnyView>
    private let window: TestHostWindow
    private let resourceFactory: NativeSceneResourceFactory

    var resourceFactoryCalls: Int { resourceFactory.calls }

    init(resources: StationResources, probe: NativeSceneAmbientProbe, width: CGFloat = 760) {
        NativeShellLaunchContext.install()
        window = TestHostWindow(size: NSSize(width: width, height: 620))
        let factory = NativeSceneResourceFactory(resources: resources)
        resourceFactory = factory
        hosting = NSHostingView(rootView: AnyView(StationRootView(selectionStore: RootSelectionStore(),
            makeResources: { factory.make() }).environment(probe).environment(\.scenePhase, .active)
            .environment(\.accessibilityEnabled, true)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }))
        window.mount(hosting)
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
private final class NativeSceneResourceFactory {
    private let resources: StationResources
    private(set) var calls = 0

    init(resources: StationResources) { self.resources = resources }
    func make() -> StationResources {
        calls += 1
        return resources
    }
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
