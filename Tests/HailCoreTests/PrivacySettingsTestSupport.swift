#if os(macOS)
import AppKit
import HailProtocol
import Observation
import SwiftUI
import Testing
@testable import HailCore

/// The production root's exact projection/intent adapter, with observable synthetic preference storage.
@MainActor @Observable
final class PrivacySettingsFixture: PrivacySettingsOwner {
    let connections: HostConnectionStore
    var selectedHostID: HostEndpoint.Identifier?
    var settingsShowOverheard = false { didSet { preferenceWrites.append("show") } }
    var settingsWhoseOverheard = "owner" { didSet { preferenceWrites.append("whose") } }
    var privacySettingsRequest = PrivacySettingsRequestState()
    @ObservationIgnored var preferenceWrites: [String] = []

    init(connections: HostConnectionStore, host: HostEndpoint.Identifier?) {
        self.connections = connections
        selectedHostID = host
    }
}

/// A transport-only fixture. It never requests permissions, constructs audio or opens a network socket.
actor PrivacySettingsTransport: WebSocketTransport {
    let socket: ScriptedSocket
    let declinePrivacy: Bool
    private(set) var privacyAttempts = 0

    init(socket: ScriptedSocket, declinePrivacy: Bool) {
        self.socket = socket
        self.declinePrivacy = declinePrivacy
    }

    func send(_ data: Data) async throws {
        if case .control(.setPrivacy) = try FrameCoding.decode(data).payload {
            privacyAttempts += 1
            if declinePrivacy { throw SocketTestError.unavailable }
        }
        await socket.send(data)
    }
    func receive() async throws -> Data { try await socket.receive() }
    func close() async { await socket.close() }
}

@MainActor
struct PrivacySettingsRig {
    let owner: PrivacySettingsFixture
    let endpoint: HostEndpoint
    let socket: ScriptedSocket
    let transport: PrivacySettingsTransport

    static func ready(capabilities: [String], declinePrivacy: Bool = false) async throws -> Self {
        let address = try #require(URL(string: "ws://127.0.0.1:8765"))
        let endpoint = try HostEndpoint(id: "privacy-fixture", name: "Example Mac", url: address)
        let socket = ScriptedSocket()
        let transport = PrivacySettingsTransport(socket: socket, declinePrivacy: declinePrivacy)
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(transport), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: capabilities, deviceName: "Example Mac")))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
        return Self(owner: PrivacySettingsFixture(connections: store, host: endpoint.id),
                    endpoint: endpoint, socket: socket, transport: transport)
    }

    func confirmPrivateButUnavailable() async throws {
        try await socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { owner.connections.privacySwitch(endpoint.id).isPrivate } }
        let generation = try #require(owner.connections.snapshots[endpoint.id]?.connectionGeneration)
        owner.connections.notePrivateStop(
            HostConnectionFailure.remote("not_allowed: ambient stopped: synthetic unavailable"),
            binding: AmbientAudioBinding(hostID: endpoint.id, targetID: "synthetic-target",
                                         connectionGeneration: generation, selection: 0))
    }

    func scopes() async throws -> [String] {
        try await socket.sentFrames().compactMap {
            if case .control(.overheardScope(let scope)) = $0.payload { scope } else { nil }
        }
    }

    func close() async { await owner.connections.disconnect(endpoint.id) }
}

/// Mount the actual Form and root adapter; only the preference owner and transport are synthetic.
@MainActor
final class NativePrivacySettingsHost {
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init(owner: PrivacySettingsFixture) {
        _ = NSApplication.shared
        hosting = NSHostingView(rootView: AnyView(NavigationStack { owner.privacySettingsOverview }
            .transaction { $0.disablesAnimations = true; $0.animation = nil }))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
    }

    func render() async {
        for _ in 0..<4 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func hide() { hosting.rootView = AnyView(Text("Closed")) }
    func finish() { window.close() }
}
#endif
