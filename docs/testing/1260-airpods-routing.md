# AirPods session routing

Part of #1260. This slice owns iPhone and iPad session configuration, route repair, and the distinction between a speaker pick and the app’s own writes.

## Host verification

At commit `271c75e2e99e26c3e460178ffb1fd90fa4f4d430`, the maintainer reported that `swift build --build-tests -j 2` succeeded. The filtered route tests passed once with `--no-parallel` and three times with `--parallel`. Each run executed **152 tests in 26 suites**.

At commit `867a127ee848c50cc19c66e60fbe8284cff4072c`, the maintainer reported another successful `swift build --build-tests -j 2`. All **156 tests in 27 suites** passed once with `--no-parallel` and three times with `--parallel`.

Strict SwiftLint reported zero violations across 22 Swift files in round e, including the restored keepalive file. The host build and filtered route suites are pending for the round-e head. Physical iPhone and iPad validation remains deferred.

## Synthetic coverage

The cases in `AudioOutputRouteOwnershipTests` use the production decision and effect runner with explicit port snapshots, injected failures, and ordered notifications. They require no audio device or elapsed-time waits.

| Test | Expected observation |
|---|---|
| `coldConfigureEmptyThenA2DPWithoutArrival` | Neutral configuration followed by active A2DP and built-in input, with no hardware arrival or output write. |
| `neutralActivationWithReceiverFallsBackToSpeaker` | One speaker-default write across settlement, its echo, and repeated settlement. |
| `disconnectWithOtherExternalOutputKeepsIt` | Losing Bluetooth leaves the selected car output alone. |
| `newHeadsetClearsChoiceBeforeOutputMoves` | A new headset clears the speaker choice while the output still reads speaker. An inactive session defers repair until activation. |
| `usbArrivalWithExistingHFPPreservesChoice` | A USB mic arriving alongside an already available headset preserves Speaker. |
| `delayedRepairEchoNeverLatches` | A delayed built-in override following a clear has release attribution and creates no owner choice. |
| `pickerBeforeEchoSurvivesFailedClear` | A distinguishable picker transition survives a failed clear, the successful category write’s delayed echo, and a USB cycle. |
| `mixablePlaybackRelinquishesStationOwnership` | Mixable playback releases the cached standalone or capture ownership and issues zero routing writes. |
| `ambiguousEchoRecordsNoDurableLatch` | Indistinguishable built-in overrides hold further writes within the episode. A later hardware episode can repair. |
| `correctPairMakesNoWrites` | HFP input/output and built-in input/A2DP output each produce zero repair writes with the speaker-default option either set or clear. A later necessary category write removes an inert default. |
| `preferredInputEchoNeverBecomesPickerChoice` | The confirming override consumes input-write attribution. A duplicate preserves the temporary hold without creating a choice. |
| `staleReceiverNotificationCannotChangeAnAlreadyExternalRoute` | A queued receiver snapshot cannot install a speaker default after output moves. |
| `activationRemembersHeadphonesSeenBeforeCategoryWrite` | An observed pre-configure A2DP output permits one repair when activation settles on speaker without a hardware notification. |

### First review regressions

Strict SwiftLint passed on the 10 Swift files changed in round b. The table describes the ordered assertions.

| Finding | Test | Event order and expected result |
|---|---|---|
| P1-1 | `delayedReleaseFromSpeakerToReceiverIsAmbiguous` | A clear returns on speaker. A later override reports receiver with the same USB mic. Duplicate delivery and settlement leave the selection audible, with release attribution, no durable choice, and one total write. |
| P1-2 | `failedReconfigureCannotClaimNextPickerTap` | Complete an HFP-to-built-in input write, disconnect, reconnect, and fail a configure. A picker transition matching the old input write now latches Speaker and survives a USB cycle. |
| P1-3 | `idleHFPToggleKeepsStandaloneRoutingActive` | Toggle HFP during active standalone playback. A headset arrival clears the override, and removal to receiver triggers fallback without capture starting. |
| P1-4 | `togglingNeitherRepairsNorSpendsTheNextEpisodesRepair`, `usbArrivalWithExistingHFPPreservesChoice` | A category notification exposes HFP on speaker. The choice survives until the headset hardware notice. A USB-only arrival with an existing headset preserves the choice even when USB has yet to become the selected mic. |
| P1-5 | `unpluggingHeadphonesRestoresAnAudibleReceiverFallback`, `duplicateRemovalKeepsSpeakerFallbackEchoAttribution` | Removal reports receiver immediately or speaker followed by receiver. One repair requests speaker in each case, including with a prior speaker pick. A duplicate removal preserves fallback echo attribution. |
| P2-1 | `standaloneSelectsSavedHFPMicrophoneBeforeSettlement` | With HFP enabled, activate on built-in mic and A2DP. A scripted successful input write changes the observed pair to HFP/HFP before settlement. Repeating configuration issues no second input write. |
| P2-2 | `partialCategoryRepairChecksLiveOutputAndOwner` | The category write moves only the mic. The same owner still on speaker clears the override. An output already on A2DP or a transfer of session ownership skips that clear. |
| P2-3 | `correctPairMakesNoWrites`, `userChoiceSurvivesHardwareUntilExternalOutputReturns` | Both correct pairs tolerate either speaker-default value. An existing default survives an external arrival and is removed during the next necessary USB recovery. |

