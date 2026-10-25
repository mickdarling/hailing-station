#if os(macOS)
import Foundation
@testable import HailDaemonKit

/// Fake RightyO pieces for the meeting control (#735 MM-D, rightyo#227). Synthetic only.
extension FakeRightyo {
    /// `"meeting": <json>, ` for a `started` line, or nothing: the raw advertisement, so a malformed one can be tried.
    static func meetingAdvert(_ json: String?) -> String { json.map { "\"meeting\": \($0), " } ?? "" }

    /// The acking control reader, appending to `control.txt`. `ignoring`, it takes no meeting line: each is set aside
    /// in `ignored.txt` instead, as a child that skips or rejects the line would leave it.
    static func meetingControl(ignoring: Bool) -> String {
        let control = ackingControl(append: true), take = #"printf '%s\n' "$ctl" >> control.txt"#
        guard ignoring else { return control }
        let skip = #"case "$ctl" in *'"meeting"'*) printf '%s\n' "$ctl" >> ignored.txt; continue;; esac"#
        return control.replacingOccurrences(of: take, with: skip + "\n" + take)
    }

    /// Holds the child's first line back (at most 15 s) until the test writes `go`.
    static let untilGo = """
    GO_WAIT=0
    while [ ! -e go ] && [ $GO_WAIT -lt 300 ]; do /bin/sleep 0.05; GO_WAIT=$((GO_WAIT + 1)); done
    """
}

/// The control lines a meeting-capable child is written (#735 MM-D).
enum MeetingLines {
    static let advert = #"{"version": 1}"#
    static func media(_ on: Bool) -> String { "{\"media\":\(on)}\n" }
    static func meeting(_ on: Bool) -> String { "{\"meeting\":\(on)}\n" }
    /// Every line, in order.
    static func lines(_ lines: String...) -> String { lines.joined() }
    /// A new child's gate and meeting line in either order: the gate is written under `register`'s lock, the meeting
    /// line once haild reads its `started`, which may already have been read. Neither order is ever less gated than
    /// the media gate alone (meeting plus media decides as meeting alone).
    static func newChild(_ control: String?, after earlier: String = "") -> Bool {
        let (gate, meeting) = (media(true), meeting(true))
        return control == earlier + gate + meeting || control == earlier + meeting + gate
    }
}
#endif
