import Testing

extension AmbientLegacyStopPathTests {
    @Test func everyLegacySpellingChangesTheFileCounts() throws {
        let original = "let factory = StopReason.legacy"
        let before = try StopReferenceSource(original, definesStopPaths: true)
        #expect(before.legacyCounts == [".legacy": 1])
        #expect(before.controllerCounts == ["legacy": 1])
        for addition in [
            "var reason: StopReason; reason = .legacy(path)",
            "func make() -> Self { .legacy(resolve(path)) }",
            "use(Unrelated.\n  `legacy` /* comment */ (value))"
        ] {
            let after = try StopReferenceSource(original + "\n" + addition, definesStopPaths: true)
            #expect(after.legacyCounts == [".legacy": 2, ".legacy(": 1])
            #expect(after.controllerCounts == ["legacy": 2])
        }
    }

    @Test func unrelatedFilesOnlyPinLegacySpellings() throws {
        let source = """
        // AmbientListeningController
        let end = "ambientController"
        let block = other.veto
        let sendFailed = legacy
        use(LegacyStopPath.self, Other.legacy, .legacy(value))
        """
        let inventory = try StopReferenceSource(source)
        #expect(!inventory.includesEntryPoints)
        #expect(inventory.legacyCounts == [".legacy": 2, ".legacy(": 1, "LegacyStopPath": 1])
        #expect(inventory.controllerCounts.isEmpty)
        #expect(inventory.unappliedLines.isEmpty)
    }

    @Test func controllerReferencesPinFilesEvenWithoutStopNames() throws {
        for source in ["let value: AmbientListeningController?", "use(store.`ambientController`)"] {
            let inventory = try StopReferenceSource(source)
            #expect(inventory.includesEntryPoints)
            #expect(inventory.controllerCounts.isEmpty)
        }
    }

    @Test func entryPointsMustBeAppliedWhereTheyAreFirstReferenced() throws {
        let source = """
        func destinationLost() { controller.destinationLost() }
        reconnect.block { recover() }
        let callback = controller.destinationLost
        register(`retire`)
        callbacks.append(reconnect.block(_:stop:))
        """
        let inventory = try StopReferenceSource(source)
        #expect(inventory.includesEntryPoints)
        #expect(inventory.unappliedLines == [
            "let callback = controller . destinationLost": 1,
            "register ( retire )": 1,
            "callbacks . append ( reconnect . block ( _ : stop : ) )": 1
        ])
    }

    @Test func commentsAndStringTextAreIgnored() throws {
        let source = ##"""
        // controller.destinationLost and .legacy(path)
        /* outer /* inner */ .legacy(path) */
        let plain = "text \".legacy(path)\" // end"
        let raw = #".legacy(path) "block" /* retire */"#
        let multi = """
            .legacy(path)
            """
        let message = "literal .legacy(path), evaluated \(describe(.legacy(value)))"
        """##
        let inventory = try StopReferenceSource(source, definesStopPaths: true)
        #expect(inventory.legacyCounts == [".legacy": 1, ".legacy(": 1])
        #expect(inventory.controllerCounts == ["legacy": 1])
        #expect(inventory.unappliedLines.isEmpty)
    }
}
