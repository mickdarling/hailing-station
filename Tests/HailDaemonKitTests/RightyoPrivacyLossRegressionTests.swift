#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoPrivacyLossRegressionTests {
    static func started(privateLaunch: Bool, positioned: Bool) -> String {
        let flag = privateLaunch ? #","private":true"# : ""
        let capability = positioned ? #", "duck_after_sample": 1"# : ""
        return """
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"phase"/"request_outcomes":{"version":1},"duck":{"version":3\(flag)},"phase"/' \
          -e 's/"partials": false/"partials": false\(capability)/'
        """
    }

    static let stopped = #"/usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g""#

    static func pipeline(_ fake: FakeRightyo, privateLaunch: Bool,
                         configure: (inout RightyoAmbientPipeline.Configuration) -> Void)
        throws -> RightyoAmbientPipeline {
        var config = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 0.3, termGrace: 0.3))
        config.replyControl = true
        config.startPrivate = privateLaunch
        config.onVoiceDuck = { _ in }
        configure(&config)
        return try RightyoAmbientPipeline(configuration: config, dispatcher: RecordingAmbientDispatcher())
    }

    /// The child leaves fd 3 unread after acknowledging on. Media lines and legacy off are both 15 bytes.
    private func proveFull(_ pipeline: RightyoAmbientPipeline) throws {
        while true {
            errno = 0
            let accepted = pipeline.reportMedia(true)
            let error = errno
            if accepted || error == EINTR { continue }
            try #require(error == EAGAIN)
            return
        }
    }

    /// The child copies stdin to this FIFO. Wait only for the requested bytes or the absolute deadline.
    private func receive(_ descriptor: Int32, count: Int, until deadline: DispatchTime) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: count)
        var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while result.count < count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { break }
            let timeout = Int32((deadline.uptimeNanoseconds - now) / 1_000_000)
            let polled = poll(&ready, 1, timeout)
            if polled < 0, errno == EINTR { continue }
            if polled == 0 { break }
            try #require(polled > 0)
            let length = Darwin.read(descriptor, &buffer, count - result.count)
            try #require(length > 0)
            result.append(contentsOf: buffer.prefix(length))
        }
        return result
    }

    private func waitPastBacklogAge(from start: DispatchTime) async throws {
        let age = (start + .milliseconds(2_100)).uptimeNanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        if now < age { try await Task.sleep(nanoseconds: age - now) }
    }

    private static let fullPipeChild = """
        \(RightyoPrivacyLossRegressionTests.started(privateLaunch: false, positioned: true))
        IFS= read -r line <&3 || exit 1
        [ "$line" = '{"duck":true}' ] || exit 1
        \(AmbientPrivacyEventTests.line("on", sequence: 2, at: 0, extra: #", \"at_ms\": 0"#))
        /bin/cat > received
        \(RightyoPrivacyLossRegressionTests.stopped)
        """

    @Test func publicStdinFlowsForLongerThanBacklogAgeWithControlFull() async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake(Self.fullPipeChild)
        defer { fake.cleanUp() }
        let path = fake.directory.appendingPathComponent("received").path
        try #require(mkfifo(path, 0o600) == 0)
        let reader = open(path, O_RDWR | O_NONBLOCK)
        try #require(reader >= 0)
        defer { close(reader) }
        let retry = Mutex<(@Sendable () -> Void)?>(nil)
        let pipeline = try Self.pipeline(fake, privateLaunch: false) { config in
            config.privacyRetryClock.schedule = { _, work in retry.withLock { $0 = work } }
        }
        #expect(pipeline.reportDuck(true))
        let run = Task { try await pipeline.run() }
        defer { pipeline.finishInput() }
        try #require(await pipeline.privacyKept())
        try proveFull(pipeline)
        #expect(!pipeline.reportDuck(false))
        let first = Data([1, 2]), second = Data([3, 4])
        try #require(pipeline.requestOutcomes.supported)
        let start = DispatchTime.now()
        #expect(pipeline.send(audio: first))
        #expect(try receive(reader, count: first.count, until: start + .seconds(2)) == first)
        try await waitPastBacklogAge(from: start)
        try proveFull(pipeline)
        #expect(pipeline.send(audio: second))
        #expect(try receive(reader, count: second.count, until: start + .seconds(4)) == second)
        let expire = try #require(retry.withLock { $0 })
        expire()
        #expect(pipeline.privacyControl.active && pipeline.requestOutcomes.generation == nil)
        let last = Data([5, 6])
        #expect(pipeline.send(audio: last))
        #expect(try receive(reader, count: last.count, until: start + .seconds(4)) == last)
        pipeline.finishInput()
        let summary = try await run.value
        #expect(summary.child.writtenBytes == 6 && summary.child.droppedBytes == 0)
    }

    @Test func withdrawingBeforePrivateStartupPreservesBothAudioChunks() async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        while IFS= read -r line <&3; do
          echo "$line" >> before
          [ "$line" = '{"media":true}' ] && break
        done
        \(Self.started(privateLaunch: true, positioned: false))
        \(AmbientPrivacyEventTests.line("status", sequence: 2, at: 0))
        /bin/cat > audio.raw
        /bin/cat <&3 > after
        \(Self.stopped)
        """)
        defer { fake.cleanUp() }
        let (events, signal) = AsyncStream<Bool>.makeStream()
        let pipeline = try Self.pipeline(fake, privateLaunch: true) { config in
            config.onVoiceDuck = { if $0 == .status { signal.yield(true) } }
        }
        defer { pipeline.finishInput() }
        _ = pipeline.reportDuck(false)
        #expect(!pipeline.childStarted && pipeline.hearsAudio)
        #expect(pipeline.send(audio: Data([1, 2])))
        try #require(pipeline.reportMedia(true))
        let run = Task {
            defer { signal.finish() }
            return try await pipeline.run()
        }
        var observed = events.makeAsyncIterator()
        try #require(await observed.next() == true)
        #expect(pipeline.send(audio: Data([3, 4])))
        pipeline.finishInput()
        _ = try await run.value
        #expect(AmbientPrivacyAudioGateTests.heard(fake) == Data([1, 2, 3, 4]))
        #expect(try fake.recorded("before") == "{\"media\":true}\n")
        #expect(try fake.recorded("after") == "{\"duck\":false}\n")
    }
}
#endif
