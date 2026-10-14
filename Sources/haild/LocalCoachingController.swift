public import Foundation
import HailCore
public import Observation

@MainActor
protocol LocalCoachingControlling: AnyObject {
    var status: ForegroundCoachingStatus { get }
    func control(_ line: String) throws -> Bool
    func off()
    func join() async
}

extension CoachingCommand: LocalCoachingControlling {
    var status: ForegroundCoachingStatus { owner.status }
}

/// The window and CLI share the same private coaching composition (#266); no Terminal process is launched.
@MainActor @Observable
public final class LocalCoachingController {
    public struct CLIRefusal: Error {}
    public enum State: Sendable, Equatable { case off, active, stopping, refused }
    public private(set) var state = State.off
    public private(set) var revision: UUID?
    @ObservationIgnored private var command: (any LocalCoachingControlling)?
    @ObservationIgnored private let makeCommand: ([String]) throws -> any LocalCoachingControlling
    @ObservationIgnored private var watch: Task<Void, Never>?

    public init(rendererEnvironment: [String: String]? = nil) {
        makeCommand = { try CoachingCommand.native(CoachingConfiguration.parse($0),
                                                   rendererEnvironment: rendererEnvironment) }
    }

    init(makeCommand: @escaping ([String]) throws -> any LocalCoachingControlling) {
        self.makeCommand = makeCommand
    }

    isolated deinit { watch?.cancel(); command?.off() }

    /// Called only by an explicit local Start control after participant awareness is confirmed.
    public func start(arguments: [String], participantAwareness: Bool) throws {
        guard state == .off, command == nil, participantAwareness else { throw CoachingCommandError.invalidControl }
        do {
            let configured = try makeCommand(arguments)
            command = configured
            revision = UUID()
            _ = try configured.control("enable aware")
            state = .active
            watch = Task { [weak self] in
                while !Task.isCancelled, configured.status != .off {
                    if configured.status == .retiring { self?.state = .stopping }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                }
                guard !Task.isCancelled else { return }
                self?.command = nil
                self?.revision = nil
                self?.watch = nil
                self?.state = .off
            }
        } catch {
            command?.off()
            state = .refused
            throw CoachingCommandError.invalidConfiguration
        }
    }

    public func setOwnerListening(_ listening: Bool) throws {
        guard state == .active, let command else { throw CoachingCommandError.invalidControl }
        _ = try command.control(listening ? "owner idle" : "owner answering")
    }

    /// Stops effects immediately, then joins the exact owned child's retirement before allowing another Start.
    public func stop() async { await stop(expectedRevision: revision) }

    public func stop(expectedRevision: UUID?) async {
        guard revision == expectedRevision else { return }
        guard let owned = command else { state = .off; return }
        state = .stopping
        owned.off()
        watch?.cancel()
        watch = nil
        await owned.join()
        guard command === owned else { return }
        command = nil
        revision = nil
        state = .off
    }

    public static func runCLI(_ arguments: [String]) async throws {
        do { try await CoachingCommand.run(arguments) } catch is CoachingCommandError { throw CLIRefusal() }
    }
    public static func reportCLIRefusal() { CoachingTerminal.reportRefusal() }
}
