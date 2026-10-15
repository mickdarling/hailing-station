import AVFoundation
import HailCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Platform details shared by the same station view tree (#266).
@MainActor
enum StationPlatform {
    static var isDesktop: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

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
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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

    static var captureMode: AmbientCaptureMode {
        #if os(macOS)
        .plain
        #else
        AmbientCaptureModeResolver.currentMode()
        #endif
    }

    static var isActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
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
    /// macOS station destinations need an explicit return control (#523).
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

    @ViewBuilder func stationHeaderOnly() -> some View {
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
private struct StationToolBackNavigation: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button(action: { dismiss() }) {
                    Label("Back", systemImage: "chevron.left")
                }
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
