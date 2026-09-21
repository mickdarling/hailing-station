import Foundation

struct SerializedWebSocketConnector: WebSocketConnecting {
    let predecessor: Task<Void, Never>
    let base: any WebSocketConnecting

    func open(url: URL, subprotocol: String) async throws -> any WebSocketTransport {
        await predecessor.value
        try Task.checkCancellation()
        return try await base.open(url: url, subprotocol: subprotocol)
    }
}

func drainingTransportBarrier(for connection: HostConnection) -> Task<Void, Never> {
    Task {
        let handoff = await connection.retire()
        await handoff.value
    }
}

extension HostConnection {
    func replaceLoop(reconnectAttempt: Int? = nil) async {
        generation &+= 1
        let token = generation
        loopTask?.cancel()
        cancelNegotiationDeadline()
        let handoff = beginTransportHandoff()
        clearSocketDiagnostics()
        loopTask = Task { [weak self] in
            await handoff.value
            guard let self, !Task.isCancelled, await self.isCurrent(token) else { return }
            if let reconnectAttempt,
               !(await self.waitToReconnect(attempt: reconnectAttempt, token: token)) { return }
            await self.run(token: token, reconnectAttempt: reconnectAttempt ?? 0)
        }
    }

    func beginTransportHandoff() -> Task<Void, Never> {
        let priorBarrier = transportBarrier
        openingGeneration = nil
        let closingSocket = socket
        socket = nil
        let handoff = Task {
            if let priorBarrier { await priorBarrier.value }
            if let closingSocket { await closingSocket.close() }
        }
        transportBarrier = handoff
        return handoff
    }

    private func run(token: UInt64, reconnectAttempt initialAttempt: Int) async {
        var reconnectAttempt = initialAttempt
        while isCurrent(token), wantsConnection, !Task.isCancelled {
            snapshot.connectionGeneration = UUID()
            await publish(.connecting, token: token)
            guard isCurrent(token), wantsConnection, !Task.isCancelled else { return }
            do {
                try await connectAndReceive(
                    token: token,
                    timeoutReconnectAttempt: reconnectAttempt + 1
                )
            } catch {
                if await shouldStop(after: error, token: token) { return }
                if snapshot.state == .ready { reconnectAttempt = 0 }
                reconnectAttempt += 1
                if !(await waitToReconnect(attempt: reconnectAttempt, token: token)) { return }
            }
        }
    }

    private func connectAndReceive(token: UInt64, timeoutReconnectAttempt: Int) async throws {
        scheduleNegotiationDeadline(token: token, reconnectAttempt: timeoutReconnectAttempt)
        openingGeneration = token
        transportBarrier = loopTask
        let opened: any WebSocketTransport
        do {
            opened = try await connector.open(url: snapshot.endpoint.url, subprotocol: Self.subprotocolName)
        } catch {
            finishOpening(token: token)
            throw error
        }
        finishOpening(token: token)
        guard isCurrent(token), wantsConnection else {
            await opened.close()
            return
        }
        socket = opened
        await publish(.negotiating, token: token)
        let hello = try await negotiate(on: opened, token: token)
        guard isCurrent(token), wantsConnection else { return }
        cancelNegotiationDeadline()
        snapshot.negotiatedVersion = hello.version
        snapshot.capabilities = hello.capabilities
        await publish(.ready, token: token)
        try await sendPing(generation: token)
        try await send(.listTargets, generation: token)
        while isCurrent(token), wantsConnection, !Task.isCancelled {
            let data = try await opened.receive()
            guard isCurrent(token), wantsConnection else { return }
            try await process(data, generation: token)
        }
    }

    private func finishOpening(token: UInt64) {
        guard openingGeneration == token else { return }
        openingGeneration = nil
        transportBarrier = nil
    }

    private func shouldStop(after error: any Error, token: UInt64) async -> Bool {
        if error is CancellationError { return true }
        guard isCurrent(token), wantsConnection else { return true }
        cancelNegotiationDeadline()
        let handoff = beginTransportHandoff()
        clearSocketDiagnostics()
        await handoff.value
        guard isCurrent(token), wantsConnection else { return true }
        guard let failure = error as? HostConnectionFailure else { return false }
        await publish(.failed(reason: failure.description), token: token)
        return true
    }

    private func waitToReconnect(attempt: Int, token: UInt64) async -> Bool {
        let delay = schedule.delay(attempt: attempt, jitterUnit: jitter())
        await publish(.reconnecting(attempt: attempt, nextDelay: delay), token: token)
        do {
            try await sleep(.milliseconds(Int64((delay * 1_000).rounded())))
            return true
        } catch {
            return false
        }
    }
}
