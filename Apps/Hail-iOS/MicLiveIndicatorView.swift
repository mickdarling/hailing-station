import HailCore
import SwiftUI

/// The microphone indicator (#334, #1115): red while recording and while the state is uncertain, clear when off.
/// It renders a `MicLiveState` and nothing else. It has no action, sends no intent and can't change capture.
///
/// Live and uncertain differ in shape as well as wording, so the difference never rests on colour alone: live is a
/// filled red disc, uncertain a dashed red ring. Off keeps its frame, so the layout never jumps, and stays in the
/// accessibility tree as "Microphone off".
struct MicLiveIndicatorView: View {
    enum Style {
        /// The iPhone top bar: the glyph alone.
        case glyph
        /// The Mac and iPad sidebar: the glyph with its wording.
        case row
    }

    let state: MicLiveState
    var style: Style = .glyph
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 22

    var body: some View {
        Group {
            switch style {
            case .glyph:
                glyph
            case .row:
                Label {
                    Text(state.label)
                        .foregroundStyle(state.showsRed ? Color.red : Color.secondary)
                } icon: {
                    glyph
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .accessibilityIdentifier("station.mic-live")
    }

    private var glyph: some View {
        ZStack {
            switch state {
            case .live:
                Circle().fill(Color.red)
                Image(systemName: "mic.fill")
                    .font(.system(size: diameter * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            case .uncertain:
                Circle().strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                Image(systemName: "mic")
                    .font(.system(size: diameter * 0.55, weight: .semibold))
                    .foregroundStyle(Color.red)
            case .off:
                Color.clear
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

#Preview("Microphone indicator · synthetic") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach([MicLiveState.live, .uncertain, .off], id: \.label) { state in
            HStack(spacing: 24) {
                MicLiveIndicatorView(state: state)
                MicLiveIndicatorView(state: state, style: .row)
            }
        }
    }
    .padding()
}
