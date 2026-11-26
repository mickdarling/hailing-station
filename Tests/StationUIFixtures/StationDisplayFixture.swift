#if STATION_UI_FIXTURES
import HailCore
import SwiftUI

/// The isolated UI-test window uses the same layout and document without station resources.
struct StationDisplayFixture: View {
    let state: StationTranscriptSeed
    @State private var navigation = StationNavigationState()
    private let session = StationTranscriptSeed.session
    private var device: StationNavigationIdiom { StationRedesignLaunch.idiom }

    var body: some View {
        StationNavigationShell(state: navigation, idiom: device, session: session,
                               send: { navigation.apply($0) }, detail: { _ in screen },
                               inspector: { EmptyView() }, dock: { _ in EmptyView() })
            .environment(\.stationTheme, .astra)
    }

    private var screen: some View {
        StationScreen(hasDestination: true, needsRecovery: false, header: {
            HStack(spacing: 0) {
                StationScreenHeader(destination: .confirmed(session), availability: .ready,
                                    showingDestinations: .constant(false), browser: { EmptyView() })
                StationExpandToggle(expanded: Binding(get: { navigation.fullConversation },
                                                      set: { _ in navigation.apply(.toggleFullConversation) }))
                    .padding(.trailing, 12)
            }
        }, listening: { _, details in
            HStack {
                ListeningPrivacyRailView(state: state.rail(on: device), isDetailPresented: details,
                                         listeningDevice: state.listeningPhase == .listening ? deviceTitle : nil)
                Button(state.privacy.isPrivate ? "Leave private mode" : "Go private") {}
                    .buttonStyle(.borderless).disabled(state.privacy.pending)
            }.padding(.horizontal, 12)
        }, pane: { _, _, _ in
            StationConversationPane(hasThread: true, needsSetup: false, playbackHeld: state == .held,
                                    chat: document, fallback: { EmptyView() }, tools: { EmptyView() },
                                    openDevices: {}, showsTools: false, showsRecovery: false, reviewRecovery: {})
        }, dock: { _, _ in
            VoiceDockView(state: state.dock, caption: "Also check what happens after the connection…",
                          onIntent: { _ in }, talkIdentifier: "station.talk")
        }, routes: { EmptyView() }, recoveryState: { _, turn in
            .resolve(availability: .ready, destination: .confirmed(session), privacy: .status(state.privacy),
                     listening: (state.listeningPhase, false), turn: turn)
        }, inspectConnection: {}, chooseDestination: {})
    }

    private var document: some View {
        ConversationDocument(allEntries: state.conversation, hostName: session.hostName,
                             sessions: [session.targetID: session.targetName],
                             audioProblem: state.audioProblem(replyID:), copy: { _ in })
    }

    private var deviceTitle: String {
        switch device {
        case .mac: "Mac"
        case .pad: "iPad"
        case .phone: "iPhone"
        }
    }
}
#endif