### Second review regressions

Strict SwiftLint reported zero violations across all eight Swift files changed in round c.

Round c uses the hardware reason and the notification’s previous input/output types to identify an episode. The current pair is read again before each write. USB and headset additions use one inventory updated by hardware notifications.

| Finding | Test | Ordered assertions |
|---|---|---|
| P1-1 | `duplicateRemovalKeepsSpeakerFallbackEchoAttribution`, `duplicateArrivalWithChangedCurrentOutputPreservesPicker` | Redeliver the same removal after receiver has moved to speaker, then deliver the restore echo. Expect one restore and no durable choice. A repeated arrival reporting a different current output also preserves an intervening picker choice. |
| P1-2 | `confirmedClearThenPickerReversalSurvivesUSB` | Clear speaker to A2DP, deliver its confirmation, then pick speaker from A2DP. The choice survives a USB cycle with no second clear. Exercise both initial speaker-default values. |
| P1-3 | `captureTakeoverUsesSavedMicWhenHFPWouldBeRefused` | Toggle HFP via the idle configuration entry point during standalone playback. Script an HFP refusal, then activate capture with a saved built-in mic. Expect successful activation and only the built-in request during takeover. |
| P1-4 | `skippedReceiverFallbackRemainsEligible` | A queued receiver removal finds live speaker and issues zero writes. A live receiver notice then triggers one successful fallback across repeat delivery. |
| P1-5 | `usbArrivalWithExistingHFPPreservesChoice` | Pick speaker with HFP available. A category notice exposes USB before the USB hardware notice. Preserve Speaker with the built-in or USB mic selected, including without an earlier hardware inventory. |
| P2-1 | `standaloneArrivalResolvesActualPair` | Deliver a headset arrival with standalone playback active. Check built-in/A2DP and HFP/HFP as starting pairs with the preference both off and on. Expect one input request for a mismatch and zero writes for a correct pair or its duplicate. |
| P2-2 | `skippedCategoryCannotClearLivePickerReceiver`, `partialCategoryRepairChecksLiveOutputAndOwner` | A queued speaker repair finds live receiver before its first write. Leave it alone through the picker notification. If the category write succeeds and changes only the input, continue to the clear. |
| P2-3 | `connectedAirPodsStillRepairOnceAfterKeepaliveUSBBlip` | Resume nonmixable capture following mixable keepalive and USB loss. Returning USB produces one category write and one clear. |
| Active-pair qualification | `inactiveA2DPWithOldSpeakerDefaultRequiresNeutralCategory`, `correctPairMakesNoWrites` | Clear the old default before activation even when the inactive snapshot reports A2DP. An active, correct pair tolerates either bit value. |

At the round-c head, idle settings and capture preparation share a category-only backend call. It preserves active standalone ownership. Standalone playback resolves the microphone on first configuration and on hardware changes. Capture activation transfers ownership before the capture resolver applies its saved microphone preference.

### Third review regressions

The host results for these regressions are recorded above at `867a127e`.

