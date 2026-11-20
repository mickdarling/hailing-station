import Foundation
import Testing
@testable import HailDaemonKit

/// Real producer bytes, dry admission only (#1247): no child, capture, model, host or delivery.
@Suite(.frozenGuardBudget) struct RightyoStartedEventReplayTests {
    private func fixture(_ name: String = "started-all-options") throws -> Data {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/RightyO")
        return try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }

    /// RightyoAmbientPipeline.run -> decode -> consumeRequestOutcome -> consumer.consume -> admit/validate.
    /// A started event returns false because it delivers nothing; throwing is refusal.
    @discardableResult
    private func replay(_ data: Data) async throws -> RightyoInputEvent {
        let event = try RightyoInputEvent.decode(data)
        #expect(event.type == "session")
        #expect(event.phase == "started")
        let consumer = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run",
                                               session: event.sessionId)
        #expect(try await !consumer.consume(event))
        return event
    }

    private func adding(_ key: String, to name: String) throws -> Data {
        var event = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var object = try #require(event[name] as? [String: Any])
        object[key] = true
        event[name] = object
        return try JSONSerialization.data(withJSONObject: event)
    }

    @Test func allOptionsProducerEventIsAdmittedWithEveryAdvertisement() async throws {
        let data = try fixture()
        let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Pin completeness independently of the emitter so losing an option cannot silently weaken the replay.
        #expect(Set(wire.keys) == ["schema_version", "type", "session_id", "sequence", "emitted_at_ms", "phase",
                                  "capabilities", "addressing", "speaker_names", "owner_voice", "request_forming",
                                  "speech", "audio_input", "dismissal", "conversation", "acknowledgement", "duck",
                                  "meeting", "request_outcomes"])
        let event = try await replay(data)
        #expect(event.sessionId == "host-contract")
        #expect(event.sequence == 1)
        #expect(event.emittedAtMs == 0)
        let capabilities = try #require(event.capabilities)
        #expect(capabilities.activation == "finalized-turn")
        #expect(!capabilities.partials)
        #expect(capabilities.speakers == "enrolled")
        #expect(capabilities.context)
        #expect(event.addressing == .object(["names": .array([.string("Helper")]),
                                            "variants": .object(["Helper": .array([.string("Helpah")])])]))
        #expect(AmbientOverheardRelay.advertisesNames(event.speakerNames))
        #expect(AmbientOwnerVoiceRelay.advertises(event.ownerVoice))
        #expect(event.requestForming?.kind == "template")
        let dismissal = try #require(event.dismissal)
        #expect(dismissal.version == 1)
        #expect(dismissal.windowMs == 12345)
        #expect(dismissal.cooldownMs == 45678)
        #expect(dismissal.cooldownMinConfidence == 0.91)
        #expect(event.conversation != nil)
        #expect(event.acknowledgement != nil)
        #expect(RightyoInputEvent.privacyVersion(event.duck) == 3)
        #expect(AmbientDuckControl.advertises(data))
        #expect(AmbientDuckControl.confirmsPrivate(data))
        #expect(AmbientMeetingControl.advertises(data))
        #expect(RightyoInputEvent.supportsRequestOutcomes(event.requestOutcomes))
        // speech/audio_input are producer diagnostics; haild intentionally ignores them during admission.
        #expect(wire["speech"] is [String: Any])
        #expect(wire["audio_input"] is [String: Any])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAILD_RIGHTYO_STARTED_EVENT"] != nil,
                   "Set HAILD_RIGHTYO_STARTED_EVENT to the emitted JSON file for the pre-reload check."))
    func preReloadStartedEventIsAdmitted() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HAILD_RIGHTYO_STARTED_EVENT"])
        try await replay(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    @Test func extraDismissalKeyIsRefused() async throws {
        let data = try adding("future_option", to: "dismissal")
        await #expect(throws: RightyoInputError.invalidEvent) { try await replay(data) }
    }

    @Test func unknownConversationKeyIsAccepted() async throws {
        try await replay(adding("future_option", to: "conversation"))
    }

    @Test func pre286ProducerMinAttendIncidentIsRefused() async throws {
        let data = try fixture("started-pre-286")
        let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dismissal = try #require(wire["dismissal"] as? [String: Any])
        #expect(dismissal["min_attend"] as? Double == 0.6)
        await #expect(throws: RightyoInputError.invalidEvent) { try await replay(data) }
    }

    /// Pin consumer admission as well as decoding: synthesized/lenient decoding alone would accept these.
    @Test func invalidStartedCapabilitiesAndValidationFieldsAreRefused() async throws {
        let original = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        for change: [String: Any] in [["schema_version": 2], ["request_forming": ["kind": "future"]],
                                     ["capabilities": ["activation": "future", "partials": false,
                                                       "speakers": "enrolled", "context": true]]] {
            let data = try JSONSerialization.data(withJSONObject: original.merging(change) { _, new in new })
            await #expect(throws: RightyoInputError.invalidEvent) { try await replay(data) }
        }
    }
}
