import Foundation
import Synchronization

/// #704: on CI the whole cooperative pool stalls for seconds at the start of the parallel lane. A heartbeat task on the
/// pool stamps the time every 100 ms; a plain thread, which the pool cannot starve, checks it. When the heartbeat is
/// more than 2 s stale it samples this process once (`/usr/bin/sample`, else `ps -M`) and writes the stacks to stderr,
/// so the next stall names what holds every thread. Only with `CI=true`, or `HAIL_STALL_WATCHDOG=1` locally; once per
/// process.
enum StallWatchdog {
    static let started: Void = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] == "true" || environment["HAIL_STALL_WATCHDOG"] == "1" else { return }
        let beat = Mutex(ContinuousClock.now)
        Task.detached(priority: .medium) {
            while true {
                beat.withLock { $0 = .now }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let watcher = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let stale = beat.withLock { ContinuousClock.now - $0 }
                if stale > .seconds(2) { return report(stale: stale) }
            }
        }
        watcher.name = "hail-stall-watchdog"
        watcher.start()
    }()

    private static func report(stale: Duration) {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let stacks = output(of: "/usr/bin/sample", [pid, "1"]).map(callGraph)
            ?? output(of: "/bin/ps", ["-M", "-p", pid]) ?? "neither sample nor ps -M ran\n"
        let text = "=== #704 stall watchdog: cooperative heartbeat stale for \(stale) in pid \(pid) ===\n"
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