| Finding | Test | Ordered assertions |
|---|---|---|
| P1-1 | `delayedReleaseFromSpeakerToReceiverIsAmbiguous` | Drain the clear’s speaker-to-speaker override before delivering its speaker-to-receiver override. Both belong to the clear. Settlement leaves one write and no durable picker choice. |
| P1-2 | `wiredThenAirPodsWithSamePreviousRouteReleasesSpeaker` | Connect wired headphones and pick Speaker. Duplicate delivery preserves the choice. Adding HFP to the inventory with the same previous pair releases it once. |
| P1-3 | `duplicateUSBRemovalAfterMicReturnsPreservesAirPods` | Deliver a USB-mic removal while the mic is absent and repeat it after USB is selected again. The later USB availability notice still recovers A2DP. |
| P2-1 | `idleToggleSelectsAlreadyConnectedAirPodsWithOnlyCategoryNotice` | The scripted idle settings entry selects the HFP mic on built-in/A2DP after a category-only notice. Round e connects the native forwarding path to the same idle configuration entry. |
| P2-2 | `standaloneArrivalResolvesActualPair` | Hold the observed mic and output at their pre-write values across a duplicate hardware notice. Deliver the reflected pair afterward. Expect one mic request for a mismatch and zero for a correct pair. |
| P2-3 | `failedReceiverSettlementRetriesOnlyOnReconciliation` | Refuse the initial speaker-default write. Its category notification leaves the receiver eligible. Explicit reconciliation succeeds once and repeated settlement produces no further writes. |

### Fourth review regressions

| Finding | Test | Ordered assertions |
|---|---|---|
| P1-1 | `delayedReleaseFromSpeakerToReceiverIsAmbiguous` | Clear while on speaker, receive its speaker echo, refuse a preferred-input write, then deliver the receiver echo. Expect release attribution, an ambiguous decision, one clear and no durable speaker choice. |
| P1-2 | `duplicateAirPodsArrivalAfterEnablingHFPPreservesSpeaker` | Connect on A2DP with HFP off, pick Speaker, enable HFP, and redeliver the same arrival. Whether the HFP input became visible at the write or at redelivery, expect the same hardware generation, Speaker retained, and zero repairs. |
| P2 | `idleHFPSettingSupersedesUnreflectedStandaloneBuiltInRequest` | Start on HFP/HFP with HFP off and leave the built-in mic request outstanding. Turn HFP on through the idle setting. Deliver the old confirmation twice, before or after the HFP confirmation. Expect HFP/HFP, one new HFP request, and one reassertion only if the already-confirmed HFP setting was displaced. |

PR1 retains main’s native keepalive start and release behavior. The existing playback and USB recovery cases remain in this suite. Explicit attribution of keepalive writes, removal of the saved speaker default at handoff, and `keepaliveHandoffReconcilesOnce` move together to the follow-up patch.

Also run the existing output-route, Bluetooth HFP, input-selection, lifecycle, and keepalive suites. Include the failure and interleaving cases for USB input loss, duplicate arrivals, picker-before-echo, and partial category/override failure.

## Physical checks deferred

On both iPhone and iPad, use a numbered synthetic reply. For each trial record the actual input and output **port types**, the relevant options, and the audible result. Omit device names and identifiers.

- Start with AirPods already connected. Check first foreground and first background replies, with capture active and with standalone playback. Listen from the first word without opening Control Center.
- Connect while idle, listening, and halfway through the reply. With automatic input and no USB or wired mic, check built-in mic plus A2DP with HFP off, then headset mic plus HFP with it on. Repeat a first standalone reply with the saved preference on.
- With Speaker explicitly selected, toggle HFP, change only the USB mic, and then connect a new external output. Confirm the selected speaker survives the first two changes and yields to the new output. Exercise a picker tap interleaved with an app repair.
- Disconnect to built-in output and check speaker audibility, including an immediate receiver, an empty route, and speaker followed by receiver. Repeat with an explicit speaker selection. Repeat with one AirPod and a wired car connection, noting which output iOS actually selected.
- Exercise keepalive start, release, and capture takeover. Check that background playback stays mixable and capture owns preferred-input selection.

AVAudioSession supplies previous ports and a route-change reason without a picker transaction ID. Identical picker and app-echo evidence is recorded as ambiguous. A headset absent from the current output and available inputs cannot be identified from those snapshots alone. Hardware checks must establish the actual ordering.

Mid-reply continuation across an engine reset, the player’s later activation after a keepalive release, and transmission through the existing route diagnostics belong to PR2. This slice exposes an in-process observation with the trigger, decision, user-choice flag, attributed operation, attempted effect, status, and observed route. Listening lifecycle decisions remain with the existing capture owner.
