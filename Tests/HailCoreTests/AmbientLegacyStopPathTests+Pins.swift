extension AmbientLegacyStopPathTests {
    static let storeFile = "Sources/HailCore/Transport/HostConnectionStore.swift"
    static let reconnectFile = "Sources/HailCore/AmbientListeningReconnect.swift"
    static let stateFile = "Sources/HailCore/Transport/AmbientListeningState.swift"
    static let stopDefinitions: Set<String> = [storeFile, reconnectFile, stateFile]

    // An omitted file or spelling has zero tree-wide occurrences.
    static let legacyCounts = [
        storeFile: [".legacy": 13, ".legacy(": 13],
        reconnectFile: [".legacy": 11, ".legacy(": 11, "LegacyStopPath": 3],
        stateFile: [".legacy": 8, ".legacy(": 8, "legacy(": 1, "LegacyStopPath": 2],
        "Sources/HailDaemonKit/Provider/ProviderInputCoordinator.swift": [".legacy": 2]
    ]

    // The keys pin the entire controller file set, including files with no stop names.
    // The Station dock’s Interrupt calls the talk owner’s existing startInterrupt, never an ambient stop.
    static let controllerCounts: [String: [String: Int]] = [
        "Apps/Hail-iOS/AudioDiagnosticsView.swift": ["cancelForDiagnosticsDismissal": 1],
        // Listening settings page: reads the ambient controller only, no stop (#1115).
        "Apps/Hail-iOS/ListeningSettingsView.swift": [:],
        "Apps/Hail-iOS/RootView+DestinationSelection.swift": ["forgetSelection": 4],
        // Listening settings page: reads the ambient controller only, no stop (#1115).
        "Apps/Hail-iOS/RootView+ListeningSettings.swift": [:],
        // The Settings Privacy page's explicit owner stop (#1115).
        "Apps/Hail-iOS/RootView+Settings.swift": ["stopListening": 1, "turnOff": 1],
        "Apps/Hail-iOS/RootView.swift": ["destinationLost": 1, "forgetSelection": 1, "ownerChangedDestination": 1],
        "Apps/Hail-iOS/StationCard.swift": ["end": 1, "turnOff": 1],
        // Station rail reads the existing controller and reconnect notice. No ambient stop.
        "Apps/Hail-iOS/StationScreenListening.swift": [:],
        "Apps/Hail-iOS/StationMenuPublishers.swift": ["turnOff": 1],
        reconnectFile: [
            "block": 16, "cancelTransportRestore": 3,
            "legacy": 11, "privacySendFailed": 2, "privacyUnconfirmed": 6, "replacementFailed": 2, "sendFailed": 2,
            "socketBindingLost": 3, "systemCaptureEnded": 1, "targetLoss": 1, "veto": 2
        ],
        "Sources/HailCore/AmbientRestorePresentation.swift": [:],
        "Sources/HailCore/RailHost+Station.swift": [:],
        stateFile: [
            "bindingLoss": 1, "captureStartFailed": 1,
            "diagnosticsDismissed": 1, "encodingFailed": 2, "hostRefused": 2, "leftForeground": 1, "legacy": 9,
            "privacySendFailed": 1, "privacyUnconfirmed": 1, "replacementFailed": 1, "retriesExhausted": 1,
            "sendCancelled": 3, "sendError": 1, "sendFailed": 2, "socketBindingLost": 4, "systemCaptureEnded": 1,
            "targetLoss": 2
        ],
        "Sources/HailCore/Transport/HostConnectionStore+ProactivePlayback.swift": [:],
        storeFile: [
            "attributeSelectionLoss": 2, "bindingLoss": 1, "bindingLossReason": 5,
            "block": 5, "cancelForDiagnosticsDismissal": 1, "cancelTransportRestore": 2, "captureStartFailed": 1,
            "destinationLossReason": 3, "destinationLost": 2, "diagnosticsDismissed": 1, "end": 13,
            "forgetSelection": 5, "hostRefused": 1, "leftForeground": 3, "legacy": 13, "observeSystemEnd": 2,
            "ownerChangedDestination": 1, "privacySendFailed": 1, "privacyUnconfirmed": 1,
            "receiveAmbientRefusal": 2, "recordSendFailure": 3, "retire": 3, "retirePendingOwnerStart": 2,
            "retriesExhausted": 1, "sendError": 1, "sendFailed": 2, "socketBindingLost": 2, "stopForPolicy": 3,
            "stopListening": 3, "systemCaptureEnded": 2, "turnOff": 1, "updateDestination": 3, "veto": 7
        ]
    ]
}
