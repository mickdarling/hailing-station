#if os(macOS)
import Foundation
import HailProtocol
import Observation
import SwiftUI
@testable import HailCore

/// Owns only synthetic collaborators. No OS permission, audio session, real capture or socket is used.
@MainActor
final class ListeningSettingsAmbientProbe {
    let capture = FakeAudioCapture()
    var permissionDecision: Bool? = true
    private(set) var permissionRequests = 0
    private(set) var streamerCreations = 0
    private(set) var releases = 0
    private var permission: CheckedContinuation<Bool, Never>?

    lazy var controller = AmbientListeningController(
        notificationCenter: NotificationCenter(),
        requestPermission: { [weak self] in await self?.requestPermission() ?? false },
        makeStreamer: { [weak self] send in
            guard let self else { throw CancellationError() }
            streamerCreations += 1
            return AmbientAudioStreamer(capture: capture, send: send)
        },
        releaseSession: { [weak self] in self?.releases += 1 },
        send: { _, _ in }
    )

    private func requestPermission() async -> Bool {
        permissionRequests += 1
        if let permissionDecision { return permissionDecision }
        return await withCheckedContinuation { permission = $0 }
    }

    func resolvePermission(_ allowed: Bool) {
        permissionDecision = allowed
        let waiting = permission
        permission = nil
        waiting?.resume(returning: allowed)
    }

    static var binding: AmbientAudioBinding {
        AmbientAudioBinding(hostID: "example-mac", targetID: "synthetic-target",
                            connectionGeneration: UUID(), selection: 0)
    }
}

@MainActor @Observable
final class ListeningSettingsFixture {
    let store: HostConnectionStore
    @ObservationIgnored var page: ListeningSettingsOverview?
    @ObservationIgnored var navigation: [StationNavigationIntent] = []

    init(store: HostConnectionStore) { self.store = store }
}

/// Installs AppStorage for the exact existing key/default in an isolated suite, as the production root does.
@MainActor
struct ListeningSettingsFixtureView: View {
    let fixture: ListeningSettingsFixture
    @AppStorage private var maskPreference: Bool

    init(fixture: ListeningSettingsFixture, defaults: UserDefaults) {
        self.fixture = fixture
        _maskPreference = AppStorage(wrappedValue: false, "ambient.masksDuringReplies", store: defaults)
    }

    var body: some View {
        let page = ListeningSettingsOverview(connections: fixture.store, masksDuringReplies: $maskPreference) {
            fixture.navigation.append(.select(.station))
        }
        page.onAppear { fixture.page = page }
    }
}
#endif
