#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The audit record of a routed ambient dispatch (#636, second-key reviews on #691): `ambient-dispatch-routed`,
/// still only the target and byte count; the stream's own requests keep `ambient-dispatch`. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRouteAmbientAuditTests {
    @Test func aRoutedDispatchIsRecordedAsRoutedAndNeverWithItsWords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-636-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        _ = await rig.listener.installFallbackSyntheticPeers([session])
        let connection = await session.connectionID
        let stream = AmbientListenerDispatcher(listener: rig.listener, audit: AuditLog(directory: directory),
                                               selection: await session.selectionGeneration,
                                               streamTarget: VoiceRouteRig.scratch)
        let request = { (target: String, binding: String) in
            VoiceRouteAmbientAuthorityTests.request(connection, to: target, binding: binding)
        }
        _ = try await stream.dispatch(request(VoiceRouteRig.deck, "d"), routed: true)
        _ = try await stream.dispatch(request(VoiceRouteRig.scratch, "s"), routed: false)
        #expect(await rig.adapter.deliveries.map(\.target) == ["deck", "scratch"])
        let records = try AuditHistory(directory: directory).today().filter { $0.contains("ambient-dispatch") }
        #expect(records.count == 2)
        #expect(records.first?.contains("\"tool\":\"ambient-dispatch-routed\"") == true)
        #expect(records.last?.contains("\"tool\":\"ambient-dispatch\"") == true)
        #expect(records.allSatisfy { !$0.contains("synthetic input") })
        await rig.listener.stop(reason: "synthetic test complete")
    }
}
#endif
