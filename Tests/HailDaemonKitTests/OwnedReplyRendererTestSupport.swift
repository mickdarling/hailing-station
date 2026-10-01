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
    func until(_ phase: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw RendererFixtureFailure.watchdog(
                    phase: phase, started: FileManager.default.fileExists(atPath: record.path + ".started"),
                    ready: FileManager.default.fileExists(atPath: record.path))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static let script = """
    #!/usr/bin/perl
    use strict;
    use warnings;
    sub write_file {
        my ($path, $bytes) = @_;
        open(my $file, '>', $path) or die "fixture open failed";
        binmode($file);
        print {$file} $bytes or die "fixture write failed";
        close($file) or die "fixture close failed";
    }
    my $output = $ENV{VBSAY_OUT};
    my $record = $ENV{RENDERER_TEST_RECORD};
    write_file("$record.started", "fixture-started");
    die "fixture playback configuration" unless $ENV{VBSAY_NOPLAY} eq '1';
    die "fixture group mismatch" unless getpgrp(0) == getpgrp(getppid());
    die "fixture directory permissions" unless ((stat($output))[2] & 07777) == 0700;
    my $mode = $ENV{RENDERER_TEST_MODE};
    $SIG{TERM} = 'IGNORE' if $mode eq 'ignore-term' || $mode eq 'retirement-race';
    if ($mode eq 'descendant-writer') {
        my $child = fork();
        die "fixture fork failed" unless defined($child);
        if ($child == 0) {
            select(undef, undef, undef, 0.5);
            write_file("$output/late-descendant.raw", pack('C*', 0, 0));
            write_file("$record.done", "normal-descendant-completion");
            exit(0);
        }
    }
    write_file($record, "same-group-private-output");
    exit(23) if $mode eq 'nonzero';
    write_file("$output/synthetic.raw", pack('C*', 0, 0, 1, 0));
    if ($mode eq 'retirement-race') {
        select(undef, undef, undef, 0.01) until -e "$record.exit";
        write_file("$record.normal-exit", "controlled-successful-exit");
        exit(0);
    }
    select(undef, undef, undef, 5) if $mode eq 'ignore-term' || $mode eq 'descendant-writer';
    """
}

private enum RendererFixtureFailure: Error, CustomStringConvertible {
    case watchdog(phase: String, started: Bool, ready: Bool)

    var description: String {
        switch self {
        case let .watchdog(phase, started, ready):
            "renderer fixture watchdog: \(phase); interpreter started: \(started); assertions ready: \(ready)"
        }
    }
}
#endif
