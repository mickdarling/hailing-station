import Testing

extension AmbientLegacyStopPathTests {
    @Test func legacyPayloadDoesNotDetermineTheConstructorType() {
        let source = """
        func bind() {
            let stop: StopReason = .legacy(failure)
            let qualified: AmbientListeningState.StopReason = .legacy(resolve(failure))
            use(StopReason.legacy(failure), AmbientListeningState.StopReason.legacy(resolve(failure)))
            use(.legacy(resolve(failure)) as AmbientListeningState.StopReason)
            use(.legacy(failure) as StopReason)
        }
        func reason() -> StopReason {
            if let failure { return .legacy(failure) }
            return .legacy(resolve(fallback))
        }
        func implicit() -> AmbientListeningState.StopReason { .legacy(first ? left : right) }
        """
        #expect(Self.references(in: source) == [
            "bind legacy", "bind legacy", "bind legacy", "bind legacy", "bind legacy", "bind legacy",
            "reason legacy", "reason legacy", "implicit legacy"
        ])
    }

    @Test func stopArgumentsKeepTheirContextAcrossNestedCallsAndBranches() {
        let source = """
        extension AmbientListeningController {
            func callback() {
                controller.cancelTransportRestore(stop: .legacy(failure))
                reconnect.block(resolve(reason, fallback), stop: .legacy(path(for: failure)))
                reconnect.veto(reason, host: host(), stop: first ? .legacy(left) : .legacy(right))
                controller.end(session, reason: nil, cause: diagnostic(), stop: .legacy(first ? left : right))
                controller.stopListening(reason: .legacy(failure))
            }
        }
        """
        #expect(Self.references(in: source) == [
            "callback cancelTransportRestore", "callback legacy", "callback block", "callback legacy",
            "callback veto", "callback legacy", "callback legacy", "callback end", "callback legacy",
            "callback stopListening", "callback legacy"
        ])
    }

    @Test func unrelatedConstructorsInsideStopContextsStayExcluded() {
        let source = """
        func choose(mode: Mode = .legacy(defaultMode())) -> StopReason {
            let other: Mode = .legacy(failure)
            use(.legacy(resolve(failure)) as Mode)
            let stop: StopReason = convert(.legacy(other))
            reconnect.block(.legacy(other), stop: convert(.legacy(failure)))
            otherAPI(stop: .legacy(failure))
            func nested() -> Mode { return .legacy(failure) }
            return stop
        }
        """
        #expect(Self.references(in: source) == ["choose block"])
    }
}
