import AVFoundation
import HailCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Platform details for the one station view tree that builds for iPhone, iPad and Mac (#266).
/// Views call these instead of UIKit or AppKit directly, so the iOS behaviour stays exactly as it was.
@MainActor
enum StationPlatform {
    static var isDesktop: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The iPad all-controls layout (#245); a Mac window always has the room for it.
    static var supportsWideLayout: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    static var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var voiceOverRunning: Bool {
        #if os(macOS)
        NSWorkspace.shared.isVoiceOverEnabled
        #else
        UIAccessibility.isVoiceOverRunning
        #endif
    }

    static func announce(_ text: String) {
        #if os(macOS)
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
        #else
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        #else
        UIPasteboard.general.url = url
        #endif
    }

    /// Headphones keep their A2DP route only without voice processing on iOS (#343). A Mac captures plain, as the
    /// resolver already decides for an iPad app on a Mac: turning voice processing on there raised an uncatchable
    /// exception (#433). The echo guard still silences the mic while replies play.
    static var ambientCaptureMode: AmbientCaptureMode {
        #if os(macOS)
        .plain
        #else
        AmbientCaptureModeResolver.currentMode()
        #endif
    }

    /// Whether the app is in front. Used to decide whether a stop needs a notification.
    static var isActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// iOS keeps a connected station alive in the background with silent audio (#352). A Mac app is not suspended
    /// for being behind another window, so it needs no renderer.
    static func keepaliveRenderer() -> any BackgroundKeepaliveRendering {
        #if os(macOS)
        DesktopKeepalive()
        #else
        SilentAudioKeepalive()
        #endif
    }

    /// iOS configures its shared audio session. A Mac has none: the backend reports the system default route
    /// and never changes it.
    static func audioSessionBackend() -> any AudioSessionBackend {
        #if os(macOS)
        MacDefaultAudioSessionBackend()
        #else
        AVAudioSessionBackend()
        #endif
    }

    nonisolated static func requestMicrophone() async -> Bool {
        #if os(macOS)
        await AVCaptureDevice.requestAccess(for: .audio)
        #else
        await withCheckedContinuation(isolation: nil) { continuation in
            AVAudioApplication.requestRecordPermission { @Sendable granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }
}

extension View {
    /// macOS station destinations need an explicit return control (#523) in place of the overlapping chevron (#528).
    @ViewBuilder func stationToolBackNavigation() -> some View {
        #if os(macOS)
        modifier(StationToolBackNavigation())
        #else
        self
        #endif
    }

    @ViewBuilder func stationInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func stationHiddenNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder func stationURLInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).keyboardType(.URL)
        #else
        self
        #endif
    }

    @ViewBuilder func stationDismissKeyboardOnScroll() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}

#if os(macOS)
/// The Mac's keepalive renderer does nothing: the window's connections stay up on their own (#266).
@MainActor
private final class DesktopKeepalive: BackgroundKeepaliveRendering {
    var onEvent: (@MainActor (BackgroundKeepaliveEvent) -> Void)?
    func start() {}
    func stop(releasingSession: Bool) {}
}

private struct StationToolBackNavigation: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.navigationBarBackButtonHidden(true).safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button("Back", systemImage: "chevron.left") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to Hailing Station")
                .accessibilityIdentifier("station.tool-back")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
#endif
