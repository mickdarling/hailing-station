import SwiftUI

struct TranscriptHeading: View {
    let level: Int
    let text: AttributedString

    var body: some View {
        Text(text)
            .modifier(TranscriptDetailFont(.heading(level)))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct TranscriptDetailFont: ViewModifier {
    enum Style {
        case metadata, code, music, heading(Int)

        func font(in environment: EnvironmentValues) -> Font {
            switch self {
            case .metadata: environment.transcriptFont(.callout, style: .callout)
            case .code: environment.transcriptFont(.footnote, style: .footnote) { $0.monospaced() }
            case .music: environment.transcriptFont(.subheadline, style: .subheadline)
            case .heading(1): environment.transcriptFont(.headline, style: .headline)
            case .heading(2): environment.transcriptFont(.subheadline, style: .subheadline) { $0.weight(.semibold) }
            case .heading: environment.transcriptFont(.footnote, style: .footnote) { $0.weight(.semibold) }
            }
        }
    }

    private let style: Style
    @Environment(\.self) private var environment

    init(_ style: Style) { self.style = style }

    func body(content: Content) -> some View { content.font(style.font(in: environment)) }
}
