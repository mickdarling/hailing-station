#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #735 H-2, round 2: the device whose stream turned privacy (duck) mode on is told so, with its reason and no
/// expiry (privacy has no auto-end), and told again when the owner's exit turns it off; a device that did not
/// advertise `duck_mode` is never sent the command. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientDuckModeDeviceTests {
    private func run(capabilities: [String], expectFrames: Bool) async throws -> [String] {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true, timeout: 0.5,
                                    capabilities: capabilities)
        defer { rig.close() }
        if expectFrames {
            let on = try await receiveFrame(on: rig.socket, step: "duck mode on")
            #expect(on.payload == .control(.duckMode(on: true, reason: "voice")))
        }
        #expect(await eventually { rig.details("ambient_duck_device").count == 1 })
        let connection = try #require(rig.connection())
        #expect(rig.env.router.setDuck(false, connection: connection, reason: "voice") == 1)
        if expectFrames {
            let off = try await receiveFrame(on: rig.socket, step: "duck mode off")
            #expect(off.payload == .control(.duckMode(on: false, reason: "voice")))
        }
        #expect(await eventually { rig.details("ambient_duck_device").count == 2 })
        await rig.finish()
        return rig.details("ambient_duck_device")
    }

    @Test func aCapableDeviceIsToldWhenDuckModeTurnsOnAndOff() async throws {
        let details = try await run(capabilities: [DuckMode.capability], expectFrames: true)
        #expect(details == ["on=true device=sent", "on=false device=sent"])
    }

    /// Copied from media mode's (#612): no `duck_mode` capability, no `duck_mode` frame, even for a device that takes
    /// `media_mode`.
    @Test(arguments: [[], [MediaMode.capability]])
    func anOlderDeviceIsNeverSentTheCommand(_ capabilities: [String]) async throws {
        let details = try await run(capabilities: capabilities, expectFrames: false)
        #expect(details == ["on=true device=unsupported", "on=false device=unsupported"])
    }

    /// Mick, round 2: no privacy auto-end. With the (reserved) timeout set short and time well past it, privacy stays
    /// on, nothing is written off to the child, and a re-entry carries no expiry either.
    @Test func privacyStaysOnWithTimeAdvanced() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true, timeout: 0.2,
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        let on = try await receiveFrame(on: rig.socket, step: "duck mode on")
        #expect(on.payload == .control(.duckMode(on: true, reason: "voice")))
        let connection = try #require(rig.connection())
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(rig.env.router.duckMode(connection: connection))
        #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1)
        let again = try await receiveFrame(on: rig.socket, step: "duck mode on again")
        #expect(again.payload == .control(.duckMode(on: true, reason: "voice")))
        try await Task.sleep(for: .milliseconds(600))
        #expect(rig.env.router.duckMode(connection: connection))
        try await barrier(on: rig.socket, step: "no off")
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=true reason=voice reported=1"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":true}\n")
        await rig.finish()
    }
}
#endif
