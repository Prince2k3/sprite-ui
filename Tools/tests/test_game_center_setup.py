"""Run with: python3 -B -m unittest discover -s Tools/tests -p 'test_game_center_setup.py'."""

import contextlib
import importlib.util
import io
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


TOOLS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("game_center_setup", TOOLS / "check-game-center-setup.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

GAME_CENTER = "com.apple.developer.game-center"
SANDBOX = "com.apple.security.app-sandbox"
CLIENT = "com.apple.security.network.client"
SERVER = "com.apple.security.network.server"


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Sample ; $(touch nope).app"
        self.app.mkdir()
        self.info = self.app / "Info.plist"
        self.write_info({"CFBundleIdentifier": "com.example.game"})

    def write_info(self, value):
        self.info.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, dict):
            value = {'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', **value}
        self.info.write_bytes(plistlib.dumps(value))

    def check(self, entitlements=None, **kwargs):
        if entitlements is None:
            entitlements = {GAME_CENTER: True}
        return checker.check_bundle(
            self.app, codesign_reader=lambda path: plistlib.dumps(entitlements), **kwargs
        )

    def codes(self, report):
        return {error["code"] for error in report["errors"]}

    def make_mac(self):
        self.info.unlink()
        self.info = self.app / "Contents" / "Info.plist"
        self.write_info({"CFBundleIdentifier": "com.example.game"})

    def test_signed_local_success_keeps_server_state_unknown(self):
        report = self.check()
        self.assertTrue(report["local_checks_passed"])
        self.assertEqual(report["entitlements_source"], "signed bundle via codesign")
        self.assertFalse(report["signature_verified"])
        self.assertEqual({item["code"] for item in report["manual_checks"]},
                         {"app_store_connect_app_version", "multiplayer_compatibility"})
        self.assertTrue(all(item["status"] == "unknown" for item in report["manual_checks"]))
        self.assertIn("manual", json.dumps(report["manual_checks"]).lower())

    def test_missing_and_malformed_info(self):
        for contents in (None, b"not a plist", b'<?xml version="1.0"?><plist><dict>',
                         plistlib.dumps(["wrong root"])):
            with self.subTest(contents=contents):
                if contents is None:
                    self.info.unlink(missing_ok=True)
                else:
                    self.info.write_bytes(contents)
                report = self.check()
                self.assertFalse(report["local_checks_passed"])
                self.assertIn("info_plist", self.codes(report))

    def test_invalid_bundle_identifiers(self):
        for value in (None, 1, True, "", "com..game", "com.example.*", "$(PRODUCT_BUNDLE_IDENTIFIER)",
                      "com.example.game ", "com.example_game", "com.exämple.game"):
            with self.subTest(value=value):
                self.write_info({} if value is None else {"CFBundleIdentifier": value})
                self.assertIn("bundle_identifier", self.codes(self.check()))

    def test_expected_bundle_identifier(self):
        self.assertTrue(self.check(expected_bundle_id="com.example.game")["local_checks_passed"])
        self.assertIn("bundle_identifier_mismatch",
                      self.codes(self.check(expected_bundle_id="com.other.game")))

    def test_built_app_requires_resolved_version_and_build_numbers(self):
        for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
            for value in (None, '', ' ', 1, True, '$(CURRENT_PROJECT_VERSION)'):
                with self.subTest(key=key, value=value):
                    data = {'CFBundleIdentifier': 'com.example.game', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0'}
                    if value is None:
                        data.pop(key)
                    else:
                        data[key] = value
                    self.info.write_bytes(plistlib.dumps(data))
                    self.assertIn('bundle_version', self.codes(self.check()))

    def test_game_center_must_be_boolean_true(self):
        for value in (None, False, 1, "true", [], {}):
            with self.subTest(value=value):
                entitlements = {} if value is None else {GAME_CENTER: value}
                self.assertIn("game_center", self.codes(self.check(entitlements)))

    def test_application_identifiers_must_match_bundle(self):
        for key in ("application-identifier", "com.apple.application-identifier"):
            for value in (1, True, ["TEAM.com.example.game"], "com.example.game", "TEAM.*",
                          "TEAM.com.other.game", "TEAM.com.example.game.extra"):
                with self.subTest(key=key, value=value):
                    self.assertIn("application_identifier", self.codes(self.check(
                        {GAME_CENTER: True, key: value})))
            self.assertTrue(self.check({GAME_CENTER: True, key: "TEAM.com.example.game"})[
                "local_checks_passed"])

    def test_mac_sandbox_requires_both_network_permissions(self):
        self.make_mac()
        for missing in (CLIENT, SERVER):
            for value in (None, False, 1, "true"):
                with self.subTest(missing=missing, value=value):
                    entitlements = {GAME_CENTER: True, SANDBOX: True, CLIENT: True, SERVER: True}
                    if value is None:
                        del entitlements[missing]
                    else:
                        entitlements[missing] = value
                    report = self.check(entitlements)
                    self.assertIn("sandbox_network", self.codes(report))
                    self.assertEqual(report["platform"], "macos")

    def test_mac_without_sandbox_does_not_require_network_permissions(self):
        self.make_mac()
        for extra in ({}, {SANDBOX: False}):
            with self.subTest(extra=extra):
                self.assertTrue(self.check({GAME_CENTER: True, **extra})["local_checks_passed"])

    def test_mac_sandbox_rejects_invalid_types(self):
        self.make_mac()
        for value in (1, "true", [], {}):
            with self.subTest(value=value):
                self.assertIn("sandbox_type", self.codes(self.check({GAME_CENTER: True, SANDBOX: value})))

    def test_ios_does_not_require_mac_network_permissions(self):
        self.assertTrue(self.check({GAME_CENTER: True, SANDBOX: True})["local_checks_passed"])

    def test_missing_app_and_non_app_directory(self):
        for path in (self.app / "Missing.app", Path(self.temp.name)):
            with self.subTest(path=path):
                report = checker.check_bundle(path, codesign_reader=mock.Mock())
                self.assertIn("app_bundle", self.codes(report))
                self.assertEqual(len(report["manual_checks"]), 2)

    def test_signing_failure_is_actionable_and_never_falls_back(self):
        def fail(path):
            raise RuntimeError("code object is not signed at all")
        report = checker.check_bundle(self.app, codesign_reader=fail)
        self.assertIn("signed_entitlements", self.codes(report))
        self.assertFalse(report["local_checks_passed"])
        self.assertIn("sign", report["errors"][0]["message"].lower())

    def test_bad_signed_entitlements(self):
        for value in (b"", b"bad plist", b'<?xml version="1.0"?><plist><dict>', plistlib.dumps([True])):
            with self.subTest(value=value):
                report = checker.check_bundle(self.app, codesign_reader=lambda path: value)
                self.assertIn("signed_entitlements", self.codes(report))

    def test_supplied_plist_is_explicitly_unverified_and_skips_codesign(self):
        supplied = Path(self.temp.name) / "input.entitlements"
        supplied.write_bytes(plistlib.dumps({GAME_CENTER: True}, fmt=plistlib.FMT_BINARY))
        reader = mock.Mock(side_effect=AssertionError("must not invoke codesign"))
        report = checker.check_bundle(self.app, entitlements_file=supplied, codesign_reader=reader)
        self.assertTrue(report["local_checks_passed"])
        self.assertEqual(report["entitlements_source"], "supplied plist not verified signed bundle")
        self.assertFalse(report["signature_verified"])
        reader.assert_not_called()

    def test_missing_or_bad_supplied_plist(self):
        supplied = Path(self.temp.name) / "input.entitlements"
        for data in (None, b"broken", b'<?xml version="1.0"?><plist><dict>', plistlib.dumps([])):
            with self.subTest(data=data):
                if data is not None:
                    supplied.write_bytes(data)
                report = checker.check_bundle(self.app, entitlements_file=supplied)
                self.assertIn("supplied_entitlements", self.codes(report))

    def test_templates_validate_with_injected_reader(self):
        for platform in ("ios", "macos"):
            with self.subTest(platform=platform):
                if platform == "macos":
                    self.make_mac()
                template = TOOLS / "templates" / f"game-center-{platform}.entitlements"
                data = template.read_bytes()
                entitlements = plistlib.loads(data)
                self.assertIs(entitlements[GAME_CENTER], True)
                if platform == "macos":
                    for key in (SANDBOX, CLIENT, SERVER):
                        self.assertIs(entitlements[key], True)
                report = checker.check_bundle(self.app, codesign_reader=lambda path: data)
                self.assertTrue(report["local_checks_passed"], report)

    def test_json_cli_success_and_failure_exit_codes(self):
        supplied = Path(self.temp.name) / "input.entitlements"
        for entitlements, expected_exit in (({GAME_CENTER: True}, 0), ({GAME_CENTER: 1}, 1)):
            with self.subTest(entitlements=entitlements):
                supplied.write_bytes(plistlib.dumps(entitlements))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    code = checker.main([str(self.app), "--json", "--entitlements", str(supplied)])
                report = json.loads(output.getvalue())
                self.assertEqual(code, expected_exit)
                self.assertEqual(report["local_checks_passed"], expected_exit == 0)
                self.assertEqual(len(report["manual_checks"]), 2)

    def test_text_cli_discloses_manual_checks_and_unverified_source(self):
        supplied = Path(self.temp.name) / "input.entitlements"
        supplied.write_bytes(plistlib.dumps({GAME_CENTER: True}))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(checker.main([str(self.app), "--entitlements", str(supplied)]), 0)
        text = output.getvalue()
        for phrase in ("supplied plist not verified signed bundle", "UNKNOWN", "App Store Connect",
                       "multiplayer", "account"):
            self.assertIn(phrase, text)

    def test_checker_does_not_write_to_bundle(self):
        before = {path.relative_to(self.app): path.read_bytes() for path in self.app.rglob("*")
                  if path.is_file()}
        self.check()
        after = {path.relative_to(self.app): path.read_bytes() for path in self.app.rglob("*")
                 if path.is_file()}
        self.assertEqual(before, after)


class CodesignTests(unittest.TestCase):
    def test_stdout_plist_and_stderr_diagnostics_are_separate(self):
        payload = plistlib.dumps({GAME_CENTER: True})
        path = Path("/tmp/path with spaces;$(echo unsafe).app")
        result = subprocess.CompletedProcess([], 0, payload, b"Executable=/tmp/Game\nWarning: log\n")
        with mock.patch.object(checker.subprocess, "run", return_value=result) as run:
            self.assertEqual(plistlib.loads(checker.read_signed_entitlements(path)), {GAME_CENTER: True})
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["codesign", "-d", "--entitlements", "-", "--xml", str(path)])
        self.assertFalse(kwargs.get("shell", False))
        self.assertEqual(kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(kwargs["stderr"], subprocess.PIPE)

    def test_legacy_stderr_plist_with_logs(self):
        payload = plistlib.dumps({GAME_CENTER: True})
        result = subprocess.CompletedProcess([], 0, b"", b"Executable=Game\n" + payload + b"\nlog\n")
        with mock.patch.object(checker.subprocess, "run", return_value=result):
            self.assertEqual(plistlib.loads(checker.read_signed_entitlements(Path("/tmp/Game.app"))),
                             {GAME_CENTER: True})

    def test_nonzero_codesign_even_with_plist_is_failure(self):
        result = subprocess.CompletedProcess([], 1, plistlib.dumps({GAME_CENTER: True}), b"not signed")
        with mock.patch.object(checker.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "not signed"):
                checker.read_signed_entitlements(Path("/tmp/Game.app"))

    def test_success_without_entitlement_output_is_failure(self):
        result = subprocess.CompletedProcess([], 0, b"", b"Executable=Game\n")
        with mock.patch.object(checker.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "no entitlement plist"):
                checker.read_signed_entitlements(Path("/tmp/Game.app"))

    def test_missing_codesign_and_timeout_are_reported(self):
        for error in (FileNotFoundError("codesign not found"), subprocess.TimeoutExpired("codesign", 30)):
            with self.subTest(error=error):
                with mock.patch.object(checker.subprocess, "run", side_effect=error):
                    with self.assertRaises(RuntimeError):
                        checker.read_signed_entitlements(Path("/tmp/Game.app"))


if __name__ == "__main__":
    unittest.main()
