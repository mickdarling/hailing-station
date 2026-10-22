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
}
#endif
