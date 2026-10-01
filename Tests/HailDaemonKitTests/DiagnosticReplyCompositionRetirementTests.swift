#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct DiagnosticCompositionRetirementTests {
    @Test(arguments: [false, true])
    func rendererFailureOrStopRemainsFailureWithoutFabricatedAudio(stop: Bool) async throws {
        let fixture = try PublisherFixture(cli: true)
        if !stop {
            let script = PublisherFixture.renderer.replacingOccurrences(
                of: "stage('renderer-started');", with: "exit(23);")
            try Data(script.utf8).write(to: fixture.base.appendingPathComponent("vbsay"))
        }
        let (registry, host) = try syntheticHost()
        let destination = PublisherEndpointRecorder(blockAt: stop ? 1 : nil)
        let composition = try DiagnosticReplyComposition(configuration: .init(
            executable: fixture.executable, socket: fixture.base.appendingPathComponent("reply.sock"),
            root: fixture.root, hostID: "synthetic-host", environment: fixture.environment, deadline: .seconds(10)),
            registry: registry, destination: destination,
            audit: AuditLog(directory: fixture.base.appendingPathComponent("audit")))
        do {
            try await composition.start()
            let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host")
            _ = await session.receive(helloFrame())
            _ = await session.receive(sessionFrame(payload: .control(.select(
                targetID: DiagnosticReplyBridgeAdapter.targetID))))
            let result = await session.receive(sessionFrame(target: DiagnosticReplyBridgeAdapter.targetID,
                                                            payload: .text(TextPayload(text: "synthetic input"))))
            #expect(result.frames.isEmpty)
            try await PublisherFixture.until { await destination.frames.count == 1 }
            if stop { await composition.stop() }
            try await PublisherFixture.until {
                let status = await composition.bridgeDiagnostics()
                return status.failed + status.cancelled == 1
            }
            let status = await composition.publisherDiagnostics()
            #expect(status.completed == 0 && status.failed == 1)
            #expect(status.lastFailure == (stop ? .cancelled : .commandFailed))
            #expect(await composition.bridgeDiagnostics().completed == 0)
            #expect(await destination.frames.count == 1)
            await destination.release()
            try await shutdown(composition, fixture: fixture)
        } catch {
            await destination.release()
            try await shutdown(composition, fixture: fixture)
            throw error
        }
    }

    private func syntheticHost() throws -> (Registry, HailHost) {
        let registry = Registry()
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")])
        try policy.allow(DiagnosticReplyBridgeAdapter.targetID, binding: diagnosticUtilityBinding, tier: .open)
        return (registry, try HailHost(registry: registry, store: InMemoryPolicyStore(policy)))
    }

    private func shutdown(_ composition: DiagnosticReplyComposition, fixture: PublisherFixture) async throws {
        await composition.stop()
        try await PublisherFixture.until {
            let status = await composition.publisherDiagnostics()
            return status.retained == 0 && status.queued == 0
        }
        #expect(await composition.bridgeDiagnostics().active == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        try FileManager.default.removeItem(at: fixture.base)
    }
}
#endif
