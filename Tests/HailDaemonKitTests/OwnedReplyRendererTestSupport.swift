#if os(macOS)
import Foundation
@testable import HailDaemonKit

struct RendererFixture: Sendable {
    let base: URL
    let outputRoot: URL
    let record: URL
    let environment: [String: String]

    init(mode: String) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("owned-renderer-test-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        outputRoot = base.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        record = base.appendingPathComponent("record")
        let script = base.appendingPathComponent("vbsay")
        try Data(Self.script.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        environment = ["PATH": mode == "missing" ? "" : base.path, "RENDERER_TEST_MODE": mode,
                       "RENDERER_TEST_RECORD": record.path]
    }

    func start() throws -> OwnedReplyRenderer {
        try OwnedReplyRenderer(text: "synthetic", outputRoot: outputRoot, environment: environment)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RendererFixtureFailure.watchdog }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static let script = """
    #!/usr/bin/python3
    import os, signal, stat, time
    from pathlib import Path
    output = Path(os.environ["VBSAY_OUT"])
    assert os.environ["VBSAY_NOPLAY"] == "1"
    assert os.getpgrp() == os.getpgid(os.getppid())
    assert stat.S_IMODE(output.stat().st_mode) == 0o700
    mode = os.environ["RENDERER_TEST_MODE"]
    if mode == "ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if mode == "descendant-writer":
        child = os.fork()
        if child == 0:
            time.sleep(0.5)
            (output / "late-descendant.raw").write_bytes(bytes([0, 0]))
            Path(os.environ["RENDERER_TEST_RECORD"] + ".done").write_text("normal-descendant-completion")
            os._exit(0)
    Path(os.environ["RENDERER_TEST_RECORD"]).write_text("same-group-private-output")
    if mode == "nonzero":
        raise SystemExit(23)
    (output / "synthetic.raw").write_bytes(bytes([0, 0, 1, 0]))
    if mode in ("ignore-term", "descendant-writer"):
        time.sleep(5)
    """
}

private enum RendererFixtureFailure: Error { case watchdog }
#endif
