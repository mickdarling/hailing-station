#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The owner's off settings a test sets (#941): the probe's wait (haild's three seconds unless a test that expects no
/// pong shortens it; a pong ends the wait at once) and a hook before the off decides.
struct PrivacyOffSettings: Sendable {
    static let silent = Self(probeTimeout: .milliseconds(500))
    var probeTimeout: Duration = .seconds(3)
    var offScoping: (@Sendable (UUID) async -> Void)?
}

/// The restore rig's pieces for #941's privacy park tests: segments told apart by their bytes, a held child let go,
/// and what each child read. Synthetic only.
extension RestoreRig {
    /// A synthetic segment of `fill` bytes, the first one of a `resume` start when asked.
    static func segment(_ stream: UUID, _ sequence: Int, fill: UInt8, resume: Bool = false) -> Frame {
        var frame = audio(stream, sequence)
        if case .audio(var payload) = frame.payload {
            (payload.isResume, payload.bytes) = (resume, Data(repeating: fill, count: payload.bytes.count))
            frame.payload = .audio(payload)
        }
        return frame
    }

    /// A device with the app's own claims (#941: Hello name "hail terminal", class `kind`) that never answers a ping,
    /// selecting the rig's target, and its connection id.
    func connectSilent(kind: String? = "phone",
                       capabilities: [String] = ["probe"]) async throws -> (SilentPeer, UUID) {
        let before = await Self.connections(of: env.listener)
        let peer = try await SilentPeer.connect(port: env.port)
        try await peer.send(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: Self.appName, deviceKind: kind
        )))))
        _ = try await peer.receive()
        try await peer.send(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let nonce = UUID().uuidString
        try await peer.send(sessionFrame(payload: .control(.ping(nonce: nonce))))
        while try await peer.receive().payload != .control(.pong(nonce: nonce)) {}
        let after = await Self.connections(of: env.listener)
        return (peer, try #require(after.subtracting(before).first))
    }

    /// The Hello name every app sends (`HostConnection.deviceName`'s default; `HostConnectionStore` sets no other).
    static let appName = "hail terminal"

    /// Lets a held child write its `started` (`holdStarted`, `holdSpawn`).
    func release() throws { try Data().write(to: fake.directory.appendingPathComponent("go")) }

    /// What the `spawn`th child read from its stdin, once the rig has finished.
    func heard(_ spawn: Int) -> Data {
        (try? Data(contentsOf: fake.directory.appendingPathComponent("audio.\(spawn).raw"))) ?? Data()
    }
}
#endif
