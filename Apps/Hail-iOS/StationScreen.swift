import HailCore
import SwiftUI

/// Only presentation state lives here. The permanent detail hosts the conversation, talk owner and ambient
/// card in fixed slots even while listening details, sheets or another section cover them.
struct StationScreen<Header: View, Listening: View, Pane: View, Dock: View, Routes: View>: View {
    let hasDestination: Bool
    let needsRecovery: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let listening: (TalkCapturePhase?, Binding<Bool>) -> Listening
    @ViewBuilder let pane: (Bool, Bool, @escaping () -> Void) -> Pane
    @ViewBuilder let dock: (@escaping () -> Void, @escaping () -> Void) -> Dock
    @ViewBuilder let routes: () -> Routes
    let recoveryState: (Date, TurnOutcome?) -> RecoverySheetState
    let inspectConnection: () -> Void
    let chooseDestination: () -> Void
    @State private var listeningDetails = false
    @State private var sheet: Sheet?
    @State private var afterRecovery: RecoveryIntent?
    @State private var report: StationTalkReport?
    @State private var dockHeight: CGFloat = 64
    @Environment(\.stationPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Sheet: String, Identifiable {
        case recovery, routes
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                GeometryReader { space in
                    ScrollView {
                        VStack(spacing: 0) {
                            header()
                            Divider()
                            listening(talkPhase, $listeningDetails)
                            Divider()
                            pane(listeningDetails, showRecovery) { sheet = .recovery }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(height: fitsPane ? max(280, space.size.height) : nil)
                        .frame(minHeight: space.size.height, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                // At AX sizes and in short windows the dock can grow beyond the remaining height.
                // One permanent scroll container keeps all actions reachable without replacing the owner.
                ScrollView {
                    dock({ listeningDetails = true }, { sheet = .routes })
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                }
                .contentMargins(.vertical, 0, for: .scrollContent)
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("station.dock-scroll")
                .frame(height: min(dockHeight, max(90, viewport.size.height * 0.5)))
            }
        }
        .background(palette[.elevatedSurface])
        .onPreferenceChange(StationTalkReportKey.self) { report = $0 }
        .sheet(item: $sheet, onDismiss: completeRecoveryIntent) { selection in
            NavigationStack {
                Group {
                    switch selection {
                    case .routes: routes().navigationTitle("Audio routes")
                    case .recovery:
                        TimelineView(.periodic(from: .now, by: 1)) { tick in
                            RecoverySheetView(state: recoveryState(tick.date, report?.turn)) {
                                afterRecovery = $0
                                sheet = nil
                            }
                        }
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            }
            .frame(minWidth: 280, minHeight: 320)
        }
    }

    private var fitsPane: Bool {
        hasDestination && !listeningDetails && !typeSize.isAccessibilitySize
    }

    private var talkPhase: TalkCapturePhase? {
        hasDestination ? report?.phase : .idle
    }

    private var showRecovery: Bool {
        if needsRecovery { return true }
        switch report?.turn {
        case .noReplyYet, .refused, .sentUnverified, .notSent: return true
        default: return false
        }
    }

    private func completeRecoveryIntent() {
        defer { afterRecovery = nil }
        switch afterRecovery {
        case .inspectConnection: inspectConnection()
        case .chooseDestination: chooseDestination()
        case .openListening: listeningDetails = true
        case nil: break
        }
    }
}
