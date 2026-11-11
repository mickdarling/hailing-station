import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite struct DeviceVoiceStopSessionTests {
    @Test func onlyAWiredAmbientHostAdvertisesTheCapability() async throws {
        let rig = try await RecipientTestRig.make()
        let gate = AmbientAudioGate(target: RecipientTestRig.target, sink: RecordingAmbientSink(), sweepInterval: nil)
        for ambient in [false, true] {
            for wired in [false, true] {
                var callback: (@Sendable (UUID, Int?) async -> Void)?
                if wired { callback = { _, _ in } }
                let session = HostSession(host: rig.host,
                                          authorizer: PersonalTerminalAuthorizer(ambientAudio: ambient ? gate : nil),
                                          deviceVoiceStop: callback)
                let result = await session.receive(helloFrame())
                let frame = try #require(result.frames.first)
                guard case .control(.hello(let hello)) = frame.payload else {
                    Issue.record("expected host hello")
                    return
                }
                #expect(hello.capabilities.contains(DeviceVoiceStop.capability) == (ambient && wired))
                let report = DeviceVoiceStop.report(latencyMs: 1, hostCapabilities: hello.capabilities)
                #expect((report != nil) == (ambient && wired))
            }
        }
    }

    @Test func anUnnegotiatedConnectionFailsClosedAndLogsNotReady() async throws {
        let rig = try await RecipientTestRig.make()
        let events = Mutex<[WebSocketListenerEvent]>([]), calls = Mutex(0)
        let session = HostSession(host: rig.host, deviceVoiceStop: { _, _ in calls.withLock { $0 += 1 } })
        await session.attachLastInput(LastInputLedger(), replyEvent: { event in events.withLock { $0.append(event) } })
        let frame = sessionFrame(payload: .control(.voiceStopped(latencyMs: 5)))
        let beforeHello = await session.receive(frame)
        #expect(beforeHello.frames.count == 1)
        #expect(beforeHello.frames.first?.payload == .control(.error(
            code: .malformed, message: "first frame must be hello"
        )))
        #expect(beforeHello.disposition == .close)
        // A non-hello closes negotiation; the next stop still has no side effect.
        _ = await session.receive(sessionFrame(payload: .control(.ping(nonce: "synthetic"))))
        let afterClose = await session.receive(frame)
        #expect(afterClose.frames.isEmpty)
        #expect(afterClose.disposition == .close)
        #expect(events.withLock { $0.map(\.detail) } == ["reason=not_ready"])
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func anUnwiredAmbientHostIgnoresTheReportWithAToken() async throws {
        let rig = try await RecipientTestRig.make()
        let gate = AmbientAudioGate(target: RecipientTestRig.target, sink: RecordingAmbientSink(), sweepInterval: nil)
        let ignored = Mutex<[String?]>([])
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        await session.attachLastInput(LastInputLedger(), replyEvent: { event in
            ignored.withLock { $0.append(event.detail) }
        })
        _ = await session.receive(helloFrame())
        let result = await session.receive(sessionFrame(payload: .control(.voiceStopped(latencyMs: nil))))
        #expect(result.frames.isEmpty)
        #expect(ignored.withLock { $0 } == ["reason=no_active_stream"])
    }

    @Test func readyReportsUseNegotiatedConnectionIdentityAndAuthorization() async throws {
        let rig = try await RecipientTestRig.make()
        let gate = AmbientAudioGate(target: RecipientTestRig.target, sink: RecordingAmbientSink(), sweepInterval: nil)
        let calls = Mutex<[(UUID, Int?)]>([])
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate),
                                  deviceVoiceStop: { connection, latency in
            calls.withLock { $0.append((connection, latency)) }
        })
        _ = await session.receive(helloFrame())
        let result = await session.receive(sessionFrame(payload: .control(.voiceStopped(latencyMs: 19))))
        #expect(result.frames.isEmpty)
        #expect(calls.withLock { $0.count } == 1)
        let connection = await session.connectionID
        #expect(calls.withLock { $0.first?.0 } == connection)
        #expect(calls.withLock { $0.first?.1 } == 19)
        let denied = HostSession(host: rig.host, deviceVoiceStop: { _, _ in
            Issue.record("read-only authorizer must refuse a voice stop")
        })
        let ignored = Mutex<[String?]>([])
        await denied.attachLastInput(LastInputLedger(), replyEvent: { event in
            ignored.withLock { $0.append(event.detail) }
        })
        _ = await denied.receive(helloFrame())
        let refusal = await denied.receive(sessionFrame(payload: .control(.voiceStopped(latencyMs: nil))))
        #expect(refusal.frames.isEmpty)
        #expect(ignored.withLock { $0 } == ["reason=unauthorized"])
    }

    @Test func repeatedUnauthorizedReportsAreBoundedAndCountSuppressedLines() async throws {
        let rig = try await RecipientTestRig.make()
        let clock = Mutex(ContinuousClock.now), ignored = Mutex<[String?]>([])
        let session = HostSession(host: rig.host, requestClock: { clock.withLock { $0 } })
        await session.attachLastInput(LastInputLedger(), replyEvent: { event in
            ignored.withLock { $0.append(event.detail) }
        })
        _ = await session.receive(helloFrame())
        let frame = sessionFrame(payload: .control(.voiceStopped(latencyMs: nil)))
        for _ in 0..<5 { _ = await session.receive(frame) }
        #expect(ignored.withLock { $0 } == ["reason=unauthorized"])
        clock.withLock { $0 = $0.advanced(by: .seconds(9)) }
        _ = await session.receive(frame)
        #expect(ignored.withLock { $0 } == ["reason=unauthorized"])
        clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
        _ = await session.receive(frame)
        #expect(ignored.withLock { $0 } == ["reason=unauthorized", "reason=unauthorized suppressed=5"])
    }
}
