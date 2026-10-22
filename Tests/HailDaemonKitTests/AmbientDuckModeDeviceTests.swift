#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #735 H-2: the device whose stream turned duck mode on is told so, with its reason and expiry, and told again when
/// it turns off; a re-entry re-arms the auto-end; a device that did not advertise `duck_mode` is never sent the
/// command. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientDuckModeDeviceTests {
    private func run(capabilities: [String], expectFrames: Bool) async throws -> [String] {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 0.5,
                                    capabilities: capabilities)
        defer { rig.close() }
        let before = Int64(Date().timeIntervalSince1970 * 1_000)
        if expectFrames {
            let expires = try await expectOn(on: rig.socket, after: before)
            #expect(expires != nil)
            let off = try await receiveFrame(on: rig.socket, step: "duck mode off")
            #expect(off.payload == .control(.duckMode(on: false, reason: "timeout")))
        }
        #expect(await eventually { rig.details("ambient_duck_device").count == 2 })
        await rig.finish()
        return rig.details("ambient_duck_device")
    }

    /// The next frame must be `duck_mode` on for `voice`, expiring about the configured timeout after the change and
    /// never in the past; returns its expiry.
    private func expectOn(on socket: URLSessionWebSocketTask, after before: Int64) async throws -> Int64? {
        let on = try await receiveFrame(on: socket, step: "duck mode on")
        guard case .control(.duckMode(true, "voice", let expires?)) = on.payload else {
            Issue.record("expected duck_mode on, got \(on.payload)")
            return nil
        }
        #expect(expires >= before && expires <= Int64(Date().timeIntervalSince1970 * 1_000) + 2_000)
        return expires
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

    /// Saying the entry again while duck mode is on re-arms the auto-end: the device sees a later expiry, the first
    /// timeout never fires, and the one off that follows says `timeout`.
    @Test func theAutoEndReArmsOnReEntry() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 1,
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        let before = Int64(Date().timeIntervalSince1970 * 1_000)
        let first = try #require(try await expectOn(on: rig.socket, after: before))
        try await Task.sleep(for: .milliseconds(300))
        let connection = try #require(rig.connection())
        #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1)
        let second = try #require(try await expectOn(on: rig.socket, after: before))
        #expect(second > first)
        let off = try await receiveFrame(on: rig.socket, step: "duck mode off")
        #expect(off.payload == .control(.duckMode(on: false, reason: "timeout")))
        #expect(Int64(Date().timeIntervalSince1970 * 1_000) >= second - 100)
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=true reason=voice reported=1",
                                                "on=false reason=timeout reported=1"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":true}\n{\"duck\":false}\n")
    }
}
#endif
