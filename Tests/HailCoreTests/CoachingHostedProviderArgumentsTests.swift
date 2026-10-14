import Testing
@testable import HailCore

@Suite struct CoachingHostedProviderArgumentsTests {
    @Test(arguments: [false, true]) func catalogAndBudgetCannotManufactureConsent(_ consent: Bool) throws {
        if consent {
            let arguments = try CoachingHostedProviderArguments.make(catalog: "/authored/catalog.json",
                                                                     maxRequests: 20, consent: consent)
            #expect(arguments == ["--coaching-provider", "jev", "--coaching-allow-hosted-text",
                                  "--coaching-max-requests", "20",
                                  "--coaching-advice-catalog", "/authored/catalog.json"])
            #expect(!arguments.contains("--allow-hosted-audio"))
        } else {
            #expect(throws: CoachingHostedProviderArguments.Refusal.consentRequired) {
                try CoachingHostedProviderArguments.make(catalog: "/authored/catalog.json",
                                                         maxRequests: 20, consent: consent)
            }
        }
    }

    @Test func missingProviderSetupStaysInert() throws {
        #expect(try CoachingHostedProviderArguments.make(catalog: nil, maxRequests: nil, consent: false).isEmpty)
    }

    @Test(arguments: [0, 101]) func invalidBudgetsAndPartialSetupRefuseInsteadOfDowngrading(_ budget: Int) {
        #expect(throws: CoachingHostedProviderArguments.Refusal.invalidConfiguration) {
            try CoachingHostedProviderArguments.make(catalog: "/authored/catalog.json",
                                                     maxRequests: budget, consent: true)
        }
        #expect(throws: CoachingHostedProviderArguments.Refusal.invalidConfiguration) {
            try CoachingHostedProviderArguments.make(catalog: nil, maxRequests: 20, consent: true)
        }
        #expect(throws: CoachingHostedProviderArguments.Refusal.invalidConfiguration) {
            try CoachingHostedProviderArguments.make(catalog: "relative/catalog", maxRequests: 20, consent: true)
        }
    }
}
