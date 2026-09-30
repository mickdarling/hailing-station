import Foundation
import Network
import Testing
@testable import HailDaemonKit

@Suite struct TerminalReplyTransportTests {
    @Test func ownerCancellationRetiresPeerBeforeAnyConnectionStateCallback() async throws {
        let (host, _) = try await sessionHost()
        // Neither connection starts: the production cancellation closure runs without a state callback.
        let peer = WebSocketPeer(
            id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: HostSession(host: host), queue: DispatchQueue(label: "synthetic-cancelled-peer"),
            helloTimeout: .seconds(5), log: { _ in }, onEnd: { _ in }
        )
        let other = WebSocketPeer(
            id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: HostSession(host: host), queue: DispatchQueue(label: "synthetic-independent-peer"),
            helloTimeout: .seconds(5), log: { _ in }, onEnd: { _ in }
        )
        let owner = try #require(await peer.prepareReplyPublication(helloFrame()))
        let sibling = try #require(await peer.prepareReplyPublication(helloFrame()))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await owner.result()
        }
        #expect(!(await cancelled.value))
        #expect(!(await peer.ended))
        #expect(await peer.prepareReplyPublication(helloFrame()) == nil)
        #expect(!sibling.enqueue())
        #expect(!(await sibling.result()))
        #expect(!(await peer.send(helloFrame())))
        #expect(await other.prepareReplyPublication(helloFrame()) != nil)
        await peer.finish(reason: "synthetic cleanup")
        await other.finish(reason: "synthetic cleanup")
    }

    @Test func terminalTransportRetirementCannotReviveAndOtherTransportStaysCurrent() async throws {
        let first = ReplyTransportLifecycle()
        let second = ReplyTransportLifecycle()
        let old = try #require(first.issuePermit())
        let independent = try #require(second.issuePermit())
        first.retire()
        first.retire()
        #expect(first.issuePermit() == nil)
        #expect(old.performIfCurrent { true } == nil)
        #expect(independent.performIfCurrent { true } == true)
        #expect(second.issuePermit() != nil)
    }
}
