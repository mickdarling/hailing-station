import Dispatch
import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// #924 review round 1. P3-1: a held host clip is decided whole, under one check of the privacy reply hold, so a
/// decision lands before all of its frames (none is sent) or after all of them, never between its words and its audio.
/// P3-2: a reply the hold refused is reported `privacyHeld` and stopped even once the hold is released. Synthetic
/// transport only: no network connection is started.
@Suite(.serialized, .timeLimit(.minutes(1))) struct PrivateReplyHoldClipTests {
    static let clip = AmbientAckClip(pcm: Data(repeating: 5, count: 480), sampleRate: 24_000,
                                     text: "Nothing was sent.")

    /// A decision started while the clip's first frame (its words) is being handed over lands only after its audio too.
    /// The first hand-off waits up to 1 s for the decision, which cannot land while the clip holds the lock; the bound
    /// never decides a pass, it only makes sure the decision is waiting when the lock is released. A clip after it is
    /// suppressed whole: no frame.
    @Test func aDecisionDuringAClipLandsAfterAllOfIt() async throws {
        let landed = DispatchSemaphore(value: 0)
        let box = HoldBox()
        let sender = ClipSender913 { index, sender in
            guard index == 1, let (hold, connection) = box.value else { return }
            DispatchQueue.global().async {
                hold.set(true, connection: connection)
                sender.note("decided")
                landed.signal()
            }
            if landed.wait(timeout: .now() + .seconds(1)) == .success { landed.signal() }
        }
        let rig = try await ClipRig913.make(sender: sender)
        box.set(await rig.listener.replyHold, await rig.session.connectionID)
        #expect(await rig.acknowledge() == "sent")
        #expect(await Self.waits(landed), "the decision never landed")
        #expect(sender.events == ["frame1", "frame2", "decided"])
        #expect(await rig.acknowledge() == "suppressed_privacy")
        #expect(sender.events == ["frame1", "frame2", "decided"])
    }

    /// Both of a clip's sends stalled (handed over, never completed): decisions for this connection and another
    /// complete meanwhile. The bound only limits how long a regression (a completion awaited under the lock) takes to
    /// fail; the sends are then released, so nothing hangs.
    @Test func aStalledClipNeverDelaysAPrivacyDecision() async throws {
        let sender = ClipSender913(stalls: true)
        let rig = try await ClipRig913.make(sender: sender)
        let (hold, connection) = (await rig.listener.replyHold, await rig.session.connectionID)
        var submissions = sender.submissions.stream.makeAsyncIterator()
        let acknowledgement = Task { await rig.acknowledge() }
        _ = try #require(await submissions.next())
        let decided = await Self.waits(Self.deciding(hold, [UUID(), connection]))
        #expect(decided, "a privacy decision waited behind a stalled send")
        #expect(sender.stalled > 0, "the sends were still stalled when privacy was decided")
        sender.release()
        #expect(await acknowledgement.value == "sent")
        #expect(sender.events == ["frame1", "frame2"])
    }

    /// P3-2: the hold's own `.held` decides, not a later read of the hold. With the hold already released, a held
    /// agent reply is still `privacyHeld`, stopped, and not observed as spoken.
    @Test func aHeldReplyIsReportedHeldOnceTheHoldIsReleased() async throws {
        let env = try await ReplyEchoRig904.make(route: "correlated")
        let frame = env.frames[1]
        let (hold, connection) = (await env.listener.replyHold, await env.session.connectionID)
        #expect(!hold.holds(connection))
        await #expect(throws: LocalReplyRefusal.privacyHeld) {
            try await env.listener.requireDelivery(ReplyFrameDelivery<Void>.held, frame: frame, on: env.peer)
        }
        #expect(await env.session.hasStopped(frame))
        #expect(env.wiring.observed.withLock { $0 }.isEmpty)
    }

    /// Sets `connections` held on another thread; signals once done.
    static func deciding(_ hold: PrivateReplyHold, _ connections: [UUID]) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            connections.forEach { hold.set(true, connection: $0) }
            done.signal()
        }
        return done
    }

    /// Whether `semaphore` is signalled within 10 s, waited for off the cooperative pool.
    static func waits(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + .seconds(10)) == .success)
            }
        }
    }
}

/// The hold and connection a sender's hook decides for, set once the rig exists.
final class HoldBox: Sendable {
    private let stored = Mutex<(PrivateReplyHold, UUID)?>(nil)
    var value: (PrivateReplyHold, UUID)? { stored.withLock { $0 } }
    func set(_ hold: PrivateReplyHold, _ connection: UUID) { stored.withLock { $0 = (hold, connection) } }
}

/// A synthetic transport (#913): notes each hand-off as `frameN`, runs `onSubmit` inside it, and completes it at once,
/// or, when it `stalls`, only once released.
final class ClipSender913: Sendable {
    let submissions = AsyncStream<Void>.makeStream()
    private let log = Mutex<[String]>([])
    private let count = Mutex(0)
    private let pending = Mutex<(released: Bool, completions: [@Sendable (NWError?) -> Void])>((false, []))
    private let onSubmit: @Sendable (Int, ClipSender913) -> Void

    init(stalls: Bool = false, onSubmit: @escaping @Sendable (Int, ClipSender913) -> Void = { _, _ in }) {
        self.onSubmit = onSubmit
        pending.withLock { $0.released = !stalls }
    }

    var events: [String] { log.withLock { $0 } }
    var stalled: Int { pending.withLock { $0.completions.count } }
    func note(_ event: String) { log.withLock { $0.append(event) } }

    func submit(_ completion: @escaping @Sendable (NWError?) -> Void) {
        let index = count.withLock { count in
            count += 1
            return count
        }
        note("frame\(index)")
        onSubmit(index, self)
        submissions.continuation.yield(())
        let now = pending.withLock { state -> Bool in
            if !state.released { state.completions.append(completion) }
            return state.released
        }
        if now { completion(nil) }
    }

    func release() {
        let waiting = pending.withLock { state in
            state.released = true
            defer { state.completions = [] }
            return state.completions
        }
        waiting.forEach { $0(nil) }
    }
}

/// One ready session selecting the test target, on a listener whose only peer submits through `sender`.
struct ClipRig913 {
    let session: HostSession
    let listener: WebSocketListener
    let peer: WebSocketPeer

    static func make(sender: ClipSender913) async throws -> Self {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let wiring = ReplyEchoWiring904(owner: await session.connectionID)
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host, hostName: "mac-test",
            singleTerminalReplyFallback: true, ambient: wiring
        )
        let id = UUID()
        let peer = WebSocketPeer(
            id: id, connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), session: session,
            queue: DispatchQueue(label: "synthetic.clip913"), helloTimeout: .seconds(5), log: { _ in },
            onEnd: { _ in }, submitReply: sender.submit
        )
        await listener.installClipPeer913(peer, id: id)
        return Self(session: session, listener: listener, peer: peer)
    }

    /// "Nothing was sent." (words and audio) through the held clip path.
    func acknowledge() async -> String {
        await listener.acknowledgeAmbient(connection: await session.connectionID, target: RecipientTestRig.target,
                                          clip: PrivateReplyHoldClipTests.clip, heldWhilePrivate: true)
    }
}

private extension WebSocketListener {
    func installClipPeer913(_ peer: WebSocketPeer, id: UUID) {
        readyResult = .success(0)
        peers[id] = peer
    }
}
