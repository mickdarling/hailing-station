import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderInputShapeTests {
    @Test func multilineRefusalSpendsNeitherProviderRequestAdmissionNorSentCapacity() async throws {
        let adapter = InputShapeAdapter()
        let rig = try await InputShapeRig.make(adapter: adapter, rate: 1, maxTurns: 1)
        await #expect(throws: AdapterInputShapeError.singleLineRequired) {
            try await rig.coordinator.submit("invented first\ninvented second", utteranceID: UUID())
        }
        #expect(await adapter.contextual.isEmpty)
        #expect(await adapter.legacy.isEmpty)
        let outcome = try await rig.coordinator.submit("invented allowed", utteranceID: UUID())
        guard case .sent(let sent) = outcome else { Issue.record("no sent turn"); return }
        #expect(await rig.coordinator.state(for: sent.id) == .sent)
        #expect(await adapter.contextual.map(\.text) == ["invented allowed"])
    }

    @Test func genuineMultilineConfirmationSurvivesShapeRefusalAndCanActuallyBeReused() async throws {
        let profile = InputShapeProfile(.lineOriented)
        let adapter = InputShapeAdapter(profile: profile)
        let rig = try await InputShapeRig.make(adapter: adapter, tier: .confirm, rate: 2)
        let text = "invented first\ninvented second"
        let readBack = try await rig.readBack(text)
        #expect(readBack.lines == ["invented first", "invented second"])
        profile.set(.singleLineContextual)
        await #expect(throws: AdapterInputShapeError.singleLineRequired) {
            try await rig.host.send(text, context: rig.context, confirmedHash: readBack.hash)
        }
        #expect(await adapter.contextual.isEmpty)
        profile.set(.lineOriented) // Trusted fixture reconfiguration; same target/binding/request, not a new token.
        #expect(try await rig.host.send(text, context: rig.context, confirmedHash: readBack.hash) ==
            .delivered(readBack.lines))
        #expect(await adapter.contextual.map(\.context) == [rig.context, rig.context])
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func validConfirmedSingleLineUsesContextAndTheTokenIsOneShot() async throws {
        let adapter = InputShapeAdapter()
        let rig = try await InputShapeRig.make(adapter: adapter, tier: .confirm)
        let readBack = try await rig.readBack("invented input")
        #expect(await adapter.contextual.isEmpty)
        #expect(try await rig.host.send("invented input", context: rig.context, confirmedHash: readBack.hash) ==
            .delivered(["invented input"]))
        let replay = try await rig.host.send("invented input", context: rig.context, confirmedHash: readBack.hash)
        guard case .needsConfirmation = replay else { Issue.record("token was reused"); return }
        #expect(await adapter.contextual.map(\.context) == [rig.context])
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func shapeUsesSanitizedNormalizedLinesRatherThanRawNewlines() async throws {
        for (raw, expected) in [
            ("e\u{301}\r\n \t\n", "é"),
            ("\u{1B}[31minvented\u{1B}[0m\n\n", "invented"),
            ("\u{1B}]title\u{7}invented\u{00A0}input\n \n", "invented input")
        ] {
            let adapter = InputShapeAdapter()
            let rig = try await InputShapeRig.make(adapter: adapter)
            #expect(try await rig.host.send(raw, context: rig.context) == .delivered([expected]))
            #expect(await adapter.contextual.map(\.text) == [expected])
        }
        let adapter = InputShapeAdapter()
        let rig = try await InputShapeRig.make(adapter: adapter)
        await #expect(throws: AdapterInputShapeError.singleLineRequired) {
            try await rig.host.send("one\u{2028}two", context: rig.context)
        }
        #expect(await adapter.contextual.isEmpty)
    }

    @Test func singleLineProfileRefusesLegacyCallsWithoutFallback() async throws {
        let adapter = InputShapeAdapter()
        let rig = try await InputShapeRig.make(adapter: adapter)
        for text in ["invented input", "invented first\ninvented second"] {
            await #expect(throws: AdapterInputShapeError.contextRequired) {
                try await rig.host.send(text, to: InputShapeRig.target)
            }
        }
        #expect(await adapter.contextual.isEmpty)
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func declaredShapeWithoutContextualCapabilityFailsClosed() async throws {
        let adapter = InputShapeUnsupportedAdapter()
        let rig = try await InputShapeRig.make(adapter: adapter)
        await #expect(throws: RegistryError.contextualDeliveryUnsupported) {
            try await rig.host.send("invented input", context: rig.context)
        }
        await #expect(throws: AdapterInputShapeError.contextRequired) {
            try await rig.host.send("invented input", to: InputShapeRig.target)
        }
        #expect(await adapter.writes.isEmpty)
    }

    @Test func unmodifiedAdaptersKeepTheirDefaultLineOrientedLegacyAndContextualDelivery() async throws {
        let adapter = SyntheticContextAdapter()
        #expect(adapter.inputShape == .lineOriented)
        let rig = try await ProviderContextTestRig.make(adapter: adapter, sanitizing: .init(newlines: .split))
        let text = "invented first\ninvented second"
        let lines = ["invented first", "invented second"]
        #expect(try await rig.host.send(text, to: rig.binding.targetID) == .delivered(lines))
        #expect(try await rig.host.send(text, context: rig.context) == .delivered(lines))
        #expect(await adapter.legacy == ["invented first", "invented second"])
        #expect(await adapter.contextual.map(\.context) == [rig.context, rig.context])
    }
}
