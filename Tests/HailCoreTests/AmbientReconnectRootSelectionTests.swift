import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectRootSelectionTests {
    @Test(arguments: [false, true])
    func persistThenHandshakeThenApplyKeepsTheRetainedCard(callbackAfterApply: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let storage = RootSelectionStore()
        let root = try RootView(rig: rig, selectionStore: storage)
        await storage.save(root.rememberedSelection)
        try await rig.drop()
        var refreshed = rig.endpoint
        refreshed.url = try #require(URL(string: "ws://127.0.0.1:18771"))
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        if !callbackAfterApply { await root.persist([refreshed]).value }
        #expect(root.rememberedSelection != nil && root.selectedHostID == refreshed.id)
        #expect(root.selectedTargetID == rig.target.id)
        #expect(await storage.load() != nil)
        #expect(root.destination == nil)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await rig.feed()
        if callbackAfterApply { await root.persist([refreshed]).value }
        #expect(root.acceptAppliedAmbientRestore())
        #expect(root.rememberedSelection?.hostURL == refreshed.url.absoluteString)
        #expect(root.destination?.endpoint == refreshed && root.destination?.target.id == rig.target.id)
        try await waitUntil { [refreshed] in await storage.load()?.hostURL == refreshed.url.absoluteString }
        #expect(root.authorizedConnectionGeneration == rig.controller.binding?.connectionGeneration)
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        await rig.close()
    }

    @Test func removalAndExplicitInvalidationStillForgetTheDestination() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let storage = RootSelectionStore()
        let root = try RootView(rig: rig, selectionStore: storage)
        await storage.save(root.rememberedSelection)
        try await rig.drop()
        await root.forgetSelection(preservingRestore: false)
        #expect(root.rememberedSelection == nil && root.selectedHostID == nil && root.selectedTargetID == nil)
        #expect(await storage.load() == nil)
        await rig.store.remove(rig.endpoint.id)
        await root.persist([]).value
        #expect(root.destination == nil)
        await rig.close()
    }

    @Test func reauthorizationNoticeOpensDestinationSelectionWithoutResuming() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        try await refuseRefreshedSelection(rig)
        let presentation = rig.appPresentation
        #expect(presentation.notice?.reason == .reauthorizationNeeded)
        #expect(presentation.notice?.text.contains("re-authorization needed") == true)
        #expect(presentation.resumeBinding == nil)
        let action = try #require(presentation.noticeAction)
        #expect(action == .selectDestination && action.title == "Choose destination")
        root.performAmbientNoticeAction(action)
        #expect(root.showingDestinations && !rig.controller.isOn && rig.capture.startCount == 1)
        #expect(try await audioFrames(rig.socket).isEmpty)
        await rig.close()
    }

    @Test func nativePersistSchedulesTheTestedForgetSelectionCallback() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("Apps/Hail-iOS/RootView.swift"),
                                encoding: .utf8)
        #expect(source.contains("!endpoints.contains(where: rememberedSelection.matches(endpoint:))"))
        #expect(source.contains("Task { await forgetSelection() }"))
    }
}

@MainActor
private func refuseRefreshedSelection(_ rig: AmbientReconnectRig) async throws {
    var refreshed = rig.endpoint
    refreshed.name = "Refreshed synthetic host"
    rig.socket = ScriptedSocket()
    await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
    await rig.store.upsert(refreshed)
    try await waitUntil { try await rig.socket.sentFrames().contains {
        if case .control(.hello) = $0.payload { return true }; return false
    } }
    try await rig.socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
        capabilities: ["ping", "stream_audio", "set_privacy"], deviceName: "Synthetic")))
    try await rig.socket.push(.targets([rig.target]))
    try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
}
