import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Collects the adapter's token-only evidence (#894) and renders it as haild's error log writes it.
final class EvidenceLog: Sendable {
    private let storage = Mutex<[TmuxDeliveryEvidence]>([])
    var all: [TmuxDeliveryEvidence] { storage.withLock { $0 } }
    func append(_ evidence: TmuxDeliveryEvidence) { storage.withLock { $0.append(evidence) } }
    /// `event detail`, one per report.
    var lines: [String] { all.map { "\($0.event) \($0.detail)" } }
    func lines(_ event: String) -> [String] { lines.filter { $0.hasPrefix(event + " ") } }

    /// The JSON lines `haild run` writes to its error log (`logNetworkEvent`).
    var errorLog: [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return all.compactMap { evidence in
            let event = WebSocketListenerEvent(event: evidence.event, detail: evidence.detail)
            return (try? encoder.encode(event)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Privacy (#894): every detail is `key=value` tokens of lowercase letters, digits and `_`, so it can hold no
    /// words, preview or hash of a text; and no rendered line holds any word of the texts the test delivered or
    /// typed (`_` joins a word, so `stale_input` is a reason token, never the word "input").
    func expectTokensOnly(excluding texts: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for evidence in all {
            #expect(
                evidence.detail.wholeMatch(of: #/[a-z_]+=[a-z0-9_]+( [a-z_]+=[a-z0-9_]+)*/#) != nil,
                "not tokens only: \(evidence.detail)", sourceLocation: sourceLocation
            )
        }
        let words = Set(texts.flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber } }.map(String.init))
        for line in errorLog {
            let tokens = Set(line.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
            #expect(tokens.isDisjoint(with: words), "a delivered word in: \(line)", sourceLocation: sourceLocation)
            for text in texts where line.localizedCaseInsensitiveContains(text) {
                Issue.record("text in: \(line)", sourceLocation: sourceLocation)
            }
        }
    }
}

/// A tmux adapter over a scripted runner, with its submit outcomes and its evidence.
struct EvidenceHarness {
    let adapter: TmuxAdapter
    let runner: FakeCommandRunner
    let outcomes = OutcomeLog()
    let evidence = EvidenceLog()

    init(_ pane: ScriptedPane, timing: TmuxSubmitTiming) {
        self.init(FakeCommandRunner { pane.respond($0) }, timing: timing)
    }

    init(_ runner: FakeCommandRunner, timing: TmuxSubmitTiming) {
        let (outcomes, evidence) = (outcomes, evidence)
        self.runner = runner
        adapter = TmuxAdapter(
            runner: runner, pollInterval: nil, submitTiming: timing,
            submitObserver: { outcomes.append($0) }, evidenceObserver: { evidence.append($0) }
        )
    }

    var keys: [String] { get async { await runner.delivered } }

    /// Fast waits; a clear limit short enough that pending text is refused quickly.
    static func timing(settleLimit: Duration = .seconds(5), settleFloor: Duration = .milliseconds(1))
        -> TmuxSubmitTiming {
        TmuxSubmitTiming(
            settleFloor: settleFloor, pollInterval: .milliseconds(2), quiet: .milliseconds(6),
            settleLimit: settleLimit, confirmLimit: .milliseconds(500), clearLimit: .milliseconds(120)
        )
    }
}

extension Array {
    /// The single element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
