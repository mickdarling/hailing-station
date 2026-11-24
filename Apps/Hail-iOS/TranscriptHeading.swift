import SwiftUI
#if os(macOS)
import AppKit
private typealias HeadingPlatformFont = NSFont
#else
import UIKit
private typealias HeadingPlatformFont = UIFont
#endif

struct TranscriptHeading: View {
    let level: Int
    let text: AttributedString
    @Environment(\.classicTranscriptSize) private var size
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private var font: Font {
        switch level {
        case 1: scaled(.headline, style: .headline)
        case 2: scaled(.subheadline.weight(.semibold), style: .subheadline)
        default: scaled(.footnote.weight(.semibold), style: .footnote)
        }
    }

    private func scaled(_ font: Font, style: HeadingPlatformFont.TextStyle) -> Font {
        guard let size, !size.preference.isDefault else { return font }
        let scale = size.preference.scale
        if #available(iOS 26, macOS 26, *) { return font.scaled(by: scale) }
        // On earlier releases, resolve the native text style at the current category before applying Aa once.
        #if os(macOS)
        let native = NSFont.preferredFont(forTextStyle: style, options: [:])
        #else
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let native = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        #endif
        return .system(size: native.pointSize * scale, weight: .semibold)
    }
}
