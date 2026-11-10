"""Dead-mapping cleanup parity for the production partial-error CLI branch."""

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class DeliveryMappingCleanupCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Compile the actual declaration, error formatting and exit branch in isolation: no daemon or pane.
        host = (REPO / "Sources/HailDaemonKit/Daemon/HailHost.swift").read_text()
        adapter = (REPO / "Sources/HailDaemonKit/Adapter/Adapter.swift").read_text()
        main = (REPO / "Sources/haild/main.swift").read_text()
        declaration = next(line.strip() for line in host.splitlines() if "case partial(" in line)
        overload_start = host.index("    public static func partial(")
        overload = host[overload_start:host.index("\n    }", overload_start) + len("\n    }")]
        reason_start = host.index("public enum HostPartialReason:")
        reason = host[reason_start:host.index("\n}", reason_start) + len("\n}")]
        dependencies = []
        for marker in [
            "public enum AdapterError:", "public enum DialogKind:",
            "public struct DialogBlock:", "public enum PendingInputReason:",
        ]:
            start = adapter.index(marker)
            dependencies.append(adapter[start:adapter.index("\n}", start) + len("\n}")])
        # A refactor must not let the splice silently extract nothing for the partial reason or its dependencies.
        if "case text(" not in reason or "case dialog(" not in reason or "func partial(" not in overload:
            raise AssertionError("partial-reason source extraction no longer matches HailHost.swift")
        if any(len(part.strip().splitlines()) < 2 for part in dependencies):
            raise AssertionError("adapter dependency extraction no longer matches Adapter.swift")
        helpers = main[main.index("func note("):main.index("func reportListingFailures(")]
        branch = main[main.index("    case .partial("):main.index("    case .policyUnavailable(")]
        source = "\n".join([
            "import Foundation",
            "let standardError = FileHandle.standardError",
            *dependencies,
            reason,
            "enum HostError: Error {", declaration, overload, "}",
            helpers,
            "let delivered = Array(CommandLine.arguments.dropFirst(2))",
            "let error = HostError.partial(delivered: delivered, reason: CommandLine.arguments[1])",
            "switch error {", branch, "}",
        ])
        scratch = tempfile.TemporaryDirectory(prefix="hail-partial-parity-")
        cls.addClassCleanup(scratch.cleanup)
        source_path = Path(scratch.name) / "main.swift"
        cls.binary = Path(scratch.name) / "partial-parity"
        source_path.write_text(source)
        compiled = subprocess.run(
            ["swiftc", "-j", "4", str(source_path), "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=120, check=False,
        )
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def test_partial_reasons_keep_exit_six_and_exact_line_accounting(self):
        reasons = ["target_policy_changed", "delivery cancelled", "adapter delivery failed"]
        for reason in reasons:
            for delivered in [[], ["one"], ["one", "two"]]:
                with self.subTest(reason=reason, delivered=delivered):
                    result = subprocess.run(
                        [str(self.binary), reason, *delivered],
                        capture_output=True, text=True, timeout=15, check=False,
                    )
                    count = len(delivered)
                    suffix = "" if count == 1 else "s"
                    expected = f"haild: delivered {count} line{suffix}, then: {reason}\n"
                    self.assertEqual(result.returncode, 6)
                    self.assertEqual(result.stderr, expected)
                    self.assertEqual(result.stdout, "")
