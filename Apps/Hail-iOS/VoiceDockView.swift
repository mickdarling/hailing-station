import HailCore
import SwiftUI

/// The voice dock (#1115): Tap to talk and Finish & send in one place, with Paste, Privacy and More beside it. It
/// renders a `VoiceDockState` and emits `VoiceDockIntent`s. The talk owner keeps the capture, its suppression hooks,
/// the pending send and its timeout; the dock never starts, finishes or discards a capture itself.
///
/// The action row is at least 44 pt tall with 8 pt insets, about 60 pt in all. The live caption adds height only
/// while a capture is active, and at accessibility text sizes the controls stack. It has no keyboard shortcuts, so
/// it never takes Space from text selection or an editor.
struct VoiceDockView: View {
    let state: VoiceDockState
    /// The owner's live caption. It shows only while `state.showsCaption`.
    let caption: String?
    let onIntent: (VoiceDockIntent) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var target: CGFloat = 44

    var body: some View {
        VStack(spacing: 8) {
            if state.showsCaption {
                liveCaption
            }
            let row = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            row {
                primaryButton
                accessories
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var liveCaption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Live caption · not sent yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(caption.flatMap { $0.isEmpty ? nil : $0 } ?? "Listening…")
                .font(.body)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("station.voice-dock.caption")
    }

    private var primaryButton: some View {
        Button {
            if let intent = state.primaryIntent { onIntent(intent) }
        } label: {
            Label(state.label, systemImage: state.symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: target)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.primary == .finish ? .red : .accentColor)
        .controlSize(.regular)
        .disabled(!state.isEnabled)
        .accessibilityValue(state.value)
        .accessibilityHint(state.hint)
        .accessibilityIdentifier("station.voice-dock.talk")
    }

    private var accessories: some View {
        HStack(spacing: 6) {
            if state.paste != .hidden {
                iconButton("Paste text", symbol: "doc.on.clipboard", intent: .paste, item: state.paste,
                           hint: "Opens pasted text for the next request.")
            }
            if state.privacy != .hidden {
                iconButton("Privacy", symbol: "lock", intent: .privacy, item: state.privacy,
                           hint: "Shows the privacy switch and what it covers.")
            }
            moreMenu
        }
    }

    private func iconButton(
        _ title: String, symbol: String, intent: VoiceDockIntent, item: VoiceDockState.Item, hint: String
    ) -> some View {
        Button {
            onIntent(intent)
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(minWidth: target, minHeight: target)
        }
        .buttonStyle(.bordered)
        .disabled(item != .enabled)
        .accessibilityHint(hint)
        .accessibilityIdentifier("station.voice-dock.\(intent)")
    }

    private var moreMenu: some View {
        Menu {
            Button("Audio routes", systemImage: "speaker.wave.2") { onIntent(.audioRoutes) }
            Button("Listening controls", systemImage: "ear") { onIntent(.listeningControls) }
            if state.escape != .hidden {
                Divider()
                Button("Escape", systemImage: "xmark.octagon", role: .destructive) { onIntent(.escape) }
                    .disabled(state.escape != .enabled)
                    .accessibilityHint("Discards any active recording and sends Escape immediately to the target.")
            }
        } label: {
            Label("More controls", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(minWidth: target, minHeight: target)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("station.voice-dock.more")
    }
}

#Preview("Voice dock · synthetic") {
    let label = DestinationLabel(hostName: "Studio", targetName: "build", targetKind: "tmux", targetID: "%1")
    let all = DockAccessories(escape: true, privacy: true, paste: true)
    let talks: [(TalkActivity, DestinationControlState)] = [
        (TalkActivity(phase: .idle, sendPending: false, interrupting: false), .confirmed(label)),
        (TalkActivity(phase: .recording, sendPending: false, interrupting: false), .confirmed(label)),
        (TalkActivity(phase: .idle, sendPending: true, interrupting: false), .confirmed(label)),
        (TalkActivity(phase: .idle, sendPending: false, interrupting: false), .confirming(saved: label)),
        (TalkActivity(phase: .recording, sendPending: false, interrupting: true), .confirmed(label))
    ]
    let states = talks.map { VoiceDockState.resolve(talk: $0.0, destination: $0.1, accessories: all) }
    ScrollView {
        VStack(spacing: 16) {
            ForEach(states.indices, id: \.self) { index in
                VoiceDockView(state: states[index], caption: "Also check what happens after the connection",
                              onIntent: { _ in })
            }
        }
    }
}
