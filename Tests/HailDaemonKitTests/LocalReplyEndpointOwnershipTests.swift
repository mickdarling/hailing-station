#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct LocalReplyEndpointOwnershipTests {
    @Test func stoppingNeverStartedCompositionCannotRemoveAnotherLiveSocket() async throws {
        let fixture = try PublisherFixture(cli: true)
        let firstRegistry = Registry(), secondRegistry = Registry()
        let configuration = DiagnosticReplyComposition.Configuration(
            executable: fixture.executable, socket: fixture.base.appendingPathComponent("reply.sock"),
            outputRoot: fixture.root, hostID: "synthetic-host")
        let destination = PublisherEndpointRecorder()
        let first = try DiagnosticReplyComposition(configuration: configuration, registry: firstRegistry,
            destination: destination, audit: AuditLog(directory: fixture.base.appendingPathComponent("audit")))
        let second = try DiagnosticReplyComposition(configuration: configuration, registry: secondRegistry,
            destination: destination, audit: AuditLog(directory: fixture.base.appendingPathComponent("audit")))
        do {
            try await first.start()
            let before = try #require(try PolicyFile.info(configuration.socket))
            await second.stop()
            let after = try #require(try PolicyFile.info(configuration.socket), "contender removed another live socket")
            #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
            #expect(try await firstRegistry.targets().allSatisfy { $0.alive })
            #expect(await secondRegistry.kinds.isEmpty)
            await first.stop()
            #expect(try PolicyFile.info(configuration.socket) == nil)
            try FileManager.default.removeItem(at: fixture.base)
        } catch {
            await first.stop(); await second.stop()
            try FileManager.default.removeItem(at: fixture.base)
            throw error
        }
    }

    @Test func stopPreservesReplacementLiveSocketAndRemovesOnlyItsOwnIdentity() async throws {
        let fixture = try PublisherFixture()
        let socket = fixture.base.appendingPathComponent("reply.sock")
        let moved = fixture.base.appendingPathComponent("preserved.sock")
        let destination = PublisherEndpointRecorder()
        let audit = AuditLog(directory: fixture.base.appendingPathComponent("audit"))
        let first = try LocalReplyEndpoint(socketURL: socket, destination: destination, audit: audit)
        try await first.start()
        try FileManager.default.moveItem(at: socket, to: moved)
        let second = try LocalReplyEndpoint(socketURL: socket, destination: destination, audit: audit)
        do {
            try await second.start()
            let before = try #require(try PolicyFile.info(socket))
            await first.stop()
            let after = try #require(try PolicyFile.info(socket), "old lifetime removed replacement socket")
            #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
            await second.stop()
            #expect(try PolicyFile.info(socket) == nil)
            #expect(try PolicyFile.info(moved) != nil)
            try FileManager.default.removeItem(at: fixture.base)
        } catch {
            await first.stop(); await second.stop()
            try FileManager.default.removeItem(at: fixture.base)
            throw error
        }
    }
}
#endif
