#if os(macOS)
import Foundation
import HailProtocol
@testable import HailDaemonKit

enum CodexStdioFixtures {
    static func command(_ code: String) -> OwnedStdioCommand {
        OwnedStdioCommand(executable: "/usr/bin/perl", arguments: ["-e", "$|=1; " + code])
    }
    static let echo = command(
        #"while (<STDIN>) { /"id":(\d+)/ or die; print "{\"id\":$1,\"result\":{\"ok\":true}}\n"; }"#)
    static func reply(_ body: String) -> OwnedStdioCommand {
        command(#"$_=<STDIN>; /"id":(\d+)/ or die; "# + body + "; while (<STDIN>) {}")
    }
    static func firstChunk(_ child: OwnedStdioChild) async throws -> Data {
        var iterator = child.chunks.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw CodexStdioError.transportLost }
        return data
    }
    static func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock().now < deadline else { throw CodexStdioError.timedOut }
            await Task.yield()
        }
    }
    static func stopped(_ transport: CodexStdioTransport) async {
        transport.cancel(); await transport.join()
    }
}
#endif
