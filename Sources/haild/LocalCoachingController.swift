public import Foundation
public import HailCore
public import Observation

@MainActor
protocol LocalCoachingControlling: AnyObject {
    var status: ForegroundCoachingStatus { get }
    var startupFailure: ForegroundCoaching.StartupStage? { get }
    var retirementReason: ForegroundCoaching.RetirementReason? { get }
    func control(_ line: String) throws -> Bool
    func off()
    func join() async
}

extension LocalCoachingControlling {
    var startupFailure: ForegroundCoaching.StartupStage? { nil }
    var retirementReason: ForegroundCoaching.RetirementReason? { nil }
}

extension CoachingCommand: LocalCoachingControlling {
    var status: ForegroundCoachingStatus { owner.status }
    var startupFailure: ForegroundCoaching.StartupStage? { owner.startupFailure }
    var retirementReason: ForegroundCoaching.RetirementReason? { owner.retirementReason }
}

/// The window and CLI share the same private coaching composition (#266); no Terminal process is launched.
@MainActor @Observable
public final class LocalCoachingController {
    public struct CLIRefusal: Error {}
    public enum State: Sendable, Equatable { case off, active, stopping, refused }
    public enum Failure: Sendable, Equatable {
        case setup, start(ForegroundCoaching.StartupStage?), ended(ForegroundCoaching.RetirementReason?)

        public var message: String {
            switch self {
            case .setup:
                "Local coaching setup could not load. Check the local configuration and listener profile."
            case .start(.providerSetup):
                "Local transcription could not be prepared. Check its setup and listener profile."
            case .start(.providerStart):
                "Local transcription could not launch. Check the installed transcription service."
            case .start(.deviceSetup):
                "The selected microphone and headphones could not be prepared. Refresh devices and choose them again."
            case .start(.audioStart):
                "Audio could not start on the selected devices. Check microphone access and reconnect the devices."
            case .start(.providerQualification):
                "Local transcription could not accept the audio session. Check its service and start again."
            case .start(.activation), .start(nil):
                "Coaching startup was interrupted. Refresh devices and start again."
            case .ended(let reason): Self.retirementMessage(reason)
            }
        }

        private static func retirementMessage(_ reason: ForegroundCoaching.RetirementReason?) -> String {
            switch reason {
            case .providerEnded:
                "Local transcription stopped unexpectedly. Check its local service and start again."
            case .audioStopped(.routeInvalidated):
                "Coaching stopped because its audio route was invalidated. Refresh devices and choose them again."
            case .audioStopped(.captureEnded), .audioStopped(.captureFailed):
                "The microphone stopped delivering audio. Check microphone access and the selected device."
            case .audioStopped(.qualificationExpired), .audioStopped(.adviceExpired):
                "Coaching stopped because its audio session expired. Start a fresh session."
            case .audioStopped(.playbackFailed):
                "Private coaching playback failed. Check the selected headphones and start again."
            case .audioStopped(.stopped), nil:
                "Coaching stopped. Check the selected devices and local transcription service, then start again."
            }
        }
    }
    public private(set) var state = State.off
    public private(set) var lastFailure: Failure?
    public private(set) var revision: UUID?
    @ObservationIgnored private var command: (any LocalCoachingControlling)?
    @ObservationIgnored private let makeCommand: ([String]) throws -> any LocalCoachingControlling
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var shuttingDown = false

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
        guard !shuttingDown, state == .off, command == nil, participantAwareness else {
            throw CoachingCommandError.invalidControl
        }
        lastFailure = nil
        var failure = Failure.setup
        do {
            let configured = try makeCommand(arguments)
            command = configured
            revision = UUID()
            failure = .start(nil)
            _ = try configured.control("enable aware")
            state = .active
            watch = Task { [weak self] in
                while !Task.isCancelled, configured.status != .off {
                    if configured.status == .retiring { self?.state = .stopping }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                }
                guard !Task.isCancelled else { return }
                self?.lastFailure = .ended(configured.retirementReason)
                self?.command = nil
                self?.revision = nil
                self?.watch = nil
                self?.state = .off
            }
        } catch {
            lastFailure = command?.startupFailure.map { .start($0) } ?? failure
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

    /// Normal app Quit revokes effects synchronously, permanently denies restart, then joins retirement.
    /// The returned task is owned by the application termination delegate, not a disappearing view.
    public func shutdown() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        shuttingDown = true
        let expected = revision
        let task = Task { await self.stop(expectedRevision: expected) }
        shutdownTask = task // Publish ownership before callback-capable revocation.
        if command != nil { state = .stopping }
        watch?.cancel()
        watch = nil
        command?.off()
        return task
    }

    public static func runCLI(_ arguments: [String]) async throws {
        do { try await CoachingCommand.run(arguments) } catch is CoachingCommandError { throw CLIRefusal() }
    }
    public static func reportCLIRefusal() { CoachingTerminal.reportRefusal() }
}
