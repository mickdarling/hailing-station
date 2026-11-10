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

    static var causes: [DialogBlock.Cause] { DialogKind.allCases.map { .known($0) } + [.uninspectable] }

    static func firstSentence(_ cause: DialogBlock.Cause) -> String {
        switch cause {
        case .known(.computerUsePermissions): "A Computer Use permissions dialog is open on Deck. "
        case .known(.computerUseAppApproval): "A Computer Use app approval dialog is open on Deck. "
        case .known(.toolPermission): "A tool permission dialog is open on Deck. "
        case .known(.modalFooter): "A dialog is open on Deck. "
        case .uninspectable: "Couldn't check Deck for a dialog. "
        }
    }

    @Test(arguments: rows, causes)
    // swiftlint:disable:next large_tuple
    func exactWordingAndClipEligibility(row: (DialogBlock.Effects, Int, String), cause: DialogBlock.Cause) {
        let (effects, earlier, remainder) = row
        let notice = DialogDeliveryNotice(block: .init(cause: cause, effects: effects), earlierDelivered: earlier)
        let expected = Self.firstSentence(cause) + remainder
        #expect(Array(notice.message(target: "Deck").utf8) == Array(expected.utf8))
        #expect(notice.untouched == (effects == .none && earlier == 0))
    }
}
