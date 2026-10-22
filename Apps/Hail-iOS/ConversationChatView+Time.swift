import HailCore
import SwiftUI

/// How far a swipe has pulled the thread left to reveal each entry's time (#766), as a fraction of the full reveal:
/// 0 at rest, 1 fully shown. The full reveal is 64 pt at the default text size and grows with Dynamic Type.
private struct ChatTimeRevealKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    fileprivate var chatTimeReveal: CGFloat {
        get { self[ChatTimeRevealKey.self] }
        set { self[ChatTimeRevealKey.self] = newValue }
    }
}

extension ConversationChatView {
    /// A bubble's VoiceOver label with its time (#766): "Haili replied, 9:41 PM", then the bubble's own text.
    static func timedLabel(_ entry: ConversationEntry, thread: String?) -> String {
        "\(youSaid(entry) ?? accessibilityLabel(entry, thread: thread)), \(ChatTimestamps.time(entry.date))"
    }
}

/// A centred header where a group of entries starts (#766): "Today 9:41 PM", "Yesterday 10:02 AM", a weekday, a date.
struct ChatGroupHeader: View {
    let date: Date

    var body: some View {
        Text(ChatTimestamps.header(for: date))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One chat entry with its own time (#766). On iPhone and iPad, as in Messages, the time slides in at the trailing
/// edge while the thread is swiped left (`ChatTimeRevealGesture`); on the Mac it shows when the pointer rests on the
/// entry. VoiceOver reads it in the entry's own label.
struct TimedChatRow<Content: View>: View {
    let date: Date
    @ViewBuilder let content: Content
    @Environment(\.chatTimeReveal) private var reveal
    @ScaledMetric(relativeTo: .caption2) private var width: CGFloat = 64

    var body: some View {
        #if os(macOS)
        content.help(ChatTimestamps.time(date))
        #else
        content
            .offset(x: -reveal * width)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Text(ChatTimestamps.time(date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: (1 - reveal) * width)
                    .opacity(reveal)
                    .accessibilityHidden(true) // Already in the entry's label.
            }
        #endif
    }
}

/// Pulls the whole thread left with the finger while a mostly horizontal swipe lasts, revealing every entry's time,
/// and springs back when it ends or is cancelled (#766): gesture state resets either way, where an `onEnded` reset
/// would leave the thread stuck open after a cancellation. Vertical scrolling and the context menu are untouched.
struct ChatTimeRevealGesture: ViewModifier {
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.3))) private var reveal: CGFloat = 0
    @ScaledMetric(relativeTo: .caption2) private var width: CGFloat = 64

    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        content
            .environment(\.chatTimeReveal, reveal)
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .updating($reveal) { drag, reveal, _ in
                        let (across, down) = (drag.translation.width, drag.translation.height)
                        reveal = across < 0 && abs(across) > abs(down) ? min(-across / width, 1) : 0
                    }
            )
        #endif
    }
}
