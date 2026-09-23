import HailCore
import SwiftUI

extension View {
    func stationCard(minHeight: CGFloat = 320) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct CaptureSafeLabsView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let playback: ReplyPlaybackController

    var body: some View {
        List {
            NavigationLink("Live transcription") {
                if #available(iOS 26.0, *) {
                    TranscriptionLabView(
                        audioSession: audioSession,
                        onCaptureWillBegin: playback.beginCaptureSuppression,
                        onCaptureDidEnd: { playback.endCaptureSuppression(resumingPlayback: $0) }
                    )
                }
            }
            NavigationLink("Routing spike") { RoutingSpikeView() }
        }
        .navigationTitle("Labs")
    }
}
