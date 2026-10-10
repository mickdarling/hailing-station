#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

final class CodexFixtureGate: Sendable {
    let directory: URL
    let path: String
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-codex-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        path = directory.appendingPathComponent("release").path
        guard mkfifo(path, 0o600) == 0 else { throw CodexAppServerError.unavailable }
    }
    func release() async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        var descriptor = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        while descriptor < 0, errno == ENXIO, ContinuousClock().now < deadline {
            await Task.yield(); descriptor = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0, fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw CodexAppServerError.unavailable
        }
        defer { close(descriptor) }
        var byte: UInt8 = 1
        guard Darwin.write(descriptor, &byte, 1) == 1 else { throw CodexAppServerError.unavailable }
    }
    func remove() throws { try FileManager.default.removeItem(at: directory) }
}
enum CodexAppServerFixtures {
    static let target = "codex-owned:owned"
    static func command(gate: CodexFixtureGate? = nil, status: String = "completed",
                        early: Bool = true, terminal: Bool = true, extra: String = "",
                        approvalsReviewer: String? = "user", nullApprovalsReviewer: Bool = false,
                        echoedCwd: String? = nil) -> OwnedStdioCommand {
        let reviewer = nullApprovalsReviewer ? "approvalsReviewer=>undef,"
            : approvalsReviewer.map { "approvalsReviewer=>'\($0)'," } ?? ""
        let code = #"use JSON::PP; $|=1; $SIG{TERM}='IGNORE'; $gate=shift @ARGV; $number=0; "# +
            #"sub sendmsg { print encode_json($_[0]), "\n"; } while(<STDIN>) { $r=decode_json($_); "# +
            #"next unless exists $r->{id}; $id=$r->{id}; if($r->{method} eq 'initialize') { "# +
            #"sendmsg({id=>$id,result=>{userAgent=>'invented',codexHome=>'/synthetic-home',"# +
            #"platformFamily=>'unix',platformOs=>'macos'}}); } elsif($r->{method} eq 'thread/start') { "# +
            #"die unless $r->{params}->{approvalsReviewer} eq 'user'; "# +
            #"sendmsg({id=>$id,result=>{approvalPolicy=>'never',"# + reviewer +
            #"sandbox=>{type=>'readOnly',networkAccess=>"# +
            #"JSON::PP::false},cwd=>"# + (echoedCwd.map { "'\($0)'" } ?? #"$r->{params}->{cwd}"#) + "," +
            #"thread=>{id=>'synthetic-thread',ephemeral=>JSON::PP::true}}}); } else { "# +
            #"$number++; $turn='synthetic-turn-'.$number; "# +
            (early ? "" : response) + events + extra +
            (terminal ? terminalEvent(status) : "") +
            #"if($gate) { open($fh,'<',$gate) or die; sysread($fh,$byte,1); close($fh); } "# +
            (early ? response : "") + "} }"
        var command = OwnedStdioCommand(executable: "/usr/bin/perl", arguments: ["-e", code])
        if let gate { command.arguments.append(gate.path) }
        return command
    }
    private static let response = #"sendmsg({id=>$id,result=>{turn=>{id=>$turn,status=>'inProgress',items=>[]}}}); "#
    static let events =
        #"sendmsg({method=>'turn/started',params=>{threadId=>'synthetic-thread',turn=>{id=>$turn,"# +
        #"status=>'inProgress',items=>[]}}}); "# +
        #"sendmsg({method=>'item/completed',params=>{threadId=>'synthetic-thread',"# +
        #"turnId=>$turn,item=>{id=>'synthetic-item',type=>'agentMessage',phase=>'final_answer',"# +
        #"text=>'invented final text'}}}); "#
    static func terminalEvent(_ status: String) -> String {
        #"sendmsg({method=>'turn/completed',params=>{threadId=>'synthetic-thread',"# +
            "turn=>{id=>\u{0024}turn,status=>'\(status)',items=>[]}}}); "
    }
    static func host(_ adapter: CodexAppServerAdapter, capture: Bool = true, tier: Tier = .open) async throws
        -> HailHost {
        let registry = Registry(); try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(target, binding: adapter.sessionID, tier: tier, capture: capture)
        return try HailHost(registry: registry, sanitizing: .init(newlines: .split), store: InMemoryPolicyStore(policy))
    }
    static func binding() throws -> ProviderSessionBinding {
        try ProviderSessionBinding(hostID: "synthetic-host", providerID: "codex-owned", targetID: target,
                                   sessionID: "synthetic-session")
    }
    static func context(_ binding: ProviderSessionBinding) -> ProviderTurnContext {
        ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: binding)
    }
    static func record(_ method: String, turn: String = "turn", thread: String = "thread",
                       item: JSONValue? = nil, status: String = "inProgress") throws -> CodexAppServerRecord {
        var params: [String: JSONValue] = ["threadId": .string(thread)]
        if method == "item/completed" { params["turnId"] = .string(turn); params["item"] = item } else {
            params["turn"] = .object(["id": .string(turn), "status": .string(status), "items": .array([])])
        }
        let record = try CodexAppServerRecord(.init(method: method, params: .object(params)))
        return try #require(record)
    }
    static func item(_ id: String = "item", text: String = "invented", phase: JSONValue = .string("final_answer"),
                     delivery: JSONValue = .null, questions: JSONValue = .null) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "phase": phase, "delivery": delivery,
                 "questions": questions, "text": .string(text)])
    }
}
#endif
