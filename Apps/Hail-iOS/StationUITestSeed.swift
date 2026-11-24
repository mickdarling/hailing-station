import Foundation
import HailCore
import HailProtocol
import SwiftUI

/// DEBUG builds only (#717): `-seed-conversation N` shows the station chat for an invented thread and fills it with N
/// invented turns through the store's own frame path, 25 ms apart, as a long ambient session does: the owner's sent
/// turns, overheard turns from the owner and a guest, and Haili's replies streaming in. `-seed-overheard-tail K` makes
/// the last K turns a guest's overheard ones, `-seed-tail-ms` apart.
@MainActor
enum StationUITestSeed {
    static let hostID = "ui-test-seed"
    static let targetID = "tmux:ui-test-seed"
    private static var didRun = false

    /// The requested number of turns; nil without the argument and always in a release build.
    static var count: Int? {
        #if DEBUG
        argument("-seed-conversation")
        #else
        return nil
        #endif
    }

    private static func argument(_ name: String) -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    static func runIfRequested(into store: HostConnectionStore) async {
        #if DEBUG
        guard let count, !didRun else { return }
        didRun = true
        let tail = argument("-seed-overheard-tail") ?? 0
        let tailPause = argument("-seed-tail-ms") ?? 25
        for turn in 1...max(count, 1) {
            for frame in frames(turn: turn, overheardOnly: turn > count - tail) {
                store.ingestForUITesting(HostReplyEvent(endpointID: hostID, frame: frame))
                try? await Task.sleep(for: .milliseconds(turn > count - tail ? tailPause : 25))
            }
        }
        #endif
    }

    /// Invented text only. Every fifth turn is long; replies arrive in three growing frames.
    private static func frames(turn: Int, overheardOnly: Bool) -> [Frame] {
        let filler = " The invented weather stays mild and the invented garden needs watering again."
        let text = "Turn \(turn)." + String(repeating: filler, count: turn.isMultiple(of: 5) ? 6 : 1)
        let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
        func frame(_ payload: FramePayload) -> Frame {
            Frame(timestamp: stamp, target: targetID, source: targetID, payload: payload)
        }
        switch overheardOnly ? 2 : turn % 4 {
        case 0: return [frame(.control(.ambientHeard(targetID: targetID, text: text)))]
        case 1: return [frame(.control(.ambientOverheard(targetID: targetID, text: text, speaker: "owner")))]
        case 2:
            return [frame(.control(.ambientOverheard(targetID: targetID, text: text, speaker: "other", name: "Guest")))]
        default:
            let reply = ReplyDescriptor(id: UUID(), hostID: hostID, targetID: targetID)
            let words = text.split(separator: " ")
            return [3, 2, 1].map { part in
                let shown = words.prefix(words.count - (words.count * (part - 1)) / 3).joined(separator: " ")
                return frame(.text(TextPayload(text: shown, isFinal: part == 1, reply: reply)))
            }
        }
    }
}

extension RootView {
    /// The thread the station chat shows: the confirmed destination's, or in a DEBUG UI test the seeded one.
    var chatThread: (hostID: HostEndpoint.Identifier, targetID: String)? {
        if let destination { return (destination.hostID, destination.target.id) }
        return StationUITestSeed.count == nil ? nil : (StationUITestSeed.hostID, StationUITestSeed.targetID)
    }
}

/// DEBUG builds only (#717): how far the chat's scroll offset has ever gone past the end of its content once the chat
/// is longer than its viewport, as the hidden `station.chat.overshoot` element's value, in points. Nothing in release.
struct ChatOvershootProbe: ViewModifier {
    @State private var worst: CGFloat = 0

    func body(content: Content) -> some View {
        #if DEBUG
        if StationUITestSeed.count != nil {
            content
                .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                    guard geometry.contentSize.height > geometry.containerSize.height else { return nil }
                    let end = geometry.contentSize.height - geometry.containerSize.height
                    return geometry.contentOffset.y - end - geometry.contentInsets.bottom
                } action: { _, past in
                    if let past, past > worst { worst = past }
                }
                .background(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("station.chat.overshoot")
                        .accessibilityValue("\(Int(worst.rounded()))")
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
