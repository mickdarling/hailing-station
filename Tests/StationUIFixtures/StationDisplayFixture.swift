#if STATION_UI_FIXTURES
import HailCore
import SwiftUI

/// The isolated UI-test window uses the same layout and document without station resources.
struct StationDisplayFixture: View {
    let state: StationTranscriptSeed
    @State private var navigation = StationNavigationState()
    @State private var entries: [ConversationEntry]
    @State private var extendDuringDrag = false
    private let session = StationTranscriptSeed.session
    private var device: StationNavigationIdiom { StationRedesignLaunch.idiom }

    init(state: StationTranscriptSeed) {
        self.state = state
        _entries = State(initialValue: state.conversation)
    }

    var body: some View {
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("-measure-station-insets") {
            GeometryReader { viewport in
                let width = min(viewport.size.width, 402)
                let legacy = ProcessInfo.processInfo.arguments.contains("-fixture-empty-dock-inset")
                Group {
                    // Measure the phone tab layout at compact width on both simulator families.
                    if legacy {
                        shell(idiom: .phone) { Group { EmptyView() } }
                    } else {
                        shell(idiom: .phone) { EmptyView() }
                    }
                }
                .environment(\.horizontalSizeClass, .compact)
                .frame(width: width)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1).accessibilityElement()
                        .accessibilityLabel("Window bottom safe area")
                        .accessibilityValue(String(Double(viewport.safeAreaInsets.bottom)))
                        .accessibilityIdentifier("fixture.bottom-inset")
                }
            }
        } else { shell { EmptyView() } }
        #else
        shell { EmptyView() }
        #endif
    }

    private func shell<Dock: View>(idiom: StationNavigationIdiom? = nil,
                                   @ViewBuilder dock: @escaping () -> Dock) -> some View {
        StationNavigationShell(state: navigation, idiom: idiom ?? device, session: session,
                               send: { navigation.apply($0) }, detail: { _ in screen },
                               inspector: { EmptyView() }, dock: { _ in dock() })
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
            let rail = state.rail(on: device)
            let capture = StationListeningCapture(listening: state.listeningPhase, talk: state.talkPhase)
            HStack {
                ListeningPrivacyRailView(state: rail, isDetailPresented: details,
                                         listeningDevice: state.listeningPhase == .listening ? deviceTitle : nil,
                                         barStyle: capture.barStyle(engine: state.inputEngine, rail: rail,
                                                                    privacy: .status(state.privacy)))
                Button(state.privacy.isPrivate ? "Leave private mode" : "Go private") {}
                    .buttonStyle(.borderless).disabled(state.privacy.pending)
            }.padding(.horizontal, 12)
        }, pane: { _, _, _ in
            StationConversationPane(hasThread: true, needsSetup: false, playbackHeld: state == .held,
                                    chat: document, fallback: { scrollControls }, tools: { EmptyView() },
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
        ConversationDocument(allEntries: entries, hostName: session.hostName,
                             sessions: [session.targetID: session.targetName],
                             audioProblem: state.audioProblem(replyID:), copy: { _ in })
            .onScrollPhaseChange { _, phase in
                if extendDuringDrag, phase == .interacting, let last = entries.indices.last {
                    extendDuringDrag = false
                    StationTranscriptSeed.extendReply(&entries[last])
                }
            }
    }

    @ViewBuilder private var scrollControls: some View {
        if state == .scrolling {
            HStack {
                Button("Append turn") { entries.append(StationTranscriptSeed.numberedTurn(entries.count + 1)) }
                Button("Extend reply") {
                    guard let last = entries.indices.last, entries[last].speaker == .haili else { return }
                    StationTranscriptSeed.extendReply(&entries[last])
                }
                .disabled(entries.last?.speaker != .haili)
                Button("Extend on drag") { extendDuringDrag = true }
                    .disabled(entries.last?.speaker != .haili)
            }
        }
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
