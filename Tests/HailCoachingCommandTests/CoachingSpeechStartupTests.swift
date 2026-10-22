import Foundation
import HailCore
import Testing
@testable import HailDaemonKit
@testable import haild

/// Only an authored private executable on the injected PATH, never the installed vbsay or live factory.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct CoachingSpeechStartupTests {
    @Test func postSpawnCancellationKeepsHandleAndJoinsBeforeRenderReturns() async throws {
        for _ in 0..<5 {
            let root = TestScratch.url("coaching-startup")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let output = root.appendingPathComponent("output"), script = root.appendingPathComponent("vbsay")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try Data("#!/usr/bin/perl\n$SIG{TERM} = 'IGNORE'; select(undef, undef, undef, 5);\n".utf8)
                .write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            var owned: OwnedReplyRenderer?
            let speech = CoachingSpeechRenderer { text in
                let child = try OwnedReplyRenderer.startForJoinedRetirement(text: text, outputRoot: output,
                    environment: ["PATH": root.path], hooks: ReplyRendererLifecycleHooks(startup: {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }))
                owned = child
                return LocalCoachingSpeechSource(renderer: child)
            }
            let task = Task {
                do {
                    try await speech.render("authored") { _ in Issue.record("Startup-cancelled render emitted") }
                    Issue.record("Startup cancellation unexpectedly succeeded")
                } catch { /* Cancellation/deferred cleanup is expected only after the exact owned join. */ }
            }
            await task.value
            let child = try #require(owned)
            #expect(!child.isRunning && child.cleanupDisposition == .deferred)
            // The child wrote nothing, so its deferred folder holds nothing to recover and is removed (#800);
            // the authored scratch around it stays until the test process exits.
            let deadline = ContinuousClock.now + .seconds(5)
            while FileManager.default.fileExists(atPath: child.outputDirectory.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!FileManager.default.fileExists(atPath: child.outputDirectory.path))
        }
    }
}
