import Foundation
import Testing
@testable import HailCore

@Suite struct AmbientListeningStateTests {
    typealias State = AmbientListeningState
    typealias Event = State.Event

    static let automatic: [Event] = [
        .transportLost, .transportReady, .selectionConfirmed, .privacyConfirmed,
        .interruptionBegan, .interruptionEnded, .routeChanged, .routeSettled, .captureInvalidated,
        .sceneChanged, .micRetryDue, .captureRebuildAuthorized,
        .preferenceChanged(masksDuringReplies: true), .preferenceChanged(masksDuringReplies: false)
    ]
    static let stops: [State.StopReason] = [
        .ownerOff, .ownerReselect, .ownerRemove, .ownerDisconnect, .privacyStop, .policyDenied,
        .microphonePermissionDenied, .targetRemoved, .capabilityRemoved, .unsafeEndpointChange, .movedAway
    ] + State.LegacyStopPath.allCases.map(State.StopReason.legacy)

    @Test func ownerStartPinsTheAuthorizedBinding() throws {
        let host = try endpoint()
        let socket = AmbientAudioBinding(hostID: host.id, targetID: "target", connectionGeneration: UUID(),
                                         selection: 7, endpointURL: host.url.absoluteString)
        let unannotated = AmbientAudioBinding(hostID: host.id, targetID: socket.targetID,
                                              connectionGeneration: socket.connectionGeneration, selection: 7)
        #expect(Set([unannotated, socket]).count == 1)
        let destination = State.Destination(socket)
        let generation = UUID()
        let on = State.on(.init(generation: generation, destination: destination))
        for initial in [State.off, .stopped(.movedAway)] {
            #expect(initial.transition(.ownerStart(destination), generation: generation) == on)
        }
        #expect(destination.hostID == host.id && destination.endpointURL == host.url.absoluteString)
        #expect(destination.targetID == socket.targetID && destination.selection == 7)
        let replacement = AmbientAudioBinding(hostID: host.id, targetID: "target", connectionGeneration: UUID(),
                                              selection: 7, endpointURL: host.url.absoluteString)
        #expect(replacement != socket && State.Destination(replacement) == destination)
        let other = State.Destination(try binding(target: "other"))
        #expect(on.transition(.ownerStart(other), generation: UUID()) == on)
    }

    @Test(arguments: Self.automatic)
    func automaticEventsNeverStartStopOrFlipIntent(_ event: Event) throws {
        let generation = UUID()
        let on = State.on(.init(generation: generation, destination: .init(try binding())))
        for initial in [State.off, on, .stopped(.movedAway)] {
            #expect(initial.transition(event, generation: generation) == initial)
        }
    }

    @Test(arguments: Self.stops)
    func eachStopRetiresOnlyItsGenerationOnce(_ reason: State.StopReason) throws {
        let generation = UUID()
        let destination = State.Destination(try binding())
        let on = State.off.transition(.ownerStart(destination), generation: generation)
        let stopped = on.transition(.stop(reason), generation: generation)
        #expect(stopped == .stopped(reason))
        let next = stopped.transition(.ownerStart(destination), generation: UUID())
        #expect(next.intent?.destination == destination && next.intent?.generation != generation)
        for repeated in Self.stops {
            #expect(stopped.transition(.stop(repeated), generation: generation) == stopped)
            #expect(next.transition(.stop(repeated), generation: generation) == next)
            #expect(State.off.transition(.stop(repeated), generation: generation) == .off)
        }
    }
}
