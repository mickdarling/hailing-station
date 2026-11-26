import HailCore
import HailProtocol
import SwiftUI

/// The window supplies these bindings. Browsing a session never establishes selection by itself.
@MainActor
protocol StationDestinationOwner: AmbientDestinationOwner {
    var selectionStore: any DestinationSelectionStoring { get }
    var selectedHostID: HostEndpoint.Identifier? { get nonmutating set }
    var selectedTargetID: String? { get nonmutating set }
    var rememberedSelection: DestinationSelection? { get nonmutating set }
    var selectionAuthorizedForReadyConnection: Bool { get nonmutating set }
    var authorizedConnectionGeneration: UUID? { get nonmutating set }
    var selectionRevision: UInt { get nonmutating set }
    var scenePhase: ScenePhase { get }
    var scenePhaseRevision: UInt { get }
    var didRestoreHosts: Bool { get }
    var didRestoreSelection: Bool { get nonmutating set }
    var isRestoringSelection: Bool { get nonmutating set }
    var showingDestinations: Bool { get nonmutating set }
}

extension StationRootView: StationDestinationOwner {}

extension StationDestinationOwner {
    var availableDestinations: [Destination] {
        connections.hosts.flatMap { host in
            guard host.state == .ready else { return [Destination]() }
            return host.targets.filter(\.alive).map {
                Destination(endpoint: host.endpoint, target: $0)
            }
        }
    }
}

struct Destination: Identifiable, Equatable {
    let endpoint: HostEndpoint
    let target: TargetInfo

    var hostID: HostEndpoint.Identifier { endpoint.id }
    var id: String { "\(hostID)|\(target.id)" }
    var label: String { "\(endpoint.name) · \(target.name)" }

    /// Overheard remarks never went to the target. A reply mirrored into this thread still belongs to its source.
    @MainActor
    func latestMessage(in conversation: ConversationLog) -> ConversationEntry? {
        conversation.entries.last { !$0.overheard && $0.belongs(endpointID: hostID, targetID: target.id) }
    }
}

struct StationSessionsDetail: View {
    let destinations: [Destination]
    let confirmed: Destination?
    let listening: ListeningSettingsState.Activity?
    let conversation: ConversationLog
    let select: @MainActor (Destination) async -> Void

    var body: some View {
        if destinations.isEmpty {
            ContentUnavailableView("No sessions available", systemImage: StationSection.sessions.systemImage,
                                   description: Text("Sessions appear when a connected Mac has a live target."))
                .accessibilityIdentifier("shell.sessions.placeholder")
        } else {
            List(destinations) { option in
                let selected = option == confirmed
                Button {
                    Task { await select(option) }
                } label: {
                    SessionDetailLabel(option: option, selected: selected, listening: selected ? listening : nil,
                                       message: option.latestMessage(in: conversation))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("shell.sessions.row.\(option.id)")
                .listRowBackground(StationRowSurface())
            }
            .accessibilityIdentifier("shell.sessions.list")
        }
    }
}

private struct SessionDetailLabel: View {
    let option: Destination
    let selected: Bool
    let listening: ListeningSettingsState.Activity?
    let message: ConversationEntry?
    @Environment(\.stationPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    identity
                    Spacer(minLength: 16)
                    status
                }
                VStack(alignment: .leading, spacing: 4) {
                    identity
                    status
                }
            }
            if let listening { Text(listening.label).font(.subheadline) }
            if let message {
                Text("Last message · \(ChatTimestamps.header(for: message.date))").font(.caption)
                let text = ConversationChatView.copyable(message)
                if !text.isEmpty {
                    let prefix = text.prefix(140)
                    Text(verbatim: String(prefix) + (prefix.endIndex < text.endIndex ? "…" : ""))
                        .font(.callout).lineLimit(2)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(palette[.textSecondary])
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(option.target.name).font(.headline).foregroundStyle(palette[.textPrimary])
            Text("\(option.endpoint.name) · \(option.stationLabel.role)").font(.subheadline)
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Text("Online")
            if selected {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(palette[.brand])
            }
        }
        .font(.caption.weight(.semibold))
    }
}
