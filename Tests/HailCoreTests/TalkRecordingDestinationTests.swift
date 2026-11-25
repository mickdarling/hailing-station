import Foundation
import Testing
@testable import HailCore

@MainActor
struct TalkRecordingDestinationTests {
    @Test func finishQueuedOnAClosesCaptureWithoutDeliveringAfterSwitchToB() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        // The old card queues Finish on the main actor. Publish B before yielding to that task,
        // leaving the old view value's callback bound to A.
        let finish = Task { await rig.card.finish() }
        rig.select(rig.macB)
        await finish.value

        #expect(rig.deliveries.isEmpty)
        #expect(rig.card.status == "Not sent: destination changed")
        #expect(rig.card.finalText == rig.text)
        #expect(!rig.card.isRecording && rig.capture.stopCount == 1 && rig.card.talkSession.owner == nil)
    }

    @Test func finishOnUnchangedDestinationDeliversOnce() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        await rig.card.finish()
        #expect(rig.deliveries == [rig.macA: [rig.text]])
    }

    @Test func freshRecordingAfterSwitchDeliversOnlyItsOwnTextToB() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        rig.select(rig.macB)
        rig.show(rig.macB) // Finish is tapped on the updated card this time.
        await rig.card.finish()
        #expect(rig.card.status == "Not sent: destination changed")
        await rig.record(on: rig.macB, text: "second fixture")
        await rig.card.finish()
        #expect(rig.deliveries == [rig.macB: ["second fixture"]])
    }

    @Test func liveSelectionCanChangeBeforeTheCardObservesIt() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        rig.card.selectedDestinationID = rig.macB // No view update or generation change yet.
        await rig.card.finish()
        #expect(rig.deliveries.isEmpty && rig.card.status == "Not sent: destination changed")
    }

    @Test func callbackBoundToAnotherTargetCannotDeliverForTheSelectedMac() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        rig.show(.init(endpointID: rig.macA.endpointID, targetID: "other-target"))
        await rig.card.finish()
        #expect(rig.deliveries.isEmpty && rig.card.status == "Not sent: destination changed")
    }

    @Test func returningToABeforeFinishDoesNotReviveItsRecording() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        rig.select(rig.macB)
        rig.select(rig.macA)
        await rig.card.finish()
        #expect(rig.deliveries.isEmpty && rig.card.status == "Not sent: destination changed")
    }

    @Test(arguments: [false, true])
    func reselectionBeforeViewUpdateRefusesTheOriginalTurn(visitOtherTarget: Bool) async throws {
        let host = try await TalkDestinationStoreFixture.make()
        let rig = RecordingFixture()
        let shown = ConversationDestinationID(endpointID: host.host.id, targetID: "a")
        try await host.select("a")
        rig.card.route = StationTalkRoute(store: host.store, selected: { shown }, reportRemoval: { _ in })
        await rig.record(on: shown)
        let admitted = try #require(rig.card.recordingDestination)
        let viewGeneration = rig.card.destinationGeneration
        if visitOtherTarget { try await host.select("b") }
        try await host.select("a")
        let current = try host.binding("a")
        #expect(current.connectionGeneration == admitted.connectionGeneration)
        #expect(current.selection != admitted.selection)
        #expect(rig.card.destinationGeneration == viewGeneration)
        await rig.card.finish()
        #expect(rig.card.talkStatus == .notSent(.destinationChanged) && rig.card.finalText == rig.text)
        #expect(rig.deliveries.isEmpty && rig.capture.stopCount == 1)
        await host.store.disconnect(host.host.id)
    }

    @Test func refusalIdentityIsIndependentOfItsDisplayText() {
        let refused = TalkCardStatus.notSent(.destinationChanged)
        let activity = TalkCardStatus.activity("Not sent: destination changed")
        #expect(activity.message == refused.message)
        #expect(activity != refused)
    }

    @Test func removalDuringRecordingReportsRefusalOutsideTheUnmountedCard() async throws {
        let host = try await TalkDestinationStoreFixture.make()
        let rig = RecordingFixture()
        let shown = ConversationDestinationID(endpointID: host.host.id, targetID: "a")
        var notices: [TalkSendRefusal] = []
        try await host.select(shown.targetID)
        rig.card.route = StationTalkRoute(store: host.store, selected: { shown }, reportRemoval: { notices.append($0) })
        await rig.record(on: shown)
        _ = try #require(rig.card.recordingDestination)
        await host.store.remove(host.host.id)
        await rig.card.finish(force: true)
        #expect(rig.deliveries.isEmpty && rig.capture.stopCount == 1 && rig.card.talkSession.owner == nil)
        #expect(notices == [.destinationChanged] && rig.card.talkStatus == .notSent(.destinationChanged))
        #expect(rig.card.status == "Not sent: destination changed" && rig.card.finalText == rig.text)
    }

    @Test func reconnectingTheSameMacAndTargetDoesNotReviveItsRecording() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        rig.card.connectionGeneration = UUID()
        await rig.card.finish()
        #expect(rig.deliveries.isEmpty && rig.card.status == "Not sent: destination changed")
    }
}

@MainActor
private final class RecordingFixture {
    // Different Macs can each retain their own selected target with the same ID.
    let macA = ConversationDestinationID(endpointID: "mac-a", targetID: "target")
    let macB = ConversationDestinationID(endpointID: "mac-b", targetID: "target")
    let text = "fixture request"
    let capture = FakeAudioCapture()
    let speech = FakeTranscriber()
    let card: TranscriptionLabView
    var deliveries: [ConversationDestinationID: [String]] = [:]

    init() {
        let playback = ReplyPlaybackController(player: DuplexPlayer())
        playback.captureLivenessSleep = { _ in throw CancellationError() }
        card = TranscriptionLabView(capture: capture, playback: playback, transcriber: speech)
        select(macA)
    }

    func select(_ destination: ConversationDestinationID) {
        card.selectedDestinationID = destination
        card.destinationGeneration = UUID()
    }

    func show(_ destination: ConversationDestinationID) {
        card.destinationID = destination
        card.onFinalized = { [weak self] text in self?.deliveries[destination, default: []].append(text) }
    }

    func record(on destination: ConversationDestinationID, text: String? = nil) async {
        show(destination)
        await card.begin()
        await speech.emit(.init(text: text ?? self.text, isFinal: true))
    }
}
