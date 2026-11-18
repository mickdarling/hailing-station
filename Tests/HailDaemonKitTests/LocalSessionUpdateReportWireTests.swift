import Foundation
import Testing
@testable import HailDaemonKit

/// #1258: preserve the existing local report wire format; admission refusals carry no status.
@Suite struct LocalSessionUpdateReportWireTests {
    @Test(arguments: ["runaway_guard", "control_rate_limited"])
    func admissionRefusalWireRetainsRequiredCompatibilityFields(reason: String) throws {
        var report = LocalSessionUpdateReport(outcome: .refused, reason: reason)
        report.retryAfter = 30
        let encoded = try JSONEncoder().encode(report)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["held"] as? Int == 0)
        #expect(fields["quiet"] as? Bool == false)
        #expect(fields["speechUnavailable"] as? String == "attention_signal_missing")
        #expect(try JSONDecoder().decode(LocalSessionUpdateReport.self, from: encoded) == report)
        // Existing synthesized decoders require both keys even for refusals; omission would break old CLIs.
        for key in ["held", "quiet"] {
            var omitted = fields
            omitted.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: omitted)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LocalSessionUpdateReport.self, from: data)
            }
        }
    }
}
