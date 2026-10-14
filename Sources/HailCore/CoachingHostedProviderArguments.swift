/// Owner-local hosted-text consent is independent of participant awareness, a catalog and a request budget.
public enum CoachingHostedProviderArguments {
    public enum Refusal: Error, Sendable { case consentRequired, invalidConfiguration }

    public static func make(catalog: String?, maxRequests: Int?, consent: Bool) throws -> [String] {
        if catalog == nil, maxRequests == nil { return [] }
        guard consent else { throw Refusal.consentRequired }
        guard let catalog, let maxRequests, (1...100).contains(maxRequests), catalog.hasPrefix("/") else {
            throw Refusal.invalidConfiguration
        }
        return ["--coaching-provider", "jev", "--coaching-allow-hosted-text",
                "--coaching-max-requests", String(maxRequests), "--coaching-advice-catalog", catalog]
    }
}
