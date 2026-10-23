#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// "I can't listen privately right now." (#822 A, Mick: no silent state change): said for every refusal while
/// private, except a child a reload already retired, whose stream lives on in the new child. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyUnavailableTests {
    /// Driven at the router's closure: a child that writes `started` after its reload but before it is reaped cannot
    /// be staged reliably, so the retired verdict is given directly.
    @Test(arguments: [false, true]) func aRefusalSaysUnavailableUnlessAReloadRetiredIt(_ retired: Bool) async throws {
        let clips = AmbientAckLibrary(clips: ["confirmprivacyunavailable": [AmbientDuckModeTests.clip("I can't.", 2)]])
        let rig = try await DuckRig(script: AmbientDuckReloadTests.silent(advertises: true), clips: clips)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        // A mark names no pipeline until one is set, so nothing counts as retired before the pipeline exists.
        #expect(!rig.env.router.retired(AmbientRunMark())())
        rig.env.router.voiceDuck(on: connection, listener: rig.env.listener, retired: { retired })(.unavailable)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        let said = "unavailable confirm=confirmprivacyunavailable/0:sent"
        #expect(rig.details("ambient_duck_confirmed") == [retired ? "unavailable retired confirm=unreported" : said])
        await rig.finish()
    }

    /// The verdict on real runs (#828 key 2): a run a reload swapped out counts as retired; one the gate ended does
    /// not, so its refusal still speaks.
    @Test func onlyAReloadRetiresARun() async throws {
        // The child lingers after its input closes, so a run the gate ended is still registered when checked.
        let rig = try await DuckRig(script: AmbientDuckReloadTests.silent(advertises: true) + "\n/bin/sleep 3")
        defer { rig.close() }
        #expect(await eventually { rig.env.router.activePipeline != nil })
        let first = AmbientRunMark()
        first.set(try #require(rig.env.router.activePipeline))
        #expect(!rig.env.router.retired(first)())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(rig.env.router.retired(first)())
        let second = AmbientRunMark()
        second.set(try #require(rig.env.router.activePipeline))
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        #expect(await eventually { rig.env.router.activePipeline == nil })
        #expect(!rig.env.router.retired(second)())
        await rig.finish()
    }
}
#endif
