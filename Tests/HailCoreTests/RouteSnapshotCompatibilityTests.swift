import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct RouteSnapshotCompatibilityTests {
    private func connect(_ socket: ScriptedSocket, advertisesSnapshots: Bool) async throws -> HostConnection {
        let host = try endpoint(), connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: host.url)
        let capabilities = [DiagnosticLimits.capability]
            + (advertisesSnapshots ? [DiagnosticLimits.routeSnapshotCapability] : [])
        try await socket.push(.hello(HelloInfo(versions: [1], capabilities: capabilities, deviceName: "Mac")))
        let ready = AsyncStream<Void>.makeStream()
        let connection = HostConnection(endpoint: host, connector: connector, observer: { snapshot in
            if snapshot.state == .ready { ready.continuation.finish() }
        })
        await connection.connect()
        for await _ in ready.stream {}
        return connection
    }

    @Test(arguments: [false, true])
    func legacyHostReceivesCompatibleRouteEvents(advertisesSnapshots: Bool) async throws {
        let socket = ScriptedSocket()
        let connection = try await connect(socket, advertisesSnapshots: advertisesSnapshots)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/schema/route-snapshot.example.json"))
        guard case .control(.diagnostic(let events)) = try FrameCoding.decode(bytes).payload else {
            Issue.record("expected diagnostic fixture")
            return
        }
        try await connection.sendDiagnostics(events)
        let first = try await diagnosticFrames(socket)
        try #require(first.count == 1)
        let sent = first[0]
        var envelope = try FrameCoding.decode(sent)
        if advertisesSnapshots {
            envelope.payload = .control(.diagnostic(events: events))
            #expect(try FrameCoding.encode(envelope) == sent)
        } else {
            #expect(sent == legacyFrameBytes(id: envelope.id, timestamp: envelope.timestamp))
        }

        let onlySupplementary = events.filter {
            $0.fields[.decision] != nil || $0.fields[.phase] == .token("configure")
        }
        try await connection.sendDiagnostics(onlySupplementary)
        let frames = try await diagnosticFrames(socket)
        try #require(frames.count == (advertisesSnapshots ? 2 : 1))
        if advertisesSnapshots {
            var second = try FrameCoding.decode(frames[1])
            second.payload = .control(.diagnostic(events: onlySupplementary))
            #expect(try FrameCoding.encode(second) == frames[1])
        }
        await connection.disconnect()
    }

    private func diagnosticFrames(_ socket: ScriptedSocket) async throws -> [Data] {
        try await socket.outgoing.filter { bytes in
            if case .control(.diagnostic) = try FrameCoding.decode(bytes).payload { return true }
            return false
        }
    }

    @Test func offlineSnapshotsPreserveTheLastLegacyRecordingToken() async throws {
        let suite = "hail-route-budget-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = ContinuousClock.now
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:], wallNow: { 5 }, clock: { now })
        log.setEnabled(true)
        let route = AudioRouteSnapshot(
            ports: .init(input: .builtInMic, output: .headphones, inputCount: 1, outputCount: 1),
            settings: DeviceDiagnosticsOutputRouteTests.snapshot(output: .headphones).settings
        )
        log.currentAudioRoute = { route }
        let observations = AudioRouteObservations()
        observations.setObserving(log, enabled: true)
        let change = AudioRouteChange(reasonRaw: 4, current: route, previous: route.ports)
        var expected = [try DiagnosticEvent(.appInfo, timestamp: 5)]
        let burst = Int(DeviceDiagnostics.recordRate.capacity)
        for index in 0..<(burst - 2) {
            log.record(.appForeground, timestamp: Int64(index))
            expected.append(try DiagnosticEvent(.appForeground, timestamp: Int64(index)))
        }
        // One legacy token remains. Exhaust the snapshot allowance with both supplementary shapes.
        for _ in 0..<burst {
            observations.publish(.decision(change, .noHardwareEpisode, choseBuiltIn: false, appAttributed: false))
            observations.publish(.configure(before: route.ports, result: route.settings, policyApply: false,
                                            succeeded: true))
        }
        log.recordRouteNotification(reason: 4, previous: route.ports)
        expected.append(try DiagnosticEvent(.routeChange, timestamp: 5, fields: [
            .reason: .token("override"), .route: .token("built_in_mic")
        ]))

        let socket = ScriptedSocket()
        let connection = try await connect(socket, advertisesSnapshots: false)
        let capabilities = await connection.currentSnapshot().capabilities
        while let batch = log.nextBatch(for: capabilities) { try await connection.sendDiagnostics(batch.events) }
        #expect(!log.hasPending)
        #expect(try await DeviceDiagnosticsSendingTests.diagnostics(socket) == expected)
        await connection.disconnect()
    }

    @Test(arguments: [false, true])
    func fullBufferCountsOnlyLegacyEvictions(overflowLegacy: Bool) throws {
        let rig = DeviceDiagnosticsTests()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let log = rig.log()
        log.setEnabled(true)
        log.record(.routeChange, [.phase: .token("configure")])
        let unsent = try #require(log.nextBatch())
        var expected = [try DiagnosticEvent(.appInfo, timestamp: 1_000, fields: DeviceDiagnosticsTests.info)]
        for index in 1..<DeviceDiagnostics.capacity {
            rig.clock.advance(by: .seconds(1))
            log.record(.appForeground, timestamp: Int64(index))
            expected.append(try DiagnosticEvent(.appForeground, timestamp: Int64(index)))
        }
        log.record(.routeChange, [.decision: .token("no_hardware_episode")])
        log.requeue(unsent)
        log.record(.routeChange, [.phase: .token("configure")])
        if overflowLegacy {
            log.record(.appBackground)
            expected[0] = try DiagnosticEvent(.eventsDropped, timestamp: 1_000, fields: [
                .count: .integer(1), .code: .token("app_buffer")
            ])
            expected.append(try DiagnosticEvent(.appBackground, timestamp: 1_000))
        }
        #expect(log.bufferedCount == DeviceDiagnostics.capacity)
        #expect(rig.drain(log) == expected)
    }

    /// Fixed canonical legacy bytes. Only the transport-generated ID and envelope time vary.
    private func legacyFrameBytes(id: UUID, timestamp: Int64) -> Data {
        let change = #"{"fields":{"reason":"category_change","route":"built_in_mic"},"name":"route_change","ts":5}"#
        let start = #"{"fields":{"route":"built_in_speaker"},"name":"reply_playback_start","ts":5}"#
        let payload = #"{"command":"diagnostic","events":[\#(change),\#(start)]}"#
        let json = #"{"id":"\#(id.uuidString)","payload":\#(payload),"source":"terminal","ts":\#(timestamp),"#
            + #""type":"control","v":1}"#
        return Data(json.utf8)
    }
}
