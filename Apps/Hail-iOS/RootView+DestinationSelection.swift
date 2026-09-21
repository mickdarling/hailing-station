import HailCore
import HailProtocol

extension RootView {
    var availableDestinations: [Destination] {
        connections.hosts.flatMap { host in
            guard host.state == .ready else { return [Destination]() }
            return host.targets.filter(\.alive).map {
                Destination(endpoint: host.endpoint, target: $0)
            }
        }
    }

    var destination: Destination? {
        guard selectionAuthorizedForReadyConnection,
              let selectedHostID, let selectedTargetID, let rememberedSelection else { return nil }
        return availableDestinations.first {
            $0.hostID == selectedHostID && $0.target.id == selectedTargetID
                && rememberedSelection.matches(endpoint: $0.endpoint, target: $0.target)
        }
    }

    @MainActor
    func select(_ option: Destination) async {
        selectionRevision &+= 1
        let revision = selectionRevision
        do {
            try await connections.selectTarget(host: option.hostID, targetID: option.target.id)
            guard selectionRevision == revision else { return }
            selectedHostID = option.hostID
            selectedTargetID = option.target.id
            let selection = DestinationSelection(
                hostID: option.hostID,
                hostURL: option.endpoint.url.absoluteString,
                targetID: option.target.id,
                targetName: option.target.name
            )
            rememberedSelection = selection
            selectionAuthorizedForReadyConnection = true
            await selectionStore.save(selection)
        } catch {
            guard selectionRevision == revision else { return }
            await forgetSelection()
        }
    }

    @MainActor
    func restoreSelectionOnce() async {
        guard !didRestoreSelection else { return }
        didRestoreSelection = true
        rememberedSelection = await selectionStore.load()
        await reconcileRememberedSelection()
    }

    @MainActor
    func reconcileRememberedSelection() async {
        guard didRestoreSelection, !isRestoringSelection, let rememberedSelection else { return }
        guard let host = connections.hosts.first(where: {
            rememberedSelection.matches(endpoint: $0.endpoint)
        }) else {
            if didRestoreHosts { await forgetSelection() }
            return
        }
        guard host.state == .ready else {
            selectionAuthorizedForReadyConnection = false
            return
        }
        guard host.receivedTargetList else { return }
        guard let target = host.targets.first(where: {
            rememberedSelection.matches(endpoint: host.endpoint, target: $0)
        }) else {
            await forgetSelection()
            return
        }
        guard !selectionAuthorizedForReadyConnection else { return }

        isRestoringSelection = true
        defer { isRestoringSelection = false }
        let revision = selectionRevision
        do {
            try await connections.selectTarget(host: host.id, targetID: target.id)
            guard selectionRevision == revision,
                  self.rememberedSelection == rememberedSelection,
                  let current = connections.hosts.first(where: { $0.id == host.id }),
                  current.state == .ready,
                  current.targets.contains(where: {
                      rememberedSelection.matches(endpoint: current.endpoint, target: $0)
                  }) else { return }
            selectedHostID = host.id
            selectedTargetID = target.id
            selectionAuthorizedForReadyConnection = true
        } catch {
            guard selectionRevision == revision else { return }
            selectedHostID = nil
            selectedTargetID = nil
            selectionAuthorizedForReadyConnection = false
        }
    }

    @MainActor
    func forgetSelection() async {
        selectionRevision &+= 1
        selectedHostID = nil
        selectedTargetID = nil
        rememberedSelection = nil
        selectionAuthorizedForReadyConnection = false
        await selectionStore.save(nil)
    }
}

struct Destination: Identifiable, Equatable {
    let endpoint: HostEndpoint
    let target: TargetInfo

    var hostID: HostEndpoint.Identifier { endpoint.id }
    var id: String { "\(hostID)|\(target.id)" }
    var label: String { "\(endpoint.name) · \(target.name)" }
}
