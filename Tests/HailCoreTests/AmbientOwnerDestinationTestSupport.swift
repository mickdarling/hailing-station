import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Scripted host barriers and yield-only scheduling; no elapsed-time sleeps drive these tests.
@MainActor
final class OwnerDestinationRun {
    static let reason = "Stopped: the connection or destination went away."
    let rig: AmbientReconnectRig
    let log: DeviceDiagnostics
    private let suite = "hail-owner-destination-\(UUID())"
    private var stopEvents: [DiagnosticEvent] = []

    init() throws {
        rig = try AmbientReconnectRig()
        let defaults = try #require(UserDefaults(suiteName: suite))
        log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        rig.controller.diagnostics = log
        rig.controller.reconnect.sleep = { _ in throw CancellationError() }
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    func stops() -> [DiagnosticEvent] {
        stopEvents += (log.nextBatch()?.events ?? []).filter { $0.name == .ambientStop }
        return stopEvents
    }

    func expectDestinationLoss() {
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.controller.binding == nil)
        #expect(rig.controller.stopReason == Self.reason)
        #expect(rig.unexpected == [Self.reason])
    }

    func until(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw SocketTestError.unavailable }
            await Task.yield()
        }
    }

    func preparePending(stage: AmbientOwnerDestinationTests.Stage) async throws -> String? {
        if stage == .privacy {
            try await rig.socket.push(.duckMode(on: true, reason: "device"))
            try await until { rig.store.duckMode[rig.endpoint.id]?.isOn() == true }
        }
        try await drop()
        var ping: String?
        if stage != .gap {
            try await reconnect()
            ping = try await selectionPing()
            if stage == .privacy {
                try await rig.socket.push(.pong(nonce: try #require(ping)))
                try await until {
                    try await rig.socket.sentFrames().contains { $0.payload == .control(.setPrivacy(on: true)) }
                }
            }
        }
        return ping
    }

    func answerAfterVeto(stage: AmbientOwnerDestinationTests.Stage, ping: String?) async throws {
        // Release the host only after the owner's veto: neither a new socket nor a late answer may restore.
        switch stage {
        case .gap:
            try await reconnect()
            #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) == nil)
        case .selection:
            try await rig.socket.push(.pong(nonce: try #require(ping)))
            try await until { rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) != nil }
        case .privacy:
            try await rig.socket.push(.duckMode(on: true, reason: "device"))
        }
        // The later notice is a receive-loop barrier for the earlier host answer.
        try await rig.socket.push(.mediaMode(on: true))
        try await until { rig.store.mediaMode[rig.endpoint.id]?.on == true }
    }

    func start(listening: Bool = true) async throws {
        rig.store.ambientController = rig.controller
        rig.controller.onUnexpectedStop = { [weak rig] in rig?.unexpected.append($0) }
        rig.controller.reconnect.onNotice = { [weak rig] in rig?.notices.append($0) }
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await rig.store.upsert(rig.endpoint)
        await rig.store.connect(rig.endpoint.id)
        try await handshake()
        let selection = Task { try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id) }
        do {
            try await rig.socket.push(.pong(nonce: try await selectionPing()))
            try await selection.value
        } catch {
            selection.cancel()
            _ = await selection.result
            throw error
        }
        if listening { await rig.controller.turnOn(for: try rig.currentBinding()) }
    }

    func drop() async throws {
        await rig.socket.fail()
        try await until { await rig.retry.isWaiting() }
    }

    func reconnect() async throws {
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await rig.retry.fire()
        try await handshake()
    }

    private func handshake() async throws {
        try await until {
            try await rig.socket.sentFrames().contains { if case .control(.hello) = $0.payload { return true }
                return false }
        }
        try await rig.socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
            capabilities: ["ping", "select_target", "stream_audio", "set_privacy"], deviceName: "Synthetic")))
        try await rig.socket.push(.targets([rig.target]))
        try await until {
            rig.store.snapshots[rig.endpoint.id]?.state == .ready
                && rig.store.snapshots[rig.endpoint.id]?.receivedTargetList == true
        }
    }

    func selectionPing() async throws -> String {
        try await until { try await rig.selectionPing(after: 0) != nil }
        return try #require(try await rig.selectionPing(after: 0))
    }
}
