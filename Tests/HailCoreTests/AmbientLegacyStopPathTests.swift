import Foundation
import Testing
@testable import HailCore

@Suite struct AmbientLegacyStopPathTests {
    typealias Path = AmbientListeningState.LegacyStopPath
    static let paths: [Path] = [
        .systemCaptureEnded, .socketBindingLost, .privacySendFailed, .privacyUnconfirmed,
        .leftForeground, .captureStartFailed, .sendCancelled, .encodingFailed, .sendFailed,
        .hostRefused, .retriesExhausted, .replacementFailed, .diagnosticsDismissed
    ]

    @Test func onlyRecordedSitesCanRequestALegacyStop() throws {
        #expect(Path.allCases == Self.paths)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var sources: [String: String] = [:]
        for tree in ["Sources", "Apps"] {
            let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(tree),
                                                                   includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let path = String(file.path.dropFirst(root.path.count + 1))
                sources[path] = try String(contentsOf: file, encoding: .utf8)
            }
        }
        let actual = Self.references(in: sources).flatMap { path, sites in sites.map { "\(path) \($0)" } }
        #expect(actual.sorted() == Self.inventory.sorted())
    }

    // Include bare method values inside a type/extension as well as qualified calls in other files.
    // Counting the reference that creates a callback also catches callbacks passed on to other code.
    static func references(in source: String) -> [String] {
        references(in: ["fixture": source])["fixture", default: []]
    }

    static func references(in sources: [String: String]) -> [String: [String]] {
        let files = sources.mapValues(StopReferenceSource.init)
        let assignments = files.values.flatMap(\.assignments)
        var aliases = Set(files.values.flatMap { file in
            file.assignments.compactMap { file.members.contains($0.value) ? $0.name : nil }
        })
        while true {
            let count = aliases.count
            aliases.formUnion(assignments.compactMap { aliases.contains($0.value) ? $0.name : nil })
            if count == aliases.count { break }
        }
        return files.mapValues { $0.references(aliases: aliases) }
    }

    @Test func referencesAndAliasChainsRemainCounted() {
        let source = """
        extension AmbientListeningReconnect {
            func register() {
                let first = block(_:stop:)
                let second = first
                observe(second)
                observe(controller.destinationLost)
                veto(.privacy, host: host, stop: .legacy(.privacyUnconfirmed))
                let build = AmbientListeningState.StopReason.legacy
                observe(build(.socketBindingLost))
            }
        }
        """
        #expect(Self.references(in: source) == [
            "register first", "register block", "register second", "register first", "register second",
            "register destinationLost", "register veto", "register legacy", "register privacyUnconfirmed",
            "register build", "register legacy", "register build", "register socketBindingLost"
        ])
    }

    @Test func invokingAStoredCallbackAddsAnInventorySite() {
        let registration = """
        var onLoss: (() async -> Void)?
        func register() {
            self.onLoss = controller.destinationLost
        }
        """
        let inventory = ["<file> onLoss", "register onLoss", "register destinationLost"]
        #expect(Self.references(in: registration) == inventory)
        let withInvocation = registration + "\nfunc notify() { await self.onLoss?() }"
        #expect(Self.references(in: withInvocation) == inventory + ["notify onLoss"])
        let files = Self.references(in: [
            "Register.swift": registration,
            "Forward.swift": "func forward() {\n self.onStop = self.onLoss\n}",
            "Notify.swift": "func notify() { await self.onLoss?(); await self.onStop?() }"
        ])
        #expect(files["Register.swift"] == inventory)
        #expect(files["Forward.swift"] == ["forward onStop", "forward onLoss"])
        #expect(files["Notify.swift"] == ["notify onLoss", "notify onStop"])

        let inline = Self.references(in: [
            "Register.swift": "func register() { self.onLoss = controller.destinationLost }",
            "Notify.swift": "func notify() { await self.onLoss?() }"
        ])
        #expect(inline["Register.swift"] == ["register onLoss", "register destinationLost"])
        #expect(inline["Notify.swift"] == ["notify onLoss"])
    }

    @Test func parameterDefaultsAndUnrelatedLegacyCasesDoNotCreateAliases() {
        let source = """
        func register(previous: T = .legacy, x: T = .legacy
        ) { switch x { case .legacy: break } }
        func install(
            onLoss: Callback = controller.destinationLost
        ) { use(onLoss) }
        func select() {
            let mode: T = .legacy
            let make = T.legacy
            use(T.legacy(value))
            use(.legacy(.unrelated))
            use(mode, make)
        }
        """
        #expect(StopReferenceSource(source).assignments.isEmpty)
        #expect(Self.references(in: source) == ["install destinationLost"])
    }
}

