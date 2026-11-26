import HailCore
import SwiftUI

/// Report the installed owner's activity back to the rail. Preferences disappear with their owning destination.
struct StationTalkReport: Equatable, Sendable {
    var phase: TalkCapturePhase?
    var turn: TurnOutcome?
}

struct StationTalkReportKey: PreferenceKey {
    static let defaultValue: StationTalkReport? = nil
    static func reduce(value: inout StationTalkReport?, nextValue: () -> StationTalkReport?) {
        value = nextValue() ?? value
    }
}

extension TranscriptionLabView {
    func renderingDock(_ controls: StationDockControls) -> Self {
        var view = self
        view.dock = controls
        return view
    }

    func stationDock(_ controls: StationDockControls) -> some View {
        let talk = dockTalk
        let accessories = DockAccessories(escape: onEscape != nil, privacy: true,
            paste: attachedPaste != nil || (pasteOffer.accepts && onFinalized != nil),
            privacyEnabled: controls.privacy != nil)
        let state = dockState(destination: controls.destination(), accessories: accessories)
        return observingPaste(StationTalkDock(
            state: state, caption: transcript, pasteProblem: pasteProblem, hasPaste: attachedPaste != nil,
            status: {
                if talkStatus != .ready { statusRow }
                if talkStatus == .destinationChanged { unsentTranscript }
            }, openAttachedPaste: { showingDockPaste = true },
            onIntent: { intent in
                switch intent {
                case .talk, .finish:
                    dispatchDockPrimary(intent, destination: controls.destination(), accessories: accessories)
                case .escape:
                    if state.escape == .enabled, let onEscape { startInterrupt(using: onEscape) }
                case .paste: if state.paste == .enabled { showingDockPaste = true }
                case .privacy: controls.privacy?()
                case .listeningControls: controls.listening()
                case .audioRoutes: controls.routes()
                }
            }))
        .preference(key: StationTalkReportKey.self, value: StationTalkReport(
            phase: talk.phase,
            turn: talkStatus.outcome(pasteFailure: pasteRefusalHandling.deliveryFailure)))
        .sheet(isPresented: $showingDockPaste) {
            NavigationStack {
                ScrollView { pastePanel.padding() }
                    .navigationTitle("Paste")
                    .toolbar { Button("Done") { showingDockPaste = false } }
            }
            .frame(minWidth: 260, minHeight: 180)
            .presentationDetents([.medium, .large])
        }
        .onChange(of: destinationID) { showingDockPaste = false }
    }
}

struct StationTalkDock<Status: View>: View {
    let state: VoiceDockState
    let caption: String
    let pasteProblem: String?
    let hasPaste: Bool
    @ViewBuilder let status: () -> Status
    let openAttachedPaste: () -> Void
    let onIntent: (VoiceDockIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pasteProblem {
                Text(pasteProblem).font(.callout).padding(.horizontal)
            } else if hasPaste {
                Button("Pasted text attached", action: openAttachedPaste).padding(.horizontal)
            }
            status()
            VoiceDockView(state: state, caption: caption, onIntent: onIntent, talkIdentifier: "station.talk")
        }
    }
}
