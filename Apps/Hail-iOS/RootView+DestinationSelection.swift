// swiftlint:disable file_length
import Foundation
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
        guard let authorizedConnectionGeneration = ambientRestoreAuthorization.authorizedGeneration(
            hostID: selectedHostID, targetID: selectedTargetID,
            foregroundAuthorized: selectionAuthorizedForReadyConnection, generation: authorizedConnectionGeneration
        ),
              let selectedHostID, let selectedTargetID, let rememberedSelection else { return nil }
        return availableDestinations.first {
            $0.hostID == selectedHostID && $0.target.id == selectedTargetID
                && connections.snapshots[$0.hostID]?.connectionGeneration == authorizedConnectionGeneration
                && ambientRestoreAuthorization.matches(rememberedSelection, endpoint: $0.endpoint, target: $0.target)
        }
    }

    /// Only core's applied, still-current binding may advance authorization without a foreground selection.
    private var appliedAmbientBinding: AmbientAudioBinding? {
        ambientRestoreAuthorization.appliedBinding(hostID: selectedHostID, targetID: selectedTargetID)
    }

    private var ambientRestoreAuthorization: AmbientRestorePresentation {
        let binding = selectedHostID.flatMap { host in
            selectedTargetID.flatMap { connections.ambientBinding(host: host, targetID: $0) }
        }
        return AmbientRestorePresentation(controller: connections.ambientController, confirmedBinding: binding)
    }

    @MainActor
    func acceptAppliedAmbientRestore() -> Bool {
        guard let binding = appliedAmbientBinding else { return false }
        if let selection = rememberedSelection, let host = connections.snapshots[binding.hostID],
           let target = host.targets.first(where: { $0.id == binding.targetID }),
           let refreshed = ambientRestoreAuthorization.restoredSelection(selection, endpoint: host.endpoint,
                                                                         target: target) {
            rememberedSelection = refreshed
            if refreshed != selection {
                let revision = selectionRevision
                Task {
                    guard selectionRevision == revision, rememberedSelection == refreshed else { return }
                    await selectionStore.save(refreshed)
                }
            }
        }
        selectionAuthorizedForReadyConnection = true
        authorizedConnectionGeneration = binding.connectionGeneration
        return true
    }

    @MainActor
    func performAmbientNoticeAction(_ action: AmbientRestorePresentation.NoticeAction) {
        switch action {
        case .selectDestination: showingDestinations = true
        case .resume(let binding): Task { await connections.ambientController?.turnOn(for: binding) }
        }
    }

    @MainActor
    func select(_ option: Destination) async {
        guard scenePhase == .active else { return }
        selectionRevision &+= 1
        let revision = selectionRevision
        let phaseRevision = scenePhaseRevision
        guard let connectionGeneration = connections.snapshots[option.hostID]?.connectionGeneration else {
            return
        }
        do {
            try await connections.selectTarget(host: option.hostID, targetID: option.target.id)
            guard scenePhase == .active,
                  scenePhaseRevision == phaseRevision,
                  selectionRevision == revision else { return }
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
            await forgetSelection(preservingRestore: false)
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
        if acceptAppliedAmbientRestore() { return }
        // Core confirms a pending transport restore even in the background; do not race its selection round trip.
        guard connections.ambientController?.reconnect.isPending != true else { return }
        guard scenePhase == .active,
              didRestoreSelection,
              !isRestoringSelection,
              let rememberedSelection else { return }
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
}

extension RootView {
    @MainActor
    private func authorizeRememberedSelection(
        _ rememberedSelection: DestinationSelection,
        host: HostConnectionSnapshot,
        target: TargetInfo
    ) async {
        isRestoringSelection = true
        let revision = selectionRevision
        let phaseRevision = scenePhaseRevision
        let connectionGeneration = host.connectionGeneration
        do {
            try await connections.selectTarget(host: host.id, targetID: target.id, restoring: true)
        } catch {
            authorizationFailed(
                revision: revision,
                phaseRevision: phaseRevision,
                hostID: host.id,
                connectionGeneration: connectionGeneration
            )
            return
        }
        isRestoringSelection = false
        guard scenePhase == .active,
              scenePhaseRevision == phaseRevision,
              selectionRevision == revision,
              self.rememberedSelection == rememberedSelection else {
            retryReconciliationIfActive()
            return
        }
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
    private func authorizationFailed(
        revision: UInt,
        phaseRevision: UInt,
        hostID: HostEndpoint.Identifier,
        connectionGeneration: UUID
    ) {
        isRestoringSelection = false
        guard scenePhase == .active,
              scenePhaseRevision == phaseRevision,
              selectionRevision == revision else {
            retryReconciliationIfActive()
            return
        }
        selectedHostID = nil
        selectedTargetID = nil
        selectionAuthorizedForReadyConnection = false
        authorizedConnectionGeneration = nil
        if connections.snapshots[hostID]?.connectionGeneration != connectionGeneration {
            retryReconciliationIfActive()
        }
    }

    @MainActor
    private func retryReconciliationIfActive() {
        guard scenePhase == .active else { return }
        Task { await reconcileRememberedSelection() }
    }

    @MainActor
    private func retainAmbientSelectionForPersistence() -> Bool {
        if acceptAppliedAmbientRestore() { return true }
        guard let selection = rememberedSelection,
              selectedHostID == selection.hostID, selectedTargetID == selection.targetID,
              let host = connections.snapshots[selection.hostID],
              ambientRestoreAuthorization.retainsSelection(selection, endpoint: host.endpoint) else { return false }
        selectionAuthorizedForReadyConnection = false
        authorizedConnectionGeneration = nil
        return true
    }

    @MainActor
    func forgetSelection(preservingRestore: Bool = true) async {
        if preservingRestore, retainAmbientSelectionForPersistence() { return }
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
