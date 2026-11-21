import Foundation
import Testing
@testable import HailCore

@Suite struct AmbientLegacyStopPathTests {
    typealias Path = AmbientListeningState.LegacyStopPath
    static let paths: [Path] = [
        .systemCaptureEnded, .socketBindingLost, .privacySendFailed, .privacyUnconfirmed,
        .leftForeground, .captureStartFailed, .sendCancelled, .encodingFailed, .sendFailed,
        .hostRefused, .retriesExhausted, .replacementFailed
    ]

    @Test func onlyRecordedSitesCanRequestALegacyStop() throws {
        #expect(Path.allCases == Self.paths)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var actual: [String] = []
        for tree in ["Sources", "Apps"] {
            let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(tree),
                                                                   includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                let path = file.path.dropFirst(root.path.count + 1)
                actual += Self.references(in: source).map { "\(path) \($0)" }
            }
        }
        #expect(actual.sorted() == Self.inventory.sorted())
    }

    // Include bare method values inside a type/extension as well as qualified calls in other files.
    // Counting the reference that creates a callback also catches callbacks passed on to other code.
    static func references(in source: String) -> [String] {
        let commentsOrStrings = #/"(?:\\.|[^"\\\n])*"|\/\/[^\n]*|\/\*(?s:.*?)\*\//#
        let code = source.replacing(commentsOrStrings) { $0.output.hasPrefix("/") ? " " : String($0.output) }
        var bare: Set<String> = ["turnOff", "destinationLost", "ownerChangedDestination", "cancelTransportRestore",
                                 "bindingLossReason", "targetLoss", "attributeSelectionLoss", "recordSendFailure"]
        if code.contains(#/(?:class|extension)\s+AmbientListeningReconnect\b/#) { bare.formUnion(["block", "veto"]) }
        if code.contains(#/(?:class|extension)\s+AmbientListeningController\b/#) {
            bare.formUnion(["end", "observeSystemEnd", "updateDestination"])
        }
        if code.contains(#/(?:enum|extension)\s+(?:AmbientListeningState\.)?StopReason\b/#) {
            bare.formUnion(["legacy", "sendError", "bindingLoss"])
        }
        let members = bare.union(["block", "veto", "legacy", "sendError", "bindingLoss"])
            .union(paths.map { String(describing: $0) })
        guard members.contains(where: { code.contains($0) }) else { return [] }
        let aliases = callbackAliases(in: code, members: members)
        let tokens = #/\bfunc\s+(\w+)|\bvar\s+(bindingLossReason|body)\b|(\.\s*)?\b(\w+)\b/#
        var scope = "<file>"
        var sites: [String] = []
        for token in code.matches(of: tokens) {
            if let declaration = token.1 ?? token.2 {
                scope = String(declaration)
            } else if let word = token.4 {
                let name = String(word)
                if aliases.contains(name) || bare.contains(name) || (token.3 != nil && members.contains(name)) {
                    sites.append("\(scope) \(name)")
                }
            }
        }
        return sites
    }

    private static func callbackAliases(in code: String, members: Set<String>) -> Set<String> {
        let assignments = #/
            (?m) \b(?:let|var)\s+(\w+)(?:[ \t]*:[^=\n]+)?\s*=\s*
            (?:\w+\??\s*\.\s*)*\.?(\w+)(?:\((?:\w+:)+\))?[ \t]*$
            /#
        let pairs = code.matches(of: assignments).map { (String($0.1), String($0.2)) }
        var aliases: Set<String> = []
        while true {
            let next = Set(pairs.compactMap { members.contains($0.1) || aliases.contains($0.1) ? $0.0 : nil })
            if next == aliases { return aliases }
            aliases = next
        }
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
            start observeSystemEnd
            openStreamer recordSendFailure
            watch end legacy systemCaptureEnded
            recordSendFailure sendError bindingLossReason
            observeSystemEnd end legacy systemCaptureEnded
            update block bindingLossReason updateDestination updateDestination
            bindingLossReason bindingLoss
            updateDestination end bindingLossReason end legacy leftForeground
            destinationLost end bindingLossReason
            recover legacy retriesExhausted
            stopForPolicy block cancelTransportRestore
            ownerChangedDestination block bindingLossReason destinationLost
            turnOff block end
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
            "Apps/Hail-iOS/AudioDiagnosticsView.swift": "disappear turnOff",
            "Apps/Hail-iOS/StationCard.swift": "body turnOff",
            "Apps/Hail-iOS/StationMenuPublishers.swift": "attach turnOff",
            // Same Swift spelling in unrelated code.
            "Sources/HailDaemonKit/Provider/ProviderInputCoordinator.swift": "<file> legacy\ndispatch legacy",
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
