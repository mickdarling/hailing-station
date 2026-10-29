import HailCore
import HailProtocol
import SwiftUI

// Only peripheral UI/platform work is replaced. Both shipped initializers, their stored wrappers,
// the owner, the resource construction, and the native view bodies compile from symlinked app sources.
@MainActor
enum StationPlatform {
    static var ambientCaptureMode: AmbientCaptureMode { .plain }
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

extension StationRootView {
    var content: some View { NativeSceneStationContent(root: self) }
    var destination: Destination? {
        guard let binding = ambientDestinationBinding, let host = connections.snapshots[binding.hostID],
              let target = host.targets.first(where: { $0.id == binding.targetID }) else { return nil }
        return Destination(endpoint: host.endpoint, target: target)
    }
    func acceptAppliedAmbientRestore() -> Bool { false }
    func performAmbientNoticeAction(_ action: AmbientRestorePresentation.NoticeAction) {}
    func reconcileRememberedSelection() async {}
    func restoreSelectionOnce() async {}
    func withLocalHost(_ hosts: [HostEndpoint]?) async -> [HostEndpoint]? { nil }
    func forgetSelection() async {}
    func startAnnouncer() {}
}

extension EnvironmentValues {
    var stationCompactTalk: Bool {
        get { false }
        set { _ = newValue }
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
