import Foundation
import Synchronization

/// #704: on CI the whole cooperative pool stalls for seconds at the start of the parallel lane. Heartbeat tasks on the
/// pool and on the main actor stamp the time every 100 ms; a plain thread, which neither can starve, checks them. When
/// either is more than 2 s stale it samples this process once (`/usr/bin/sample`, else `ps -M`) and writes the stacks
/// to stderr, so the next stall names what holds the threads. Only with `CI=true`, or `HAIL_STALL_WATCHDOG=1` locally;
/// once per process.
enum StallWatchdog {
    private static let beats = Mutex((pool: ContinuousClock.now, main: ContinuousClock.now))

    static let started: Void = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] == "true" || environment["HAIL_STALL_WATCHDOG"] == "1" else { return }
        beats.withLock { $0 = (.now, .now) }
        Task.detached(priority: .medium) {
            while true {
                beats.withLock { $0.pool = .now }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        Task { @MainActor in
            while true {
                beats.withLock { $0.main = .now }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let watcher = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let (pool, main) = beats.withLock { (ContinuousClock.now - $0.pool, ContinuousClock.now - $0.main) }
                if max(pool, main) > .seconds(2) { return report(pool: pool, main: main) }
            }
        }
        watcher.name = "hail-stall-watchdog"
        watcher.start()
    }()

    private static func report(pool: Duration, main: Duration) {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let stacks = output(of: "/usr/bin/sample", [pid, "1"]).map(callGraph)
            ?? output(of: "/bin/ps", ["-M", "-p", pid]) ?? "neither sample nor ps -M ran\n"
        let text = "=== #704 stall watchdog in pid \(pid): heartbeats pool \(pool) old, main actor \(main) old ===\n"
            + stacks + "=== end #704 stall watchdog ===\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// What the tool printed, or nil when it could not run or failed.
    private static func output(of tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        (process.standardOutput, process.standardError) = (pipe, pipe)
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    /// The thread stacks only: from "Call graph:" to the summary that follows them.
    private static func callGraph(_ sample: String) -> String {
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else { return sample }
        let end = lines[start...].firstIndex { $0.hasPrefix("Total number in stack") } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n") + "\n"
    }
}
