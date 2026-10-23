#if os(macOS)
import Foundation
@testable import HailDaemonKit

/// The fake RightyO's side of the privacy-on ack (#735 S-8), shared by every privacy fake: it advertises `duck` v3 and
/// acks each `{"duck":true}` it reads on fd 3 with a `privacy` `on` event. Synthetic only.
///
/// The ack is deterministic: a background reader records every control line to `control.txt` as it arrives (as the old
/// `cat <&3 > control.txt &` did), and acks an on-line only once the fake's own lines are out (`acksMayFollow`), each
/// with the next sequence from 1000. The fake's last line (`stopped`) then follows every ack, with sequence 9999.
extension FakeRightyo {
    /// The `started` edit advertising `duck` v3, with the start-private suffix (`$PRIV`) when launched so.
    static let duckV3 = #" -e 's/"phase": "started"/"duck": {"version": 3'"$PRIV"'}, "phase": "started"/'"#

    /// The background control reader that acks (instead of `cat <&3 > control.txt &`). `append` keeps what an earlier
    /// child in the same directory recorded, as `>>` did. `ACK_AT_MS` sets the ack's `at_ms` (default 0); its
    /// `emitted_at_ms` is the fixture's last, so it never runs backwards against the lines around it.
    static func ackingControl(append: Bool = false) -> String {
        #"""
        \#(append ? ": >> control.txt" : ": > control.txt")
        ACK_SID=$7
        ACK_EMITTED=$(/usr/bin/sed -n -e '$s/.*"emitted_at_ms": \([0-9]*\).*/\1/p' events.jsonl 2>/dev/null)
        ACK_FORMAT='{"type": "privacy", "action": "on", "at_ms": %s, "schema_version": 1, '
        ACK_FORMAT="$ACK_FORMAT"'"session_id": "%s", "sequence": %s, "emitted_at_ms": %s}\n'
        ( n=1000
          while IFS= read -r ctl <&3; do
            printf '%s\n' "$ctl" >> control.txt
            [ "$ctl" = '{"duck":true}' ] || continue
            while [ ! -e "ack.$$" ]; do /bin/sleep 0.02; done
            printf "$ACK_FORMAT" "${ACK_AT_MS:-0}" "$ACK_SID" "$n" "${ACK_EMITTED:-2000}"
            /usr/bin/touch "acked.$n"
            n=$((n + 1))
          done 2>/dev/null ) &
        """#
    }

    /// The fake's own lines are out: acks may follow from here on.
    static let acksMayFollow = "/usr/bin/touch \"ack.$$\""

    /// Acks may follow, then waits (at most 5 s) until the first one is out, so the lines after it follow the ack
    /// (#735 S-8 HS-C). Those lines then need sequences above 1000.
    static let untilFirstAck = """
    \(acksMayFollow)
    ACK_WAIT=0
    while [ ! -e acked.1000 ] && [ $ACK_WAIT -lt 100 ]; do /bin/sleep 0.05; ACK_WAIT=$((ACK_WAIT + 1)); done
    """

    /// The tail after the fake's own lines: acks may follow, stdin is drained to EOF (which closes fd 3 too), the reader
    /// is awaited, and the fixture's `stopped` line follows every ack.
    static let ackingTail = """
    \(acksMayFollow)
    /bin/cat > /dev/null
    wait
    /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" -e "s/tool-demo/$7/g"\(lastSequence)
    """

    /// Puts a line after every ack.
    static let lastSequence = #" -e 's/"sequence": [0-9]*/"sequence": 9999/'"#
}
#endif
