import importlib.util
import io
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parent / "eval_local_intents.py"
SPEC = importlib.util.spec_from_file_location("eval_local_intents", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LocalIntentEvalTests(unittest.TestCase):
    def test_loopback_request_disables_environment_proxy_and_redirects(self):
        with patch.object(MODULE.urllib.request, "build_opener") as build_opener:
            build_opener.return_value.open.return_value = io.BytesIO(b'{"ok":true}')
            result = MODULE.request_json("http://127.0.0.1:11434/api/tags")
        self.assertEqual(result, {"ok": True})
        proxy, redirect = build_opener.call_args.args
        self.assertIsInstance(proxy, MODULE.urllib.request.ProxyHandler)
        self.assertEqual(proxy.proxies, {})
        self.assertIs(redirect, MODULE.NoRedirect)

    def test_ollama_request_is_bounded_and_loopback(self):
        with patch.object(MODULE, "request_json") as request:
            request.return_value = {"message": {"content": '{"intent":"host_status"}'}}
            intent, elapsed = MODULE.classify(
                "ollama", 11434, "installed-model", "Host status?"
            )
        self.assertEqual(intent, "host_status")
        self.assertGreaterEqual(elapsed, 0)
        url, payload = request.call_args.args
        self.assertEqual(url, "http://127.0.0.1:11434/api/chat")
        self.assertEqual(
            payload["format"]["properties"]["intent"]["enum"], list(MODULE.INTENTS)
        )
        self.assertEqual(payload["messages"][-1]["content"], "Host status?")

    def test_lm_studio_request_is_schema_bounded_and_loopback(self):
        with patch.object(MODULE, "request_json") as request:
            request.return_value = {
                "choices": [{"message": {"content": '{"intent":"clarify"}'}}]
            }
            intent, _ = MODULE.classify("lmstudio", 1234, "installed-model", "Check?")
        self.assertEqual(intent, "clarify")
        url, payload = request.call_args.args
        self.assertEqual(url, "http://127.0.0.1:1234/v1/chat/completions")
        self.assertEqual(payload["response_format"]["type"], "json_schema")

    def test_unknown_intent_and_extra_fields_are_rejected(self):
        for content in (
            '{"intent":"delete_files"}',
            '{"intent":"host_status","command":"rm"}',
        ):
            with (
                self.subTest(content=content),
                patch.object(MODULE, "request_json") as request,
            ):
                request.return_value = {"message": {"content": content}}
                with self.assertRaises(ValueError):
                    MODULE.classify("ollama", 11434, "installed-model", "Anything")

    def test_empty_response_is_rejected(self):
        with patch.object(MODULE, "request_json") as request:
            request.return_value = {"choices": [{"message": {"content": ""}}]}
            with self.assertRaisesRegex(ValueError, "no structured content"):
                MODULE.classify("lmstudio", 1234, "installed-model", "Anything")


if __name__ == "__main__":
    unittest.main()
