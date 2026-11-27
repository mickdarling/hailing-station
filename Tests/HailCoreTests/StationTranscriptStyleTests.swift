import SwiftUI
import Testing
@testable import HailCore
#if os(macOS)
import AppKit

@MainActor
struct StationTranscriptStyleTests {
    @Test func redesignedRowsKeepTheirBaseStylesWithANondefaultClassicScale() {
        _ = NSApplication.shared
        let text = "A synthetic paragraph with enough words to wrap in the transcript."
        var request = ConversationEntry(id: "request", speaker: .you, text: text,
                                        endpointID: "fixture", targetID: "session", date: .now)
        request.pasted = text
        var reply = ConversationEntry(id: "reply", speaker: .haili, text: text,
                                      endpointID: "fixture", targetID: "session", date: .now)
        reply.metadata = "## Heading\n\n- Example item\n\n```\nexample code\n```"
        var notice = reply
        notice.notice = true
        var music = request
        music.text = "♪ Synthetic lyrics ♪"
        music.overheard = true

        let largest = ConversationTextSize(platform: .mac, stored: ConversationTextSize.Platform.mac.steps.last)
        #expect(largest.scale > 1)
        for entry in [request, reply, notice, music] {
            let row = TranscriptEntryView(entry: entry, turn: TranscriptTurn(entry: entry, sessionName: "Session"),
                                          segments: MessageLinks.segments(entry.text),
                                          audioProblem: nil, copy: { _ in }, present: { _ in })
                .environment(\.stationTheme, .astra)
                .frame(width: 220)
                .fixedSize(horizontal: false, vertical: true)
            let base = NSHostingView(rootView: row).fittingSize.height
            let scaled = NSHostingView(rootView: row.environment(\.classicTranscriptScale, largest.scale))
            #expect(base > 0)
            #expect(abs(scaled.fittingSize.height - base) < 0.5)
        }
    }
}
#endif

// The shared formatting extensions also contain classic-only instance methods. The redesigned row calls
// their shipped static helpers and never constructs the classic view or a player.
@MainActor
struct ConversationChatView {
    let playback: ReplyPlaybackController
    let messageFont: Font?
}

extension StationPlatform {
    static func copy(_ url: URL) {}
}
