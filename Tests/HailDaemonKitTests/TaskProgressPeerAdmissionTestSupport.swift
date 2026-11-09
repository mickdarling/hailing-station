#if os(macOS)
import Darwin
import Dispatch
import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

/// Directory notifications acknowledge fixture writes; elapsed time is only a failure watchdog.
final class TaskProgressPeerFileWatch: Sendable {
    private let source: any DispatchSourceFileSystemObject
    private let queue = DispatchQueue(label: "synthetic.task-progress.acknowledgement")
    private let events = AsyncStream<Void>.makeStream()

    init(_ directory: URL) throws {
        let descriptor = open(directory.path, O_EVTONLY)
        try #require(descriptor >= 0)
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                           eventMask: .write, queue: queue)
        let continuation = events.continuation
        source.setEventHandler { continuation.yield(()) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel(); events.continuation.finish() }

    func wait(_ name: String, in fixture: SlowTmuxCommandFixture) async throws {
        let continuation = events.continuation
        let watchdog = DispatchWorkItem { continuation.finish() }
        queue.asyncAfter(deadline: .now() + .seconds(15), execute: watchdog)
        defer { watchdog.cancel() }
        var iterator = events.stream.makeAsyncIterator()
        while !fixture.exists(name) {
            try #require(await iterator.next() != nil, "fixture acknowledgement: \(name)")
        }
    }
}

struct TaskProgressPeerRig {
    let wake: TaskProgressGuardedWakeRig
    let peerID: UUID
    let peer: WebSocketPeer
    let controller: ListenerTaskProgress
    let fixture: SlowTmuxCommandFixture
    let files: TaskProgressPeerFileWatch
    let launch: RecipientPublicationGate
    let teardown: OwnerAdmissionTestBarrier
    let watchdog: any DispatchSourceTimer

    static func make(beforeAdmission: Bool) async throws -> Self {
        let fixture = try SlowTmuxCommandFixture()
        let files = try TaskProgressPeerFileWatch(fixture.directory)
        let launch = RecipientPublicationGate(timeout: .seconds(15))
        let runner = ProcessCommandRunner(beforeLaunch: { arguments in
            let paste = arguments.contains("paste-buffer")
                || arguments.contains(where: { $0.hasPrefix("paste-buffer ") })
            if beforeAdmission && paste { _ = launch.block(onDedicatedQueue: true) }
        })
        let timing = TmuxSubmitTiming(settleFloor: .zero, pollInterval: .milliseconds(1), quiet: .milliseconds(1),
                                      settleLimit: .seconds(1), confirmLimit: .seconds(1))
        let adapter = TmuxAdapter(runner: runner, tmux: fixture.executable, socket: "synthetic-socket",
                                  pollInterval: nil, submitTiming: timing)
        let wake = try await TaskProgressGuardedWakeRig.make(adapter: adapter, name: "codex",
                                                            binding: SlowTmuxCommandFixture.binding)
        let (peerID, peer) = try await wake.listener.taskProgressPeerFixture()
        let controller = try #require(await wake.listener.taskProgressController)
        let teardown = OwnerAdmissionTestBarrier()
        let watchdog = DispatchSource.makeTimerSource()
        let deadlines = wake.clock.scheduled.continuation, finished = wake.finished.continuation
        let entered = teardown.entered.continuation
        watchdog.setEventHandler { deadlines.finish(); finished.finish(); entered.finish() }
        watchdog.schedule(deadline: .now() + .seconds(20))
        watchdog.resume()
        return Self(wake: wake, peerID: peerID, peer: peer, controller: controller,
                    fixture: fixture, files: files, launch: launch, teardown: teardown, watchdog: watchdog)
    }

    private func endPeer(task: TaskProgressTask, stopping: Bool = false) -> Task<Void, Never> {
        Task {
            await PeerAmbientTeardownScope.$beforeEnd.withValue({ await teardown.hold(task) }, operation: {
                if stopping { await wake.listener.stop() } else { await wake.listener.peerEnded(peerID) }
            })
        }
    }

    func withEndedPeer(
        task: TaskProgressTask, stopping: Bool = false, operation: () async throws -> Void
    ) async throws {
        var entered = teardown.entered.stream.makeAsyncIterator()
        let ending = endPeer(task: task, stopping: stopping)
        do {
            _ = try #require(await entered.next())
            try await operation()
        } catch {
            release()
            await ending.value
            await wake.listener.stop()
            throw error
        }
        teardown.release()
        await ending.value
    }

    func replacePeer(sameAudience: Bool) async throws -> WebSocketPeer {
        let session: HostSession
        if sameAudience {
            session = await peer.session
        } else {
            session = HostSession(host: wake.host, authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host")
            _ = await session.receive(helloFrame(capabilities: [SessionUpdateCard.capability]))
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: wake.target))))
        }
        let successor = WebSocketPeer(id: UUID(),
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), session: session,
            queue: DispatchQueue(label: "synthetic.task-progress.successor"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { $0(nil) })
        let connection = await session.connectionID, generation = await session.selectionGeneration
        await wake.listener.installGuardedWakePeer(successor, target: wake.target,
                                                   connection: connection, generation: generation)
        if !sameAudience { wake.wiring.select(connection: connection) }
        return successor
    }

    func release() { watchdog.cancel(); launch.release(); teardown.release(); fixture.release() }
}

extension WebSocketListener {
    func taskProgressPeerFixture() throws -> (UUID, WebSocketPeer) {
        let entry = try #require(peers.first)
        return (entry.key, entry.value)
    }
}
#endif
