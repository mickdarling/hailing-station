import HailCore
import HailProtocol
import SwiftUI

// Only peripheral UI/platform work is replaced. Both shipped initializers, their stored wrappers,
// the owner, the resource construction, and the native view bodies compile from symlinked app sources.
@MainActor
enum StationPlatform {
    static var voiceOverRunning: Bool { false }
    static func announce(_ text: String) {}
    static func audioSessionBackend() -> any AudioSessionBackend { FakeAudioSessionBackend(inputs: []) }
    static func keepaliveRenderer() -> any BackgroundKeepaliveRendering { FakeKeepaliveRenderer() }
}

struct StationMenuStatusPublisher: ViewModifier {
    let connections: HostConnectionStore
    let destination: String?
    func body(content: Content) -> some View { content }
}

struct ReplySegmentNotices: ViewModifier {
    let connections: HostConnectionStore
    @Binding var banners: AnnouncementBanners
    func body(content: Content) -> some View { content }
}

struct SceneTestDestination { let label: String }

extension StationRootView {
    var content: some View { Text("Station") }
    var destination: SceneTestDestination? { nil }
    func reconcileRememberedSelection() async {}
    func restoreSelectionOnce() async {}
    func withLocalHost(_ hosts: [HostEndpoint]?) async -> [HostEndpoint]? { nil }
    func forgetSelection() async {}
    func startAnnouncer() {}
}

extension EnvironmentValues {
    var stationCompactTalk: Bool {
        get { false }
        set {}
    }
}

extension View {
    func stationCollapsed(_ collapsed: Bool) -> some View { self }
}

extension StationTranscriptionView {
    static var uncorrelatedDestinations: Set<StationConversationDestinationID> = []
    var attachedPaste: PastedDraft? { nil }
    var talkButton: some View { Text(String(describing: type(of: capture))) }
    var statusRow: some View { Text(status) }
    var escapeControl: some View { EmptyView() }
    var liveTranscript: some View { EmptyView() }
    var pasteControl: some View { EmptyView() }
    func observeResults() async {}
    func restorePlaybackAfterForcedTeardown() {}
    func announceDeferredStatusIfNeeded() {}
    func noteReplyArrival(previous: Set<String>, current: Set<String>) {}
    func announceStatusUnlessQuiet(_ status: String) {}
    func announceReplyStatusIfNeeded(_ status: String?) {}
    func announceControlledReplyFailureIfNeeded(_ status: String?) {}
    func announceNewReplyFailures(previous: [String: String], current: [String: String]) {}
    func noteDestinationChange(
        previous: StationConversationDestinationID?, current: StationConversationDestinationID?
    ) {}
    func clearPendingSend() {}
    func finish(force: Bool) async {}
}

struct PasteOffer {}
struct PasteRefusalHandling {}
