# Explicit coaching provider launch — inert prerequisite (#268 / #225)

This unit carries an explicit provider choice through RightyoCoachingLaunch on the existing owned
RightyO child. Mock is the default. Jev requires separate hosted-text consent, a finite 1..100 request
budget and an absolute readable regular authored catalog of 1..8192 bytes. Mock suggestions cannot be
combined with that choice. Argument construction forwards only the coaching provider, hosted-text
consent, request budget and catalog flags, without ordinary hosted-ASR consent or credentials.

RightyoCoachingProviderTests performs pure arguments validation with authored catalog files. It does
not launch Jev, record a provider child's actual argv, establish owner activity/renewal, invoke a model
or use audio hardware. RightyoCoachingControlTests separately uses an authored mock child to exercise
channel ownership. These executed prerequisite checks do not establish a producer-to-playback round trip.

The later command unit #565 contains the actual owned-child argv/configuration and activity/renewal
regressions; its verification receipts are separate evidence. Three longer executable integration
cases require an explicitly pinned authored producer and otherwise report skipped. No skipped case
establishes advice quality, a running hosted provider, full duplex or physical privacy.

Catalog semantics remain the provider's responsibility before inference. The trusted local catalog
path is not an atomic snapshot against hostile same-account replacement. This source prerequisite
introduces no new transcript runtime, network client, implicit activation, installation or deployment.
