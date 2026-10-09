#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #230 review: the reference is written only for plain legacy targets, never into a contextual bridge's prompt, and
/// the fail-closed `ambient-dispatch` audit record carries the size of the prompt actually dispatched.
@Suite(.serialized) struct AmbientReplyReferenceScopeTests {
    @Test func aContextualTargetKeepsTheOriginalBlockAndItsOutOfBandContextID() async throws {
        let rig = try await RecipientTestRig.make()
        let (listener, connected) = try dispatchListener(rig: rig)
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        do {
            let connection = try await listener.sessionConnection(of: connected.all[0])
            let prompt = "synthetic input" + RightyoInputEvent.replyBlock(target: RecipientTestRig.target)
            let request = LocalDispatchRequest(connection: connection, target: RecipientTestRig.target,
                                               binding: "reply-binding", text: prompt)
            // No reference is minted and the text is untouched: no UUID enters the bridge's model prompt.
            let (prepared, reference) = await listener.referenceAmbient(request)
            #expect(reference == nil && prepared == request)
            #expect(blockReference(in: prepared.text) == nil)
            // The dispatch still owns its reply through the adapter's own out-of-band context id.
            let owner = try #require(try await ambientDispatch(listener, request))
            #expect(await rig.adapter.contexts.last?.id == owner)
            try await pair.barrier()
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func aContextualSessionNeverAdoptsABoundReference() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reference = UUID()
        let owner = try await HostSession.$ambientReplyReference.withValue(reference) {
            try await session.dispatch(dispatchRequest(connection: UUID()))
        }
        let context = try #require(await rig.adapter.contexts.last)
        #expect(owner == context.id && context.id != reference)
        #expect(await session.replyRequests[reference] == nil)
        #expect(await session.replyRequests[context.id]?.bindingLease != nil)
    }

    @Test func theAuditRecordCarriesTheReferencedPromptSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-230-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try await LegacyReferenceRig.make()
        let (listener, connected) = try rig.listener()
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [LegacyReferenceRig.target])
        defer { pair.close() }
        do {
            let connection = try await listener.sessionConnection(of: connected.all[0])
            let request = LegacyReferenceRig.request(connection: connection)
            _ = try #require(try await ambientDispatch(listener, request, audit: AuditLog(directory: directory)))
            let typed = try #require(await rig.adapter.deliveries.last?.text)
            #expect(typed.utf8.count > request.text.utf8.count)
            let records = try AuditHistory(directory: directory).today().filter { $0.contains("ambient-dispatch") }
            #expect(records.count == 1)
            #expect(records.first?.contains("\"bytes\":\(typed.utf8.count)") == true)
            #expect(records.first?.contains("\"bytes\":\(request.text.utf8.count)") == false)
            try await pair.barrier()
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }
}
#endif
