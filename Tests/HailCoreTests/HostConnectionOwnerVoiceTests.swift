import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// rightyo#164: the device shows when its host's RightyO does not recognise the owner's voice on this input, and tells a
/// host that accepts it which kind of input route each ambient stream comes from.
@MainActor
@Suite struct HostConnectionOwnerVoiceTests {
    private let rig = HostConnectionStoreAmbientBindingTests()

    private func push(_ control: ControlPayload, on socket: ScriptedSocket) async throws {
        try await socket.push(FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control))))
    }

    @Test func theHelloAdvertisesOwnerVoiceAndTheStatusComesAndGoes() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        guard case .control(.hello(let info))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device hello first")
            return
        }
        #expect(info.capabilities.contains(OwnerVoice.capability))
        try await push(.ownerVoice(state: "unrecognized"), on: socket)
        try await waitUntil { await MainActor.run { store.ownerVoiceUnrecognized.contains(endpoint.id) } }
        try await push(.ownerVoice(state: "recognized"), on: socket)
        try await waitUntil { await MainActor.run { store.ownerVoiceUnrecognized.isEmpty } }
        #expect(store.replyFrames.isEmpty) // a notice, never a reply
        await store.disconnect(endpoint.id)
    }

    /// A new stream is a new RightyO session, so an earlier "not recognised" is cleared when it starts.
    @Test func aNewStreamClearsTheStatus() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await rig.select("tmux:a", on: ready)
        try await push(.ownerVoice(state: "unrecognized"), on: socket)
        try await waitUntil { await MainActor.run { store.ownerVoiceUnrecognized.contains(endpoint.id) } }
        let binding = try #require(store.ambientBinding(host: endpoint.id, targetID: "tmux:a"))
        try await store.sendAudio(ambientSegment(), to: binding)
        #expect(store.ownerVoiceUnrecognized.isEmpty)
        await store.disconnect(endpoint.id)
    }

    /// The route kind goes before the stream's first segment, once, and only to a host that advertised it.
    @Test(arguments: [true, false])
    func theRouteKindPrecedesTheFirstSegmentOnlyForACapableHost(capable: Bool) async throws {
        let ready = try await rig.readyStore(
            capabilities: ["ping", "select_target", "stream_audio"] + (capable ? [AmbientInput.capability] : [])
        )
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        store.inputRoute = { "usb_audio" }
        try await rig.select("tmux:a", on: ready)
        let binding = try #require(store.ambientBinding(host: endpoint.id, targetID: "tmux:a"))
        let stream = UUID()
        try await store.sendAudio(ambientSegment(stream: stream, sequence: 0), to: binding)
        try await store.sendAudio(ambientSegment(stream: stream, sequence: 1), to: binding)
        let sent = try await socket.sentFrames().compactMap { frame -> String? in
            switch frame.payload {
            case .control(.ambientInput(let route)): "route:\(route)"
            case .audio(let audio): "audio:\(audio.sequence)"
            default: nil
            }
        }
        #expect(sent == (capable ? ["route:usb_audio"] : []) + ["audio:0", "audio:1"])
        await store.disconnect(endpoint.id)
    }

    /// A port name, or a route kind newer than the first-shipped vocabulary, goes as `other`: never the name itself.
    @Test func aRouteOutsideTheVocabularyIsSentAsOther() async throws {
        let ready = try await rig.readyStore(
            capabilities: ["ping", "select_target", "stream_audio", AmbientInput.capability]
        )
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        store.inputRoute = { "Mick's AirPods" }
        try await rig.select("tmux:a", on: ready)
        let binding = try #require(store.ambientBinding(host: endpoint.id, targetID: "tmux:a"))
        try await store.sendAudio(ambientSegment(), to: binding)
        let routes = try await socket.sentFrames().filter {
            if case .control(.ambientInput) = $0.payload { return true }
            return false
        }
        #expect(routes.map(\.payload) == [.control(.ambientInput(route: "other"))])
        #expect(HostConnectionStore.sendableRoute("car_audio") == "car_audio")
        #expect(HostConnectionStore.sendableRoute("future_route") == "other")
        #expect(HostConnectionStore.sendableRoute(nil) == nil)
        #expect(HostConnectionStore.ambientInputRoutesV1.isSubset(of: Set(AmbientInput.routes)))
        await store.disconnect(endpoint.id)
    }
}
