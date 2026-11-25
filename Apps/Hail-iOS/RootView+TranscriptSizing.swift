import SwiftUI
#if os(macOS)
import AppKit
typealias TranscriptPlatformFont = NSFont
#else
import UIKit
typealias TranscriptPlatformFont = UIFont
#endif
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
