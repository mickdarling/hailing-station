import SwiftUI

extension StationTranscriptionView {
    var card: some View {
        VStack(spacing: compactTalk ? 10 : 18) {
            // The conversation thread shows each request as You (#318), so no separate last-request panel (#429).
            if !compactTalk, let destinationLabel {
                Label(destinationLabel, systemImage: "desktopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Full screen (#819), one row: talk, its status and Escape. The button keeps the first slot either way,
            // so expanding never rebuilds it.
            let row = compactTalk ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 18))
            row {
                talkButton.disabled(talkSession.owner.map { $0 != captureOwnerID } ?? false)
                if compactTalk { statusRow; escapeControl }
            }

            // Below the button, so its appearing never moves Tap to talk under a finishing tap.
            recoverableTranscript

            // Always mounted (#819 review), so a destination change still clears a paste and a refused one comes
            // back. Full screen it hides only the bare Paste button: an attached paste or a problem still shows.
            pasteControl
                .stationCollapsed(compactTalk && attachedPaste == nil && pasteProblem == nil)

            if !compactTalk { escapeControl; statusRow }
        }
        .padding(compactTalk ? 12 : 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