extension AmbientLegacyStopPathTests {
    // Each row is an enclosing function followed by its references. Repetitions count.
    static var inventory: [String] {
        let files = [
            "Sources/HailCore/Transport/HostConnectionStore.swift": """
            upsert legacy socketBindingLost veto
            disconnect veto
            selectTarget block
            selectionFailed veto legacy socketBindingLost
            remove veto
            forgetSelection attributeSelectionLoss
            transportLost sendFailed
            receiveModeNotice veto legacy privacyUnconfirmed
            setPrivacy veto veto legacy privacySendFailed
            sendAudio sendFailed
            turnOn end
            start end legacy leftForeground end legacy leftForeground end legacy captureStartFailed
            didStartStreaming observeSystemEnd
            openStreamer recordSendFailure
            watch end legacy systemCaptureEnded
            recordSendFailure sendError bindingLossReason
            observeSystemEnd end legacy systemCaptureEnded
            update block bindingLossReason updateDestination updateDestination
            bindingLossReason bindingLoss
            destinationLossReason bindingLossReason
            updateDestination end destinationLossReason end legacy leftForeground
            destinationLost end destinationLossReason
            recover legacy retriesExhausted
            stopForPolicy block cancelTransportRestore
            ownerChangedDestination block bindingLossReason destinationLost
            turnOff stopListening
            cancelForDiagnosticsDismissal stopListening legacy diagnosticsDismissed
            stopListening block end
            receiveAmbientRefusal recordSendFailure end legacy hostRefused
            cancelTransportRestore end
            """,
            "Sources/HailCore/Transport/AmbientListeningState.swift": """
            <file> legacy
            bindingLoss targetLoss legacy socketBindingLost
            targetLoss legacy socketBindingLost
            sendError legacy sendCancelled legacy sendCancelled legacy encodingFailed legacy hostRefused
            sendError legacy socketBindingLost legacy sendFailed
            """,
            "Sources/HailCore/AmbientListeningReconnect.swift": """
            begin privacyUnconfirmed privacySendFailed
            receive privacyUnconfirmed
            completeIfReady privacyUnconfirmed
            sendFailed privacySendFailed
            block cancelTransportRestore
            drop block block legacy privacyUnconfirmed
            receive block block legacy replacementFailed block legacy socketBindingLost block
            receive block legacy socketBindingLost block block targetLoss
            selectionFailed legacy replacementFailed veto
            restore block legacy socketBindingLost block legacy privacyUnconfirmed cancelTransportRestore legacy
            resume cancelTransportRestore legacy systemCaptureEnded
            veto block
            refreshEndpoint block
            prepareCaptureResume block legacy privacyUnconfirmed block legacy
            """,
            "Apps/Hail-iOS/RootView.swift": "reconcileAmbientDestination ownerChangedDestination destinationLost",
            "Apps/Hail-iOS/AudioDiagnosticsView.swift": "disappear cancelForDiagnosticsDismissal",
            "Apps/Hail-iOS/StationCard.swift": "body turnOff",
            "Apps/Hail-iOS/StationMenuPublishers.swift": "attach turnOff",
            // Same Swift spelling in unrelated code.
            "Sources/HailDaemonKit/Listener/HostReplyDelivery.swift": "commit block block",
            "Sources/HailCore/AmbientAudioStreamer.swift": "makeQueue sendFailed"
        ]
        return files.flatMap { file, rows in
            rows.split(separator: "\n").flatMap { row -> [String] in
                let words = row.split(separator: " ")
                guard let function = words.first else { return [] }
                return words.dropFirst().map { "\(file) \(function) \($0)" }
            }
        }
    }
}
