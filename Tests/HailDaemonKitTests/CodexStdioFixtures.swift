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
    static func withSafety<Result: Sendable>(
        _ transport: CodexStdioTransport,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let safety = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            transport.cancel()
        }
        do {
            let result = try await operation(); safety.cancel(); await safety.value; return result
        } catch { safety.cancel(); await safety.value; throw error }
    }
    static func withChild<Result: Sendable>(
        _ command: OwnedStdioCommand, grace: TimeInterval = 0.1,
        operation: @Sendable (OwnedStdioChild) async throws -> Result
    ) async throws -> Result {
        let child = try OwnedStdioChild(command: command, grace: grace)
        let safety = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            child.cancel()
        }
        do {
            let result = try await operation(child)
            child.cancel(); await child.join(); safety.cancel(); await safety.value
            return result
        } catch {
            child.cancel(); await child.join(); safety.cancel(); await safety.value
            throw error
        }
    }
}
#endif
