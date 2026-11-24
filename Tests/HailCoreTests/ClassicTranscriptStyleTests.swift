#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore

@MainActor
struct ClassicTranscriptStyleTests {
    @Test func messageInheritsAtDefaultAndScalesFromBody() throws {
        #expect(EnvironmentValues().classicMessageFont == nil)
        try expectStyle(.body, native: .body) { environment in try #require(environment.classicMessageFont) }
    }

    @Test func noticeKeepsFootnote() throws {
        try expectStyle(.footnote, native: .footnote) { $0.classicNoticeFont }
    }

    @Test func pasteKeepsMonospacedCallout() throws {
        try expectStyle(.callout, native: .callout, formatted: { $0.monospaced() }, font: { $0.classicPasteFont })
    }

    @Test func replyMetadataKeepsCallout() throws {
        try expectStyle(.callout, native: .callout, font: TranscriptDetailFont.Style.metadata.font(in:))
    }

    @Test func rawMetadataAndCodeKeepMonospacedFootnote() throws {
        try expectStyle(.footnote, native: .footnote, formatted: { $0.monospaced() },
                        font: TranscriptDetailFont.Style.code.font(in:))
    }

    @Test func musicKeepsSubheadline() throws {
        try expectStyle(.subheadline, native: .subheadline, font: TranscriptDetailFont.Style.music.font(in:))
    }

    @Test(arguments: 1...6)
    func headingsKeepTheirStyleAndWeight(level: Int) throws {
        let font = TranscriptDetailFont.Style.heading(level).font(in:)
        switch level {
        case 1: try expectStyle(.headline, native: .headline, font: font)
        case 2: try expectStyle(.subheadline, native: .subheadline, formatted: { $0.weight(.semibold) }, font: font)
        default: try expectStyle(.footnote, native: .footnote, formatted: { $0.weight(.semibold) }, font: font)
        }
    }

    private func expectStyle(
        _ base: Font, native style: NSFont.TextStyle, formatted: (Font) -> Font = { $0 },
        font: (EnvironmentValues) throws -> Font
    ) throws {
        let standard = ConversationTextSize(platform: .mac, stored: nil)
        var environment = EnvironmentValues()
        if style != .body { #expect(try font(environment) == formatted(base)) }
        for intent in [ConversationTextSize.Intent.smaller, .larger] {
            let scale = standard.applying(intent).scale
            environment.classicTranscriptScale = scale
            let actual = try font(environment)
            if #available(macOS 26, *) {
                #expect(actual == formatted(base).scaled(by: scale))
                let context = environment.fontResolutionContext
                let body = try #require(environment.classicMessageFont).resolve(in: context)
                let ratio = actual.resolve(in: context).pointSize / body.pointSize
                let original = formatted(base).resolve(in: context).pointSize / Font.body.resolve(in: context).pointSize
                #expect(abs(ratio - original) < 0.01)
            } else {
                let native = NSFont.preferredFont(forTextStyle: style, options: [:])
                let body = NSFont.preferredFont(forTextStyle: .body, options: [:])
                let scaledBody = body.pointSize * scale
                let points = scaledBody * (native.pointSize / body.pointSize)
                let resized = try #require(NSFont(descriptor: native.fontDescriptor, size: points))
                #expect(abs(width(actual) - width(formatted(Font(resized as CTFont)))) < 1)
            }
        }
    }

    private func width(_ font: Font) -> CGFloat {
        let text = Text(verbatim: "iiii WWWW 0123456789").font(font).fixedSize()
        return NSHostingView(rootView: text).fittingSize.width
    }
}
#endif
