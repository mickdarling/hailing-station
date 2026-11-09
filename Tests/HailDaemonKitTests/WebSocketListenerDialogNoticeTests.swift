import Testing
@testable import HailDaemonKit

/// Exact device wording from synthetic typed evidence; no captured pane contents.
@Suite struct WebSocketListenerDialogNoticeTests {
    // swiftlint:disable:next large_tuple
    static let rows: [(DialogBlock.Effects, Int, String)] = [
        (.none, 0, "Nothing was sent."),
        (.pasteMayHaveExecuted, 0, "Your words may be in the input box, but nothing was submitted."),
        (.enterMayHaveExecuted, 0, "Your words may have gone through; check the Mac before resending."),
        (.none, 1, "1 earlier line went through; the rest were not sent."),
        (.none, 2, "2 earlier lines went through; the rest were not sent."),
        (.pasteMayHaveExecuted, 1,
         "1 earlier line went through. The next line may be in the input box; the rest were not submitted."),
        (.pasteMayHaveExecuted, 2,
         "2 earlier lines went through. The next line may be in the input box; the rest were not submitted."),
        (.enterMayHaveExecuted, 1,
         "1 earlier line went through, and the next line may have too; check the Mac before resending."),
        (.enterMayHaveExecuted, 2,
         "2 earlier lines went through, and the next line may have too; check the Mac before resending.")
    ]

    @Test(arguments: rows, [false, true])
    // swiftlint:disable:next large_tuple
    func exactWordingAndClipEligibility(row: (DialogBlock.Effects, Int, String), unknown: Bool) {
        let (effects, earlier, remainder) = row
        let title = "Computer Use needs macOS permissions"
        let cause: DialogBlock.Cause = unknown ? .uninspectable : .known(title: title)
        let notice = DialogDeliveryNotice(block: .init(cause: cause, effects: effects), earlierDelivered: earlier)
        let first = unknown ? "Couldn't check Deck for a dialog. "
            : "A Computer Use needs macOS permissions dialog is open on Deck. "
        let expected = first + remainder
        #expect(Array(notice.message(target: "Deck").utf8) == Array(expected.utf8))
        #expect(notice.untouched == (effects == .none && earlier == 0))
    }
}
