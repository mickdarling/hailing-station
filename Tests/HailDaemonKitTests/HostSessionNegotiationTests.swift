import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct HostSessionNegotiationTests {
    @Test func helloNegotiatesThenPingKeepsIndependentState() async throws {
        let (host, _) = try await sessionHost()
        let session = HostSession(host: host, hostName: "mac-studio", now: { 42 })

        let negotiation = await session.receive(helloFrame(versions: [99, 1]))
        #expect(negotiation.disposition == .keepOpen)
        guard case .hello(let hello) = try onlyControl(negotiation) else {
            Issue.record("expected host hello")
            return
        }
        #expect(hello.versions == [1])
        #expect(hello.capabilities == HostSession.capabilities)
        #expect(hello.deviceName == "mac-studio")
        #expect(negotiation.frames[0].timestamp == 42)

        let pong = await session.receive(sessionFrame(payload: .control(.ping(nonce: "abc"))))
        #expect(try onlyControl(pong) == .pong(nonce: "abc"))
        #expect(pong.disposition == .keepOpen)
    }

    @Test func unsupportedVersionSendsProtocolErrorAndCloses() async throws {
        let (host, _) = try await sessionHost()
        let session = HostSession(host: host)

        let result = await session.receive(helloFrame(versions: [2], envelopeVersion: 2))
        guard case .error(let code, _) = try onlyControl(result) else {
            Issue.record("expected protocol error")
            return
        }
        #expect(code == .protocolVersion)
        #expect(result.disposition == .close)
        #expect(await session.receive(helloFrame()).frames.isEmpty)
    }

    @Test func firstFrameMustBeHelloAndDuplicateHelloCloses() async throws {
        let (host, _) = try await sessionHost()
        let first = HostSession(host: host)
        let notHello = await first.receive(sessionFrame(payload: .control(.ping(nonce: "x"))))
        #expect(try onlyControl(notHello) == .error(code: .malformed, message: "first frame must be hello"))
        #expect(notHello.disposition == .close)

        let duplicate = HostSession(host: host)
        _ = await duplicate.receive(helloFrame())
        let result = await duplicate.receive(helloFrame())
        #expect(try onlyControl(result) == .error(code: .malformed, message: "hello already received"))
        #expect(result.disposition == .close)
    }

    @Test func negotiatedVersionIsRequiredOnEveryLaterFrame() async throws {
        let (host, _) = try await sessionHost()
        let session = HostSession(host: host)
        _ = await session.receive(helloFrame())
        let result = await session.receive(sessionFrame(version: 2, payload: .control(.ping(nonce: "x"))))
        guard case .error(let code, _) = try onlyControl(result) else {
            Issue.record("expected protocol error")
            return
        }
        #expect(code == .protocolVersion)
        #expect(result.disposition == .close)
    }

    @Test func malformedAndOversizedFramesFailClosedWithoutParsing() async throws {
        let (host, _) = try await sessionHost()
        let malformed = await HostSession(host: host).receive(Data("{".utf8))
        #expect(malformed.disposition == .close)
        guard case .error(let malformedCode, _) = try onlyControl(malformed) else {
            Issue.record("expected malformed error")
            return
        }
        #expect(malformedCode == .malformed)

        let oversizedData = Data(repeating: 0x20, count: PayloadLimits.defaultMaxFrameBytes + 1)
        let oversized = await HostSession(host: host).receive(oversizedData)
        #expect(oversized.disposition == .close)
        guard case .error(let oversizedCode, _) = try onlyControl(oversized) else {
            Issue.record("expected oversized error")
            return
        }
        #expect(oversizedCode == .malformed)
    }
}
