import Foundation
import Synchronization

/// What a finished command left behind. Callers read failure text through `errorText`, which falls back to
/// stdout for a command that reports its failure there.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// What to show for a failed command: stderr, or stdout when stderr is empty.
    public var errorText: String {
        (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs one executable with an argv. Adapters take one of these so tests can script every response and
/// assert the exact argv (no shell is ever involved, so quoting is never an escaping problem) (#11).
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult
}

/// An adapter explicitly owns operation-bearing launch admission rather than a checked handoff.
public protocol LaunchAdmittingDelivery: Adapter {}

extension TmuxAdapter: LaunchAdmittingDelivery {}
extension TmuxReplyAdapter: LaunchAdmittingDelivery {}

/// A runner must place this operation immediately around its synchronous command launch.
public protocol GuardedCommandRunner: CommandRunner {
    func run(_ executable: String, _ arguments: [String], launch: CommandLaunch) async throws -> CommandResult
}

/// Synchronized launch evidence survives even an authority that throws after its operation returned.
public final class CommandLaunch: Sendable {
    public enum Evidence: Sendable, Equatable { case refused, failedBeforeExecution, possiblyExecuted }
    private let state = Mutex(Evidence.refused)
    private let admission: @Sendable (() throws -> Void) throws -> Void
    public var evidence: Evidence { state.withLock { $0 } }

    public init(admission: @escaping @Sendable (() throws -> Void) throws -> Void) {
        self.admission = admission
    }

    /// Never retry an admission error. Only the runner knows whether its launch operation executed.
    public func perform(_ operation: () throws -> Void) throws {
        var result: Result<Void, any Error>?
        try admission {
            guard result == nil else { throw DeliveryAdmissionError.invalidGate }
            state.withLock { $0 = .failedBeforeExecution }
            // Launch errors are returned after the gates release, never thrown through held predicates.
            result = Result(catching: operation)
            if case .success = result { state.withLock { $0 = .possiblyExecuted } }
        }
        guard let result else { throw DeliveryAdmissionError.invalidGate }
        try result.get()
    }
}

#if os(macOS)
/// `Foundation.Process` runner. stdout and stderr stay separate: stderr is drained on a Dispatch thread,
/// not a second cooperative-pool task (which starved the pool under parallel tests), and stdout on the
/// calling detached task; both run to EOF and the stderr drain is joined only after the process has
/// exited, so a verbose child on either pipe cannot wedge the runner. Resolves `executable` through
/// `/usr/bin/env` when it has no slash.
public struct ProcessCommandRunner: GuardedCommandRunner {
    private let beforeLaunch: (@Sendable ([String]) -> Void)?
    public init() { beforeLaunch = nil }
    init(beforeLaunch: @escaping @Sendable ([String]) -> Void) { self.beforeLaunch = beforeLaunch }

    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, launch: CommandLaunch { try $0() })
    }

    public func run(
        _ executable: String, _ arguments: [String], launch: CommandLaunch
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            if executable.contains("/") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + arguments
            }
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            beforeLaunch?(arguments)
            var admissionError: (any Error)?
            do { try launch.perform { try process.run() } } catch {
                guard launch.evidence == .possiblyExecuted else { throw error }
                admissionError = error
            }
            let errHandle = err.fileHandleForReading
            let errBox = DataBox()
            let drained = DispatchGroup()
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                errBox.set(errHandle.readDataToEndOfFile())
                drained.leave()
            }
            let stdout = String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            await withCheckedContinuation { (joined: CheckedContinuation<Void, Never>) in
                drained.notify(queue: .global(qos: .utility)) { joined.resume() }
            }
            let stderr = String(bytes: errBox.get(), encoding: .utf8) ?? ""
            if let admissionError { throw admissionError }
            return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        }.value
    }
}

/// Hands the stderr bytes from the Dispatch thread back to the task. A class because `Mutex` is noncopyable.
private final class DataBox: Sendable {
    private let storage = Mutex(Data())

    func set(_ data: Data) { storage.withLock { $0 = data } }
    func get() -> Data { storage.withLock { $0 } }
}
#endif
