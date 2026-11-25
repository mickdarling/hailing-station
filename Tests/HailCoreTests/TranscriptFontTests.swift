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
        let host = NSHostingView(rootView: scene.font(.caption2).modifier(AppearanceSettingsPresentation())
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
        let inherited = NSHostingView(rootView: text.fixedSize().font(.caption2)).fittingSize.width
        #expect(abs(original - inherited) < 1)
        appearance.apply(.larger)
        await layout(host)
        let resized = host.fittingSize.width
        if classic {
            var environment = EnvironmentValues()
            environment.classicTranscriptScale = appearance.state.scale
            let expected = NSHostingView(rootView: text.font(environment.classicMessageFont).fixedSize())
            #expect(abs(resized - expected.fittingSize.width) < 1)
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

    @Test func markdownHeadingsKeepTheirOrderAtEachAaSize() {
        _ = NSApplication.shared
        let heading = AttributedString("Same heading at every level")
        func widths(_ preference: ConversationTextSize?) -> [CGFloat] {
            (1...6).map { level in
                let view = TranscriptHeading(level: level, text: heading)
                    .environment(\.classicTranscriptScale, preference?.scale ?? 1).fixedSize()
                return NSHostingView(rootView: view).fittingSize.width
            }
        }

        let platform = ConversationTextSize.Platform.mac
        let original = widths(nil)
        var previous: [CGFloat]?
        for step in platform.steps {
            let measured = widths(ConversationTextSize(platform: platform, stored: step))
            #expect(measured[0] > measured[1])
            #expect(measured[1] > measured[2])
            #expect(measured[2] > 0)
            #expect(measured.suffix(3).allSatisfy { $0 == measured[2] })
            if step == platform.defaultSize { #expect(measured == original) }
            if let previous {
                for level in measured.indices { #expect(measured[level] > previous[level]) }
            }
            previous = measured
        }
    }
}

private struct TranscriptTestParagraph: View {
    let text: Text
    @Environment(\.classicMessageFont) private var messageFont

    var body: some View { text.classicTranscriptFont(messageFont) }
}
#endif
