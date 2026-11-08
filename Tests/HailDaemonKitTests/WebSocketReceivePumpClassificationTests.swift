import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func classificationRetiresMalformedAndFailedReceives() async throws {
        let close = NWProtocolWebSocket.Metadata(opcode: .close)
        let closeContext = NWConnection.ContentContext(identifier: "test.close", metadata: [close])
        let text = NWProtocolWebSocket.Metadata(opcode: .text)
        let textContext = NWConnection.ContentContext(identifier: "test.text", metadata: [text])
        let unsupported = NWProtocolWebSocket.Metadata(opcode: .cont)
        let unsupportedContext = NWConnection.ContentContext(identifier: "test.unsupported", metadata: [unsupported])
        let events: [WebSocketIngressPump.Event] = [
            WebSocketIngressPump.classify(Data(), context: unsupportedContext, error: nil),
            .terminal("peer closed"),
            WebSocketIngressPump.classify(nil, context: closeContext, error: nil),
            WebSocketIngressPump.classify(Data(), context: nil, error: nil),
            WebSocketIngressPump.classify(nil, context: textContext, error: nil),
            WebSocketIngressPump.classify(nil, context: textContext, error: .posix(.ECONNRESET))
        ]
        for event in events {
            let rig = PumpRig()
            rig.start { _ in Issue.record("terminal metadata must not reach application processing") }
            rig.transport.deliver(event)
            #expect(rig.lifecycle.isRetired)
            _ = try await rig.ended.wait("classified termination")
            #expect(rig.transport.receives == 1)
        }
    }
    @Test func invalidTransportMessagesRequireProtocolErrorClose() throws {
        let unsupported = NWProtocolWebSocket.Metadata(opcode: .cont)
        let text = NWProtocolWebSocket.Metadata(opcode: .text)
        let unsupportedContext = NWConnection.ContentContext(identifier: "unsupported", metadata: [unsupported])
        let textContext = NWConnection.ContentContext(identifier: "text", metadata: [text])
        let events: [WebSocketIngressPump.Event] = [
            WebSocketIngressPump.classify(nil, context: nil, error: nil),
            WebSocketIngressPump.classify(nil, context: textContext, error: nil),
            WebSocketIngressPump.classify(Data(), context: unsupportedContext, error: nil)
        ]
        for event in events {
            guard case .terminal(_, let protocolError) = event else {
                Issue.record("invalid transport input must be terminal")
                continue
            }
            #expect(protocolError)
        }
        let context = WebSocketPeer.protocolErrorCloseContext()
        let metadata = try #require(context.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata)
        #expect(metadata.opcode == .close)
        #expect(metadata.closeCode == .protocolCode(.protocolError)) // RFC 6455 code 1002.
    }

}
