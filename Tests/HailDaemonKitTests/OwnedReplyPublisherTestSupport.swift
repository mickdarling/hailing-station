#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Synchronization
@testable import HailDaemonKit

struct PublisherFixture: Sendable {
    let base: URL
    let root: URL
    let record: URL
    let executable: URL
    let environment: [String: String]

    init(mode: String = "normal", cli: Bool = false) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rp-\(UUID().uuidString.prefix(8))")
        root = base.appendingPathComponent("output"); record = base.appendingPathComponent("record")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let script = base.appendingPathComponent(cli ? "vbsay" : "job")
        try Data((cli ? Self.renderer : Self.job).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        executable = cli ? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/haild") : script
        environment = ["PATH": base.path, "RP_MODE": mode, "RP_RECORD": record.path,
                       "RP_ROOT": root.resolvingSymlinksInPath().path]
    }

    func publisher(
        deadline: Duration = .seconds(3), hooks: OwnedReplyGroupHooks = .init()
    ) throws -> OwnedReplyPublisher {
        try OwnedReplyPublisher(configuration: .init(
            executable: executable, socket: base.appendingPathComponent("reply.sock"), root: root,
            hostID: "synthetic-host", environment: environment, deadline: deadline, hooks: hooks))
    }

    func reply(_ sequence: Int = 1) -> DiagnosticBridgeReply {
        DiagnosticBridgeReply(requestID: UUID(), hostID: "synthetic-host",
                              targetID: DiagnosticReplyBridgeAdapter.targetID, sequence: sequence)
    }

    func shutdown(_ publisher: OwnedReplyPublisher) async throws {
        publisher.stop()
        try await Self.until { publisher.diagnostics().retained == 0 && publisher.diagnostics().queued == 0 }
        try FileManager.default.removeItem(at: base)
    }

    static func until(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw PublisherFixtureFailure.watchdog }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static let job = """
    #!/usr/bin/perl
    use strict; use warnings;
    my $root = $ARGV[$#ARGV];
    die 'group contract' unless getpgrp(0) == $$;
    die 'private root' unless ((stat($root))[2] & 07777) == 0700;
    my $mode = $ENV{RP_MODE};
    $SIG{TERM} = 'IGNORE' if $mode eq 'ignore' || $mode eq 'descendant';
    if ($mode eq 'descendant') {
        my $child = fork(); die 'fork failed' unless defined($child);
        if ($child == 0) { select(undef, undef, undef, 10); exit(0); }
    }
    open(my $f, '>', $ENV{RP_RECORD}) or die 'record'; print {$f} 'owned-group-private-root'; close($f);
    open(my $out, '>', "$root/owned.data") or die 'output'; print {$out} 'synthetic'; close($out);
    exit(23) if $mode eq 'nonzero';
    exit(0) if $mode eq 'descendant';
    select(undef, undef, undef, 10) if $mode eq 'ignore';
    """

    static let renderer = """
    #!/usr/bin/perl
    use strict; use warnings;
    sub stage {
        open(my $f, '>', $ENV{RP_RECORD}) or die 'record'; print {$f} $_[0]; close($f);
    }
    stage('renderer-started');
    die 'group contract' unless getpgrp(0) == getpgrp(getppid()) && getpgrp(0) == getppid();
    stage('renderer-group-verified');
    die 'playback contract' unless $ENV{VBSAY_NOPLAY} eq '1';
    my $output = $ENV{VBSAY_OUT};
    my $job = $output; $job =~ s{/[^/]+$}{};
    my $parent = $job; $parent =~ s{/[^/]+$}{};
    my @expected = stat($ENV{RP_ROOT}); my @actual = stat($parent);
    die 'root contract' unless $actual[0] == $expected[0] && $actual[1] == $expected[1]
        && $job =~ m{/hailing-reply-job-[^/]+$} && ((stat($job))[2] & 07777) == 0700;
    stage('renderer-root-verified');
    die 'private output' unless ((stat($output))[2] & 07777) == 0700;
    $SIG{TERM} = 'IGNORE' if $ENV{RP_MODE} eq 'ignore';
    if ($ENV{RP_MODE} eq 'ignore') {
        my $child = fork(); die 'fork failed' unless defined($child);
        if ($child == 0) { select(undef, undef, undef, 10); exit(0); }
    }
    open(my $f, '>', $ENV{RP_RECORD}) or die 'record'; print {$f} 'owned-cli-group-private-root'; close($f);
    die 'stdout contract' unless ($ENV{VBSAY_STDOUT} // '') eq '1';
    # One whole first streamed frame (#268), so the CLI relays audio while this renderer stays alive.
    binmode(STDOUT); $| = 1; print STDOUT "\0" x 24000;
    select(undef, undef, undef, 10) if $ENV{RP_MODE} eq 'ignore';
    """
}

enum PublisherFixtureFailure: Error { case watchdog }

final class PublisherCheckpoint: Sendable {
    private let ready = Mutex(false)
    private let release = DispatchSemaphore(value: 0)
    func pause() { ready.withLock { $0 = true }; release.wait() }
    var reached: Bool { ready.withLock { $0 } }
    func resume() { release.signal() }
}

actor PublisherEndpointRecorder: HostReplyPublishing {
    private(set) var frames: [Frame] = []
    let blockAt: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    init(blockAt: Int? = nil) { self.blockAt = blockAt }
    func publish(_ frame: Frame) async throws -> Int {
        frames.append(frame)
        if frames.count == blockAt { await withCheckedContinuation { continuation = $0 } }
        return 1
    }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
