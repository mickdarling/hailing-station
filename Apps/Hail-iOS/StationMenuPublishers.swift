import HailCore
import SwiftUI

/// Publishes the station window's connection and destination to the Mac menu-bar extra (#266). Without a
/// `StationMenuStatus` in the environment, as on iPhone and iPad, it does nothing.
struct StationMenuStatusPublisher: ViewModifier {
    let connections: HostConnectionStore
    let destination: String?
    @Environment(StationMenuStatus.self) private var status: StationMenuStatus?

    func body(content: Content) -> some View {
        content
            .onAppear { status?.windowOpen = true }
            .onDisappear { status?.windowOpen = false }
            .onChange(of: Snapshot(connections: connections, destination: destination), initial: true) { _, now in
                status?.hostCount = now.hosts
                status?.readyHostCount = now.ready
                status?.destination = now.destination
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
    @Environment(StationMenuStatus.self) private var status: StationMenuStatus?
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: attach)
            .onChange(of: binding) { _, _ in attach() }
            .onChange(of: controller.isOn) { _, isOn in
                if let token { status?.updateListening(isOn, token: token) }
            }
            .onDisappear {
                if let token { status?.detachListening(token: token) }
                token = nil
            }
    }

    private func attach() {
        guard let status else { return }
        let (controller, binding) = (controller, binding)
        token = status.attachListening(isOn: controller.isOn) { on in
            if on { AmbientStopNotifier.requestAuthorization() }
            Task { on ? await controller.turnOn(for: binding) : await controller.turnOff() }
        }
    }
}
