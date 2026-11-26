import HailCore
import SwiftUI
#if os(macOS)
import AppKit
typealias TranscriptPlatformFont = NSFont
#else
import UIKit
typealias TranscriptPlatformFont = UIFont
#endif

/// Read once per process so rebuilding the root after a Labs toggle cannot replace a running capture (#1115).
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
    /// The launch flag selects the themed shell. Both branches share the same owners on `RootView`.
    @ViewBuilder
    var stationRoot: some View {
        if StationRedesignLaunch.flags.isOn(.shell) {
            let confirmed = destination
            StationNavigationShell(
                state: navigation, idiom: StationRedesignLaunch.idiom, session: confirmed?.stationLabel,
                send: { navigation.apply($0) },
                detail: { stationSection($0, confirmed: confirmed) },
                inspector: { EmptyView() },
                dock: { _ in EmptyView() }
            )
            .environment(\.stationTheme, .astra)
        } else {
            NavigationStack { content.modifier(ClassicTranscriptSizing()) }
        }
    }

    /// Each tool keeps its own back navigation and uses the scene’s existing owners.
    @ViewBuilder
    private func stationSection(_ section: StationSection, confirmed: Destination?) -> some View {
        switch section {
        case .station:
            // The station's tool links can only select their section, keeping pushes out of the hidden station.
            content.environment(\.stationSectionOpener, StationSectionOpener { navigation.apply(.select($0)) })
        case .sessions:
            StationSessionsDetail(destinations: availableDestinations, confirmed: confirmed,
                                  listening: confirmedListeningActivity, conversation: connections.conversation,
                                  select: select)
                .navigationTitle(section.title)
        case .devices:
            #if os(macOS)
            ConnectivityLabView(store: connections, endpointsChanged: persist, showsDevicesPage: true)
            #else
            ShellToolList(section: section, destination: shellTool)
            #endif
        case .settings:
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

private struct ShellToolList<Destination: View>: View {
    let section: StationSection
    @ViewBuilder let destination: (ShellTool) -> Destination
    #if os(macOS)
    @Environment(\.shellDetailPath) private var path
    #endif

    var body: some View {
        List {
            if section == .devices {
                row(.setup, "Mac Setup", "network", "station.devices.mac-setup")
            } else {
                ShellAppearanceEntry()
                    .listRowBackground(StationRowSurface())
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
        .navigationDestination(for: ShellTool.self) { tool in
            switch tool {
            case .setup, .advanced, .labs: destination(tool) // Already scrollable.
            case .listening, .audio, .privacy, .voices, .notifications, .targets, .turnTaking:
                // A non-scrolling Mac Form can size the entire split view taller than its window.
                ScrollView { destination(tool) }
            }
        }
        #endif
    }

    @ViewBuilder
    private func row(_ tool: ShellTool, _ title: LocalizedStringKey, _ symbol: String, _ identifier: String)
        -> some View {
        let label = Label(title, systemImage: symbol)
        #if os(macOS)
        Button { path.wrappedValue.append(tool) } label: {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .listRowBackground(StationRowSurface())
        #else
        NavigationLink { destination(tool) } label: { label }
            .accessibilityIdentifier(identifier)
            .listRowBackground(StationRowSurface())
        #endif
    }
}

extension EnvironmentValues {
    func transcriptFont(_ base: Font, style: TranscriptPlatformFont.TextStyle,
                        formatted: (Font) -> Font = { $0 }) -> Font {
        guard classicTranscriptScale != 1 else { return formatted(base) }
        if #available(iOS 26, macOS 26, *) { return formatted(base).scaled(by: classicTranscriptScale) }
        #if os(macOS)
        let native = NSFont.preferredFont(forTextStyle: style, options: [:])
        #else
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let native = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        #endif
        let points = native.pointSize * classicTranscriptScale
        return formatted(Font(CTFontCreateCopyWithAttributes(native as CTFont, points, nil, nil)))
    }
    var classicNoticeFont: Font { transcriptFont(.footnote, style: .footnote) }
    var classicPasteFont: Font { transcriptFont(.callout, style: .callout) { $0.monospaced() } }
    var classicMessageFont: Font? { classicTranscriptScale == 1 ? nil : transcriptFont(.body, style: .body) }
}

extension Text {
    func classicTranscriptFont(_ override: Font?) -> Text { override.map { font($0) } ?? self }
}

/// Reuses the window-owned presenter added by #1281, outside the hidden station's navigation stack.
private struct ShellAppearanceEntry: View {
    @Environment(\.appearanceSettingsPresented) private var isPresented

    var body: some View {
        Button("Appearance", systemImage: "textformat.size") { isPresented.wrappedValue = true }
            .accessibilityIdentifier("station.settings.appearance")
    }
}
