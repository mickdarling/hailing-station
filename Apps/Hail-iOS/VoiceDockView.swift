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
    @Environment(\.stationPalette) private var palette
    let state: VoiceDockState
    /// The owner's live caption. It shows only while `state.showsCaption`.
    let caption: String?
    let onIntent: (VoiceDockIntent) -> Void
    var talkIdentifier = "station.voice-dock.talk"
    @Environment(\.horizontalSizeClass) private var widthClass
    private var wide: Bool {
        #if os(macOS)
        true
        #else
        widthClass == .regular
        #endif
    }
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
        .background(palette[.elevatedSurface])
        .overlay(alignment: .top) { Divider().overlay(palette[.separator]) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("station.voice-dock")
    }

    private var liveCaption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Live caption · not sent yet")
                .font(.caption)
                .foregroundStyle(palette[.textSecondary])
            Text(caption.flatMap { $0.isEmpty ? nil : $0 } ?? "Listening…")
                .font(.body)
                .foregroundStyle(palette[.textPrimary])
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
                .foregroundStyle(palette[.brandOnBrand])
                .frame(maxWidth: .infinity, minHeight: target)
        }
        .buttonStyle(.borderedProminent)
        .tint(palette[state.primary == .finish ? .stateLive : .accentTalk])
        .controlSize(.regular)
        .disabled(!state.isEnabled)
        .accessibilityValue(state.value)
        .accessibilityHint(state.hint)
        .accessibilityIdentifier(talkIdentifier)
    }

    private enum AccessoryTitle: String {
        case paste = "Paste"
        case interrupt = "Interrupt"
        case privacy = "Privacy"
        case more = "More controls"

        var compact: String { self == .more ? "More" : rawValue }
    }

    /// Side by side as icons, or, at accessibility sizes, stacked full width with their titles (Codex review of
    /// #1155): three scaled icon targets in a row would push controls off a narrow iPhone.
    private var accessories: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            if state.paste != .hidden {
                iconButton(.paste, symbol: "plus", intent: .paste, item: state.paste,
                           hint: "Opens pasted text for the next request.")
            }
            if wide, state.escape != .hidden {
                iconButton(.interrupt, symbol: "xmark.octagon", intent: .escape, item: state.escape,
                           hint: "Discards any recording and sends Escape to the selected target.")
            }
            if state.privacy != .hidden {
                iconButton(.privacy, symbol: "lock", intent: .privacy, item: state.privacy,
                           hint: "Requests a privacy change when available, or shows listening details.")
            }
            moreMenu
        }
    }

    private func iconButton(
        _ title: AccessoryTitle, symbol: String, intent: VoiceDockIntent, item: VoiceDockState.Item, hint: String
    ) -> some View {
        Button {
            onIntent(intent)
        } label: {
            accessoryLabel(title, symbol: symbol)
        }
        .buttonStyle(.bordered)
        .disabled(item != .enabled)
        .accessibilityHint(hint)
        .accessibilityIdentifier("station.voice-dock.\(intent)")
    }

    private var moreMenu: some View {
        Menu {
            Button("Audio routes", systemImage: "speaker.wave.2") { onIntent(.audioRoutes) }
                .accessibilityIdentifier("station.voice-dock.routes")
            Button("Listening controls", systemImage: "ear") { onIntent(.listeningControls) }
                .accessibilityIdentifier("station.voice-dock.listening")
            if !wide, state.escape != .hidden {
                Divider()
                Button("Interrupt", systemImage: "xmark.octagon", role: .destructive) { onIntent(.escape) }
                    .disabled(state.escape != .enabled)
                    .accessibilityHint("Discards any active recording and sends Escape immediately to the target.")
            }
        } label: {
            accessoryLabel(.more, symbol: "ellipsis")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("station.voice-dock.more")
    }

    @ViewBuilder
    private func accessoryLabel(_ title: AccessoryTitle, symbol: String) -> some View {
        if typeSize.isAccessibilitySize {
            Label(title.rawValue, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: target, alignment: .leading)
        } else if wide {
            Label(title.rawValue, systemImage: symbol)
                .frame(minHeight: target)
        } else {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(title.compact).font(.caption2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title.rawValue)
            .frame(minWidth: target, minHeight: target)
        }
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
