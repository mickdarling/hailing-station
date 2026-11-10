import HailCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The redesign's launch flags (#1115), read once per process. A `static let`, not a read in `RootView`'s init or
/// body: SwiftUI can create the root view's value again at any time, and a fresh read after a Labs toggle would swap
/// the whole station mid-session, which ends a capture. A toggle takes effect after the app is relaunched.
@MainActor
enum StationRedesignLaunch {
    static let flags: StationRedesignFlags = {
        let defaults = UserDefaults.standard
        // UI tests start every flag off, before the first frame reads them.
        if ProcessInfo.processInfo.arguments.contains("-reset-station-state") {
            for step in StationRedesignStep.allCases { defaults.removeObject(forKey: step.key) }
        }
        return StationRedesignFlags { defaults.object(forKey: $0) }
    }()

    /// The device family, fixed for the life of the app, never the window width.
    static var idiom: StationNavigationIdiom {
        #if os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }
}

extension RootView {
    /// Today's single station, or with the Shell step on, the native navigation shell around it. The choice is fixed
    /// for the launch. Every owner stays on `RootView` above both branches; the shell only renders `navigation` and
    /// sends its intents back here.
    @ViewBuilder
    var stationRoot: some View {
        if StationRedesignLaunch.flags.isOn(.shell) {
            StationNavigationShell(
                state: navigation, idiom: StationRedesignLaunch.idiom,
                send: { navigation.apply($0) },
                detail: { stationSection($0) },
                inspector: { EmptyView() },
                dock: { _ in EmptyView() }
            )
        } else {
            NavigationStack { content }
        }
    }

    /// The station is today's, unchanged. The other sections push the same tools the station's tool links do, so
    /// each keeps its own back navigation; none holds state of its own.
    @ViewBuilder
    func stationSection(_ section: StationSection) -> some View {
        switch section {
        case .station:
            // The station's tool links open their section rather than push under a station that hides while another
            // section shows (`StationToolLink`). Selecting a section is the only thing the opener can do.
            content.environment(\.stationSectionOpener, StationSectionOpener { navigation.apply(.select($0)) })
        case .sessions:
            // The destination step fills this in. Until then the station's own destination control is the one place
            // to choose a destination.
            ContentUnavailableView {
                Label(section.title, systemImage: section.systemImage)
            } description: {
                Text("Choose a destination from the station. Sessions will be listed here in a later update.")
            }
            .navigationTitle(section.title)
        case .devices:
            List {
                NavigationLink {
                    ConnectivityLabView(store: connections, endpointsChanged: persist)
                } label: {
                    Label("Mac Setup", systemImage: "network")
                }
                .accessibilityIdentifier("station.devices.mac-setup")
            }
            .navigationTitle(section.title)
        case .settings:
            List {
                NavigationLink { AudioDiagnosticsView(model: audioRoutes) } label: {
                    Label("Audio", systemImage: "waveform")
                }
                NavigationLink { CaptureSafeLabsView(audioSession: audioRoutes, playback: playback) } label: {
                    Label("Labs", systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("station.settings.labs")
                NavigationLink {
                    ReplySegmentToolsView(playback: playback, gate: echoGuard.segmentOnsetGate)
                } label: {
                    Label("Turn-taking", systemImage: "pause.circle")
                }
            }
            .navigationTitle(section.title)
        }
    }
}

/// Labs' "Redesign" section: one toggle per merged step. A toggle only writes its step's preference; the app reads
/// it at the next launch, and the row says so until then.
struct StationRedesignLabsSection: View {
    var body: some View {
        Section {
            ForEach(StationRedesignStep.allCases, id: \.self) { StationRedesignToggle(step: $0) }
        } header: {
            Text("Redesign")
        } footer: {
            Text("Each one is off by default and takes effect after you relaunch Hailing Station.")
        }
    }
}

private struct StationRedesignToggle: View {
    let step: StationRedesignStep
    @AppStorage private var isOn: Bool

    init(step: StationRedesignStep) {
        self.step = step
        _isOn = AppStorage(wrappedValue: false, step.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(step.title, isOn: $isOn)
                .accessibilityIdentifier(step.key)
            if isOn != StationRedesignLaunch.flags.isOn(step) {
                Text("Relaunch to apply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(step.key).pending")
            }
        }
    }
}
