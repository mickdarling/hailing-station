import HailCore
import SwiftUI

/// Report the installed owner's activity back to the rail. Preferences disappear with their owning destination.
struct StationTalkReport: Equatable, Sendable {
    var phase: TalkCapturePhase
    var turn: TurnOutcome?
}

struct StationTalkReportKey: PreferenceKey {
    static let defaultValue: StationTalkReport? = nil
    static func reduce(value: inout StationTalkReport?, nextValue: () -> StationTalkReport?) {
        value = nextValue() ?? value
    }
}

extension TranscriptionLabView {
    func renderingDock(_ render: @escaping (TranscriptionLabView) -> AnyView) -> Self {
        var view = self
        view.dock = render
        return view
    }
}

/// Holds only the paste sheet's presentation. All work, including a refusal while the sheet is closed,
/// belongs to the same transcription view that supplied the original station card.
struct StationTalkDock: View {
    let owner: TranscriptionLabView
    let destination: DestinationControlState
    let onPrivacy: () -> Void
    let onListening: () -> Void
    let onRoutes: () -> Void
    @State private var showingPaste = false

    private var phase: TalkCapturePhase {
        .init(starting: owner.isStarting, recording: owner.isRecording,
              finishing: owner.isFinalizing || owner.finishTask != nil)
    }

    private var state: VoiceDockState {
        .resolve(talk: TalkActivity(phase: phase, sendPending: owner.pendingSendID != nil,
                                    interrupting: owner.isInterrupting || owner.interruptTask != nil),
                 destination: destination, accessories: DockAccessories(
                    escape: owner.onEscape != nil, privacy: true,
                    paste: owner.attachedPaste != nil || (owner.pasteOffer.accepts && owner.onFinalized != nil)))
    }

    var body: some View {
        owner.observingPaste(
            VStack(alignment: .leading, spacing: 0) {
                if let problem = owner.pasteProblem {
                    Text(problem).font(.callout).padding(.horizontal)
                } else if owner.attachedPaste != nil {
                    Button("Pasted text attached") { showingPaste = true }.padding(.horizontal)
                }
                if owner.status != "Ready" { owner.statusRow }
                VoiceDockView(state: state, caption: owner.transcript, onIntent: perform,
                              talkIdentifier: "station.talk")
            }
        )
        .preference(key: StationTalkReportKey.self, value: StationTalkReport(
            phase: phase, turn: TurnOutcome.observed(status: owner.status)))
        .sheet(isPresented: $showingPaste) {
            NavigationStack {
                ScrollView { owner.pastePanel.padding() }
                    .navigationTitle("Paste")
                    .toolbar { Button("Done") { showingPaste = false } }
            }
            .frame(minWidth: 260, minHeight: 180)
            .presentationDetents([.medium, .large])
        }
        .onChange(of: owner.destinationID) { showingPaste = false }
    }

    private func perform(_ intent: VoiceDockIntent) {
        switch intent {
        case .talk, .finish:
            if state.primaryIntent == intent { owner.toggleTalk() }
        case .escape:
            if state.escape == .enabled, let action = owner.onEscape { owner.startInterrupt(using: action) }
        case .paste:
            if state.paste == .enabled { showingPaste = true }
        case .privacy: onPrivacy()
        case .listeningControls: onListening()
        case .audioRoutes: onRoutes()
        }
    }
}
