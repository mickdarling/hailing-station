#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension CodexAppServerAdapterTests {
    @Test func invalidStartResponseCannotManufactureSentEvidence() async throws {
        var command = CodexAppServerFixtures.command(early: false, terminal: false)
        let original = command.arguments[1]
        command.arguments[1] = original.replacingOccurrences(
            of: "result=>{turn=>{id=>$turn,status=>'inProgress',items=>[]}}",
            with: "result=>{turn=>{id=>$turn,status=>'completed',items=>[]}}")
        #expect(command.arguments[1] != original)
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: command, verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                await #expect(throws: CodexAppServerError.invalidProtocol) {
                    try await session.submit("invented input", utteranceID: UUID())
                }
                await #expect(throws: ProviderObservationLoss.self) { try await session.next() }
            }
            return adapter
        }
        #expect(await adapter.isReaped)
    }
    @Test(arguments: [false, true])
    func validReceiptRemainsSentWhenWholeEarlyPrefixIsRefused(conflicting: Bool) async throws {
        let gate = try CodexFixtureGate(); defer { try? gate.remove() }
        let wrong = conflicting
            ? #"sendmsg({method=>'item/completed',params=>{threadId=>'synthetic-thread',turnId=>$turn,"# +
                #"item=>{id=>'synthetic-item',type=>'agentMessage',phase=>'final_answer',text=>'changed'}}}); "#
            : #"sendmsg({method=>'turn/started',params=>{threadId=>'synthetic-thread',"# +
                #"turn=>{id=>'wrong-turn',status=>'inProgress',items=>[]}}}); "#
        let extra = wrong + #"open($counter,'>',$gate.'.count') or die; print $counter $number; close $counter; "#
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(gate: gate, extra: extra), verifiedVersion: "0.159.0") { adapter in
            let safety = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                Issue.record("send-receipt fixture stalled"); adapter.cancel()
            }
            do {
                try await Self.verifySentReceipt(adapter, gate: gate)
                safety.cancel(); await safety.value; return adapter
            } catch { safety.cancel(); await safety.value; throw error }
        }
        #expect(await adapter.isReaped)
        #expect(try String(contentsOfFile: gate.path + ".count", encoding: .utf8) == "1")
    }
    private static func verifySentReceipt(_ adapter: CodexAppServerAdapter, gate: CodexFixtureGate) async throws {
        let host = try await CodexAppServerFixtures.host(adapter)
        try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let utterance = UUID()
                    let outcome = try await session.submit("invented input", utteranceID: utterance)
                    guard case .sent(let turn) = outcome else { throw ProviderContractError.unknownTurn }
                    let binding = await session.binding, connection = await session.connectionID
                    #expect(turn.utteranceID == utterance && turn.binding == binding && turn.connectionID == connection)
                    #expect(await session.state(for: turn.id) == .sent)
                    await #expect(throws: ProviderObservationLoss.authorizationLost) { try await session.next() }
                    #expect(await session.status == .lost(.authorizationLost))
                    #expect(await session.state(for: turn.id) == .sent)
                    await #expect(throws: ProviderObservationError.interrupted) {
                        try await session.submit("invented retry", utteranceID: utterance)
                    }
                    await #expect(throws: ProviderObservationLoss.authorizationLost) { try await session.next() }
                }
                defer { adapter.cancel(); group.cancelAll() }
                try await CodexStdioFixtures.waitUntil { await adapter.bufferedEarlyRecords == 4 }
                try await gate.release()
                try await group.waitForAll()
            }
        }
    }
}
#endif
