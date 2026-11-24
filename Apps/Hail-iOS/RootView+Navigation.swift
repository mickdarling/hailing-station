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
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-reset-station-state") {
            for step in StationRedesignStep.allCases { defaults.removeObject(forKey: step.key) }
            #if DEBUG
            // Seed the same Boolean Labs writes. An argument-domain string would fail the flag's type check
            // and a permanent command-line override would mask the in-app opt-out on relaunch.
            if arguments.contains("-seed-navigation-shell") {
                defaults.set(true, forKey: StationRedesignStep.shell.key)
            }
            #endif
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

extension StationRootView {
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

    /// The station is today's, unchanged. Other sections keep their own back navigation. Settings' Audio overview
    /// reads the same scene-owned model as its existing tool; none of these destinations owns an audio session.
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
            .accessibilityIdentifier("shell.sessions.placeholder")
            .navigationTitle(section.title)
        case .devices, .settings:
            ShellToolList(section: section, destination: shellTool)
        }
    }

    @ViewBuilder
    private func shellTool(_ tool: ShellTool) -> some View {
        switch tool {
        case .setup:
            ConnectivityLabView(store: connections, endpointsChanged: persist)
                .accessibilityIdentifier("station.devices.setup-page")
        case .listening: listeningSettingsOverview
        case .audio: audioSettingsOverview
        case .privacy: privacySettingsOverview
        case .voices: voicesSettingsOverview
        case .notifications: notificationSettingsOverview
        case .targets: targetsSettingsOverview
        case .advanced: advancedSettingsOverview
        case .labs: CaptureSafeLabsView(audioSession: audioRoutes, playback: playback)
        case .turnTaking: ReplySegmentToolsView(playback: playback, gate: echoGuard.segmentOnsetGate)
        }
    }
}

private enum ShellTool: Hashable {
    case setup, listening, audio, privacy, voices, notifications, targets, advanced, labs, turnTaking
}

private struct ShellToolList<Destination: View>: View {
    let section: StationSection
    @ViewBuilder let destination: (ShellTool) -> Destination
    #if os(macOS)
    @State private var selected: ShellTool?
    #endif

    var body: some View {
        List {
            if section == .devices {
                row(.setup, "Mac Setup", "network", "station.devices.mac-setup")
            } else {
                ShellAppearanceEntry()
                row(.listening, "Listening and attention", "ear", "settings.listening.entry")
                row(.audio, "Audio", "waveform", "station.settings.audio")
                row(.privacy, "Privacy", "hand.raised", "station.settings.privacy")
                row(.voices, "Voices and replies", "quote.bubble", "settings.voices.entry")
                row(.notifications, "Notifications and updates", "bell", "settings.notifications.entry")
                row(.targets, "Targets", "scope", "settings.targets.entry")
                row(.advanced, "Advanced and diagnostics", "gearshape", "settings.advanced.entry")
                row(.labs, "Labs", "wrench.and.screwdriver", "station.settings.labs")
                row(.turnTaking, "Turn-taking", "pause.circle", "station.settings.turn-taking")
            }
        }
        .navigationTitle(section.title)
        #if os(macOS)
        .navigationDestination(item: $selected, destination: destination)
        #endif
    }

    @ViewBuilder
    private func row(_ tool: ShellTool, _ title: LocalizedStringKey, _ symbol: String, _ identifier: String)
        -> some View {
        let label = Label(title, systemImage: symbol)
        #if os(macOS)
        Button { selected = tool } label: {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        #else
        NavigationLink { destination(tool) } label: { label }
            .accessibilityIdentifier(identifier)
        #endif
    }
}

/// Reuses the window-owned presenter added by #1281, outside the hidden station's navigation stack.
private struct ShellAppearanceEntry: View {
    @Environment(\.appearanceSettingsPresented) private var isPresented

    var body: some View {
        Button {
            isPresented.wrappedValue = true
        } label: {
            Label("Appearance", systemImage: "textformat.size")
        }
        .accessibilityIdentifier("station.settings.appearance")
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
