#if os(macOS)
import Synchronization
import Testing
@testable import HailDaemonKit

/// #896: Network.framework's ready continuation has no deadline. Stopping releases it after a failed wait.
func boundedAmbientListenerStart(_ listener: WebSocketListener) async throws -> UInt16 {
    let result = Mutex<Result<UInt16, any Error>?>(nil)
    await bounded("#896: ambient listener start", within: .seconds(15)) {
        do {
            let port = try await listener.start()
            result.withLock { $0 = .success(port) }
        } catch {
            result.withLock { $0 = .failure(error) }
        }
    }
    let observed = result.withLock { $0 }
    if observed == nil {
        await bounded("#896: ambient listener start cleanup", within: .seconds(15)) {
            await listener.stop(reason: "synthetic startup timed out")
        }
    }
    return try #require(observed).get()
}
#endif
