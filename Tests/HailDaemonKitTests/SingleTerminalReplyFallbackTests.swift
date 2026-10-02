import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Loopback-socket proof of the #188 single-terminal fallback. Synthetic only; not device hearing.
@Suite(.serialized) struct SingleTerminalReplyFallbackTests {
    @Test func fallbackDeliversUncorrelatedRepliesToTheOnlyConnectionSelectingTheTarget() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        do {
            try await exerciseSingleSelection(listener: listener, rig: rig, port: port)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exerciseSingleSelection(
        listener: WebSocketListener, rig: RecipientTestRig, port: UInt16
    ) async throws {
        // One client selects the target; the other selects a different target and must hear nothing.
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [RecipientTestRig.target, "recipient:other"]
        )
        defer { pair.close() }
        let selected = pair.sockets[0]
        let legacy = uncorrelatedDescriptor(audio: true)
        let text = recipientText(legacy)
        try #require(await listener.publish(text) == 1)
        #expect(try await recipientSocketReceive(on: selected) == text)
        let audio = recipientAudio(legacy, sequence: 0, final: true)
        try #require(await listener.publish(audio) == 1)
        #expect(try await recipientSocketReceive(on: selected) == audio)
        // An explicit request reference nobody holds is refused, never redirected.
        var unknown = uncorrelatedDescriptor()
        unknown.requestID = UUID()
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(recipientText(unknown)) }
        try await pair.barrier()

        // A correlated reply still travels by ownership, and the owner's refused duplicate never falls back.
        let context = try await pair.submitInput(on: 0, rig: rig)
        let correlated = recipientText(recipientDescriptor(context))
        try #require(await listener.publish(correlated) == 1)
        #expect(try await recipientSocketReceive(on: selected) == correlated)
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(correlated) }
        // The sole selector owning a different current request still hears a request-less reply.
        let later = recipientText(uncorrelatedDescriptor())
        try #require(await listener.publish(later) == 1)
        #expect(try await recipientSocketReceive(on: selected) == later)
        try await pair.barrier()
    }

    @Test func staleRequestReferencesNeverReachAnotherConnection() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        do {
            try await exerciseStaleReference(listener: listener, rig: rig, port: port)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exerciseStaleReference(
        listener: WebSocketListener, rig: RecipientTestRig, port: UInt16
    ) async throws {
        // A submits request R, then selects away; B then becomes the sole selector of the target.
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [RecipientTestRig.target, nil])
        defer { pair.close() }
        let stale = recipientDescriptor(try await pair.submitInput(on: 0, rig: rig))
        try await pair.select("recipient:other", on: 0)
        try await pair.select(RecipientTestRig.target, on: 1)
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(recipientText(stale)) }
        try await pair.barrier()
        // Only the request-less shape falls back, and only to the connection selecting the target now.
        let requestless = recipientText(uncorrelatedDescriptor())
        try #require(await listener.publish(requestless) == 1)
        #expect(try await recipientSocketReceive(on: pair.sockets[1]) == requestless)
        try await pair.barrier()
    }

    @Test func correlatedRepliesStayWithTheirOwnerWhileTwoConnectionsSelectTheTarget() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        do {
            try await exerciseSharedSelection(listener: listener, rig: rig, port: port)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exerciseSharedSelection(
        listener: WebSocketListener, rig: RecipientTestRig, port: UInt16
    ) async throws {
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [RecipientTestRig.target, RecipientTestRig.target]
        )
        defer { pair.close() }
        let context = try await pair.submitInput(on: 1, rig: rig)
        let correlated = recipientText(recipientDescriptor(context))
        try #require(await listener.publish(correlated) == 1)
        #expect(try await recipientSocketReceive(on: pair.sockets[1]) == correlated)
        // The owner's duplicate is a correlated refusal; it never falls back to the other selector.
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(correlated) }
        // Two selecting connections: the flag changes nothing, and nobody hears a request-less reply.
        await #expect(throws: LocalReplyRefusal.notUniqueRecipient) {
            try await listener.publish(recipientText(uncorrelatedDescriptor()))
        }
        try await pair.barrier()
    }

    @Test func fallbackFlagIsOffByDefaultAndKeepsOwnerOnlyDelivery() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host, hostName: "mac-test")
        #expect(!(await listener.singleTerminalReplyFallback))
        await listener.installFallbackSyntheticPeers([await rig.session()])
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(uncorrelatedDescriptor()))
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func fallbackFlagRequiresPersonalTerminalMode() throws {
        let base = ["--bind", "127.0.0.1", "--port", "8765"]
        let enabled = try ConnectionProbeDaemon.options(
            base + ["--personal-terminal", "--single-terminal-reply-fallback"]
        )
        #expect(enabled.singleTerminalReplyFallback)
        #expect(enabled.personalTerminal != nil)
        #expect(!(try ConnectionProbeDaemon.options(base + ["--personal-terminal"]).singleTerminalReplyFallback))
        #expect(throws: WebSocketListenerError.invalidArguments) {
            try ConnectionProbeDaemon.options(base + ["--connection-probe", "--single-terminal-reply-fallback"])
        }
    }
}
