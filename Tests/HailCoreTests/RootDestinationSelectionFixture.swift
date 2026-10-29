import Foundation
import HailProtocol
@testable import HailCore

/// Compile the actual app extension against a state shell without loading the native audio/SwiftUI surface.
@MainActor
final class RootView: AmbientDestinationOwner {
    enum Phase { case active, inactive, background }
    let connections: HostConnectionStore
    let selectionStore: any DestinationSelectionStoring
    var selectedHostID: HostEndpoint.Identifier?
    var selectedTargetID: String?
    var rememberedSelection: DestinationSelection?
    var selectionAuthorizedForReadyConnection = true
    var authorizedConnectionGeneration: UUID?
    var selectionRevision: UInt = 0
    var scenePhaseRevision: UInt = 0
    var scenePhase = Phase.active
    var didRestoreSelection = true
    var didRestoreHosts = true
    var isRestoringSelection = false
    var showingDestinations = false
    private(set) var savedHosts: [HostEndpoint] = []

    init(rig: AmbientReconnectRig, selectionStore: any DestinationSelectionStoring) throws {
        connections = rig.store
        self.selectionStore = selectionStore
        selectedHostID = rig.endpoint.id
        selectedTargetID = rig.target.id
        rememberedSelection = DestinationSelection(hostID: rig.endpoint.id, hostURL: rig.endpoint.url.absoluteString,
                                                   targetID: rig.target.id, targetName: rig.target.name)
        authorizedConnectionGeneration = try rig.currentBinding().connectionGeneration
    }

    /// RootView.persist's scheduled invalidation; a source contract below checks the native adapter still uses it.
    func persist(_ endpoints: [HostEndpoint]) -> Task<Void, Never> {
        savedHosts = endpoints
        let invalidates = rememberedSelection.map { selection in
            !endpoints.contains(where: selection.matches(endpoint:))
        } ?? false
        return Task { if invalidates { await forgetSelection() } }
    }
}

actor RootSelectionStore: DestinationSelectionStoring {
    private var selection: DestinationSelection?
    func load() -> DestinationSelection? { selection }
    func save(_ selection: DestinationSelection?) { self.selection = selection }
}
