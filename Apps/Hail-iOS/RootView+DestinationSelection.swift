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
              let authorizedConnectionGeneration,
              let selectedHostID, let selectedTargetID, let rememberedSelection else { return nil }
        return availableDestinations.first {
            $0.hostID == selectedHostID && $0.target.id == selectedTargetID
                && connections.snapshots[$0.hostID]?.connectionGeneration == authorizedConnectionGeneration
                && rememberedSelection.matches(endpoint: $0.endpoint, target: $0.target)
        }
    }

    @MainActor
    func select(_ option: Destination) async {
        selectionRevision &+= 1
        let revision = selectionRevision
        guard let connectionGeneration = connections.snapshots[option.hostID]?.connectionGeneration else {
            return
        }
        do {
            try await connections.selectTarget(host: option.hostID, targetID: option.target.id)
            guard selectionRevision == revision else { return }
            guard let current = connections.snapshots[option.hostID],
                  current.state == .ready,
                  current.connectionGeneration == connectionGeneration else { return }
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
            authorizedConnectionGeneration = connectionGeneration
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
            authorizedConnectionGeneration = nil
            return
        }
        guard host.receivedTargetList else { return }
        guard let target = host.targets.first(where: {
            rememberedSelection.matches(endpoint: host.endpoint, target: $0)
        }) else {
            await forgetSelection()
            return
        }
        if selectionAuthorizedForReadyConnection,
           authorizedConnectionGeneration == host.connectionGeneration { return }
        selectionAuthorizedForReadyConnection = false
        authorizedConnectionGeneration = nil

        await authorizeRememberedSelection(rememberedSelection, host: host, target: target)
    }

    @MainActor
    private func authorizeRememberedSelection(
        _ rememberedSelection: DestinationSelection,
        host: HostConnectionSnapshot,
        target: TargetInfo
    ) async {
        isRestoringSelection = true
        let revision = selectionRevision
        let connectionGeneration = host.connectionGeneration
        do {
            try await connections.selectTarget(host: host.id, targetID: target.id)
        } catch {
            isRestoringSelection = false
            guard selectionRevision == revision else { return }
            selectedHostID = nil
            selectedTargetID = nil
            selectionAuthorizedForReadyConnection = false
            authorizedConnectionGeneration = nil
            if connections.snapshots[host.id]?.connectionGeneration != connectionGeneration {
                Task { await reconcileRememberedSelection() }
            }
            return
        }
        isRestoringSelection = false
        guard selectionRevision == revision,
              self.rememberedSelection == rememberedSelection else { return }
        guard let current = connections.hosts.first(where: { $0.id == host.id }),
              current.state == .ready,
              current.connectionGeneration == connectionGeneration,
              current.targets.contains(where: {
                  rememberedSelection.matches(endpoint: current.endpoint, target: $0)
              }) else {
            selectionAuthorizedForReadyConnection = false
            authorizedConnectionGeneration = nil
            Task { await reconcileRememberedSelection() }
            return
        }
        selectedHostID = host.id
        selectedTargetID = target.id
        selectionAuthorizedForReadyConnection = true
        authorizedConnectionGeneration = connectionGeneration
    }

    @MainActor
    func forgetSelection() async {
        selectionRevision &+= 1
        selectedHostID = nil
        selectedTargetID = nil
        rememberedSelection = nil
        selectionAuthorizedForReadyConnection = false
        authorizedConnectionGeneration = nil
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
