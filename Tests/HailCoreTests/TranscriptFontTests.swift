#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore

@MainActor
struct TranscriptFontTests {
    @Test(arguments: [true, false])
    func thePreferenceResizesOnlyMountedClassicTranscriptText(classic: Bool) async throws {
        _ = NSApplication.shared
        let suite = "TranscriptFontTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = ConversationAppearancePreferences(defaults: defaults, platform: .mac)
        let text = Text("A synthetic conversation paragraph")
        let paragraph = TranscriptTestParagraph(text: text).fixedSize()
        let scene = Group {
            if classic { paragraph.modifier(ClassicTranscriptSizing()) } else { paragraph }
        }
        let host = NSHostingView(rootView: scene.font(.largeTitle).modifier(AppearanceSettingsPresentation())
            .environment(appearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        await layout(host)
        let original = host.fittingSize.width
        #expect(original > 0)
        if !classic {
            let inherited = NSHostingView(rootView: text.fixedSize().font(.largeTitle)).fittingSize.width
            #expect(abs(original - inherited) < 1)
        }
        appearance.apply(.larger)
        await layout(host)
        let resized = host.fittingSize.width
        if classic {
            #expect(resized > original)
        } else {
            #expect(abs(resized - original) < 1)
        }
        appearance.apply(.reset)
        await layout(host)
        #expect(abs(host.fittingSize.width - original) < 1)
    }

    private func layout(_ host: NSView) async {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private struct TranscriptTestParagraph: View {
    let text: Text
    @Environment(\.classicTranscriptSize) private var size

    var body: some View { text.classicTranscriptFont(size) }
}
#endif
