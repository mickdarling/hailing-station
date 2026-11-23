#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

private actor OutcomeHeldDispatcher: RightyoAmbientDispatching {
    let reference = UUID()
    private(set) var entered = false
    private var gate: CheckedContinuation<Void, Never>?
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        entered = true
        await withCheckedContinuation { gate = $0 }
        return reference
    }
    func release() { gate?.resume(); gate = nil }
}
private final class OutcomeRaceMark: Sendable { let muted = Mutex(false) }

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoOutcomePipelineRaceTests {
    @Test func privacyOnOffWhileDispatchSuspendsCannotRestoreItsMapping() async throws {
        let fake = try FakeRightyo("""
            /usr/bin/sed -n -e '1,6p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
            while [ ! -f go ]; do /bin/sleep 0.02; done
            /bin/cat second.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
            /bin/cat > /dev/null
            /bin/cat terminal.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
            """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        try prepare(fake)
        let dispatcher = OutcomeHeldDispatcher(), mark = OutcomeRaceMark()
        var config = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 0.2, termGrace: 0.2))
        config.onVoiceMute = { _ in mark.muted.withLock { $0 = true } }
        let pipeline = try RightyoAmbientPipeline(configuration: config, dispatcher: dispatcher)
        let run = Task { try await pipeline.run() }
        #expect(await eventually { await dispatcher.entered })
        _ = pipeline.reportDuck(true)
        _ = pipeline.reportDuck(false)
        try Data().write(to: fake.directory.appendingPathComponent("go"))
        await dispatcher.release()
        // The second request's mute callback is after the first receipt was processed.
        #expect(await eventually { mark.muted.withLock { $0 } })
        #expect(!pipeline.requestOutcomes.contains(dispatcher.reference))
        pipeline.finishInput()
        let summary = try await run.value
        #expect(summary.delivered == 1)
    }
    private func prepare(_ fake: FakeRightyo) throws {
        let file = fake.directory.appendingPathComponent("events.jsonl")
        var events = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
        }
        events[0]["request_outcomes"] = ["version": 1]
        try write(events, to: file)
        let second = events[3...5].map { old -> [String: Any] in
            var event = old
            event["sequence"] = (old["sequence"] as? Int ?? 0) + 10
            event["emitted_at_ms"] = 2100
            if var turn = old["turn"] as? [String: Any] {
                turn["utterance_id"] = "again"; turn["text"] = "mute"; event["turn"] = turn
            }
            if old["request_id"] != nil { event["request_id"] = "tool-demo:again" }
            if old["utterance_id"] != nil { event["utterance_id"] = "again" }
            return event
        }
        try write(second, to: fake.directory.appendingPathComponent("second.jsonl"))
        var terminal = try #require(events.last)
        terminal["sequence"] = 17
        terminal["emitted_at_ms"] = 2100
        try write([terminal], to: fake.directory.appendingPathComponent("terminal.jsonl"))
    }
    private func write(_ events: [[String: Any]], to file: URL) throws {
        let lines = try events.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        var data = Data()
        for line in lines { data.append(line); data.append(10) }
        try data.write(to: file)
    }
}
#endif
