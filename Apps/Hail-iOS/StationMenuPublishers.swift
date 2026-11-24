import HailCore
import SwiftUI

/// The root owns disposal above navigation and publishes its connection and destination to the Mac menu.
struct StationMenuStatusPublisher: ViewModifier {
    let connections: HostConnectionStore
    let destination: String?
    @StateObject private var window: StationWindowAttachment
    @Environment(StationMenuStatus.self) private var status: StationMenuStatus?

    init(connections: HostConnectionStore, destination: String?) {
        self.connections = connections
        self.destination = destination
        _window = StateObject(wrappedValue: StationWindowAttachment(connections))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.stationWindowAttachment, window)
            .background { StationDisposalObserver(attachment: window).frame(width: 0, height: 0) }
            .onChange(of: Snapshot(connections: connections, destination: destination), initial: true) { _, now in
                guard let status, window.attachStationRoot(in: status) else { return }
                status.hostCount = now.hosts
                status.readyHostCount = now.ready
                status.destination = now.destination
            }
    }

    private struct Snapshot: Equatable {
        let hosts: Int
        let ready: Int
        let destination: String?

        @MainActor
        init(connections: HostConnectionStore, destination: String?) {
            hosts = connections.hosts.count
            ready = connections.hosts.filter { $0.state == .ready }.count
            self.destination = destination
        }
    }
}

/// Lets the menu-bar extra turn this card's ambient listening on or off, through the card's own controller, so
/// the menu and the card can never disagree (#266). Without a `StationMenuStatus` it does nothing.
struct StationMenuListeningPublisher: ViewModifier {
    let controller: AmbientListeningController
    let binding: AmbientAudioBinding
    @Environment(\.stationWindowAttachment) private var window
    @Environment(StationMenuStatus.self) private var status: StationMenuStatus?
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: attach)
            .onChange(of: binding) { _, _ in attach() }
            .onChange(of: Self.phase(controller)) { _, phase in
                if let token { status?.updateListening(phase, token: token) }
            }
            .onDisappear {
                if let token { status?.detachListening(token: token) }
                token = nil
            }
    }

    private func attach() {
        guard let status else { return }
        // A card can appear before its root publishes the first snapshot.
        if let window, !window.attachStationRoot(in: status) { return }
        let (controller, binding) = (controller, binding)
        token = status.attachListening(Self.phase(controller)) { on in
            if on { AmbientStopNotifier.requestAuthorization() }
            Task { on ? await controller.turnOn(for: binding) : await controller.turnOff() }
        }
        window?.listeningToken = token
    }

    /// The same order the card checks: listening, then paused, then moved to another device.
    @MainActor
    private static func phase(_ controller: AmbientListeningController) -> StationMenuStatus.Listening {
        if controller.isListening { return .listening }
        if controller.isOn { return controller.pausedReason == nil ? .starting : .paused }
        if case .movedAway = controller.handoff { return .elsewhere }
        return .off
    }
}

private extension EnvironmentValues {
    @Entry var stationWindowAttachment: StationWindowAttachment?
}

@MainActor
private final class StationWindowAttachment: ObservableObject {
    // Roots replace one another within the single Mac station menu or within one iOS window scene.
    private static let visible = NSMapTable<AnyObject, StationWindowAttachment>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .weakMemory)
    private weak var scope: AnyObject?
    private let connections: HostConnectionStore
    var listeningToken: UUID?

    init(_ connections: HostConnectionStore) { self.connections = connections }

    @discardableResult
    func attachStationRoot(in scope: AnyObject) -> Bool {
        guard !connections.stationSceneDisposed else { return false }
        if Self.visible.object(forKey: scope) === self { return true }
        if let old = self.scope, old !== scope, Self.visible.object(forKey: old) === self {
            Self.visible.removeObject(forKey: old)
        }
        if let previous = Self.visible.object(forKey: scope), previous.connections !== connections {
            previous.stationWindowDisposed()
        }
        self.scope = scope
        Self.visible.setObject(self, forKey: scope)
        (scope as? StationMenuStatus)?.windowOpen = true
        return true
    }

    func stationWindowDisposed() {
        let current = scope.flatMap { Self.visible.object(forKey: $0) }
        // Only reusing the same resources could transfer ownership away from this callback.
        if current !== self, current?.connections === connections { return }
        connections.disposeStationScene()
        guard let scope, current === self else { return }
        Self.visible.removeObject(forKey: scope)
        if let menu = scope as? StationMenuStatus {
            if let listeningToken { menu.detachListening(token: listeningToken) }
            menu.windowOpen = false
        }
    }
}

#if os(macOS)
private typealias StationNativeView = NSView
private struct StationDisposalObserver: NSViewRepresentable {
    let attachment: StationWindowAttachment
    func makeNSView(context: Context) -> StationDisposalView { StationDisposalView(attachment) }
    func updateNSView(_ view: StationDisposalView, context: Context) {}
    static func dismantleNSView(_ view: StationDisposalView, coordinator: ()) {
        view.attachment.stationWindowDisposed()
    }
}
#else
private typealias StationNativeView = UIView
private struct StationDisposalObserver: UIViewRepresentable {
    let attachment: StationWindowAttachment
    func makeUIView(context: Context) -> StationDisposalView { StationDisposalView(attachment) }
    func updateUIView(_ view: StationDisposalView, context: Context) {}
    static func dismantleUIView(_ view: StationDisposalView, coordinator: ()) {
        view.attachment.stationWindowDisposed()
    }
}
#endif

private final class StationDisposalView: StationNativeView {
    let attachment: StationWindowAttachment
    private weak var observed: AnyObject?

    init(_ attachment: StationWindowAttachment) {
        self.attachment = attachment
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe(window, name: NSWindow.willCloseNotification)
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scene = window?.windowScene else { return }
        attachment.attachStationRoot(in: scene)
        observe(scene, name: UIScene.didDisconnectNotification)
    }
    #endif

    private func observe(_ owner: AnyObject?, name: Notification.Name) {
        guard let owner, owner !== observed else { return }
        if let observed { NotificationCenter.default.removeObserver(self, name: name, object: observed) }
        observed = owner
        NotificationCenter.default.addObserver(self, selector: #selector(receivedDisposal(_:)),
                                               name: name, object: owner)
    }

    @objc private func receivedDisposal(_: Notification) { attachment.stationWindowDisposed() }
}
