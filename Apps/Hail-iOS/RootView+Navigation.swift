import HailCore
import SwiftUI
#if os(macOS)
import AppKit
typealias TranscriptPlatformFont = NSFont
#else
import UIKit
typealias TranscriptPlatformFont = UIFont
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
            NavigationStack { content.modifier(ClassicTranscriptSizing()) }
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
            shellSettingsSection
        }
    }

    private var shellSettingsSection: some View {
        List {
            ShellAppearanceEntry()
            NavigationLink { listeningSettingsOverview } label: {
                Label("Listening and attention", systemImage: "ear")
            }
            .accessibilityIdentifier("settings.listening.entry")
            NavigationLink { audioSettingsOverview } label: {
                Label("Audio", systemImage: "waveform")
            }
            .accessibilityIdentifier("station.settings.audio")
            NavigationLink { privacySettingsOverview } label: {
                Label("Privacy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("station.settings.privacy")
            NavigationLink { voicesSettingsOverview } label: {
                Label("Voices and replies", systemImage: "quote.bubble")
            }
            .accessibilityIdentifier("settings.voices.entry")
            NavigationLink { notificationSettingsOverview } label: {
                Label("Notifications and updates", systemImage: "bell")
            }
            .accessibilityIdentifier("settings.notifications.entry")
            NavigationLink { targetsSettingsOverview } label: {
                Label("Targets", systemImage: "scope")
            }
            .accessibilityIdentifier("settings.targets.entry")
            NavigationLink { advancedSettingsOverview } label: {
                Label("Advanced and diagnostics", systemImage: "gearshape")
            }
            .accessibilityIdentifier("settings.advanced.entry")
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
        .navigationTitle(StationSection.settings.title)
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
