"""Evidence must fail closed and never turn static checks into live Game Center approval."""
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("multiplayer_release", Path(__file__).resolve().parents[1] / "check-multiplayer-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.log = Path(self.temp.name) / "checks.log"

    def run_output(self, output, code=0, kind="swift"):
        def runner(command, **kwargs):
            self.assertIsInstance(command, list)
            self.assertFalse(kwargs.get("shell", False))
            kwargs["stdout"].write(output)
            return subprocess.CompletedProcess(command, code)
        return release.execute_check(["swift", "test"], self.log, timeout=10, kind=kind, runner=runner)

    def test_counts_each_bundle_and_keeps_command_and_fresh_log(self):
        self.log.write_text("old evidence")
        report = self.run_output("Test run with 11 tests in 2 suites passed after 1s.\nTest run with 23 tests in 4 suites passed after 2s.\n")
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["tests_passed"], 34)
        self.assertEqual(report["command"], ["swift", "test"])
        self.assertNotIn("old evidence", self.log.read_text())

    def test_empty_or_zero_selection_does_not_count_as_success(self):
        for output in ("Build complete!", "No matching test cases were run", "Test run with 0 tests passed after 0s."):
            with self.subTest(output=output):
                self.assertEqual(self.run_output(output)["status"], "failed")

    def test_nonzero_exit_does_not_pass_even_with_partial_passing_bundles(self):
        report = self.run_output("Test run with 2 tests passed after 0s.", code=1)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["exit_code"], 1)

    def test_missing_tool_and_timeout_are_failed_evidence(self):
        for error in (FileNotFoundError("swift"), subprocess.TimeoutExpired("swift", 10)):
            report = release.execute_check(["swift", "test"], self.log, timeout=10, kind="swift", runner=mock.Mock(side_effect=error))
            self.assertEqual(report["status"], "failed")
            self.assertIn("error", report)

    def test_documentation_needs_a_compilation_summary(self):
        self.assertEqual(self.run_output("Build complete!", kind="documentation")["status"], "failed")
        report = self.run_output("All 61 tutorial stages and 100 guide examples compile.", kind="documentation")
        self.assertEqual(report["status"], "passed")
        self.assertEqual((report["tutorial_stages"], report["guide_examples"]), (61, 100))

    def test_native_checks_stay_pending_even_when_every_local_check_passes(self):
        report = release.make_report([{"status": "passed"}], [{"local_checks_passed": True}], revision={"commit": "abc"}, full_tests=True)
        self.assertTrue(report["local_checks_passed"])
        self.assertFalse(report["release_ready"])
        self.assertEqual(report["native_testing"]["status"], "pending")
        self.assertTrue(all(item["status"] == "pending" for item in report["native_testing"]["checks"]))
        json.dumps(report)

    def test_missing_evidence_or_any_failure_fails_local_checks(self):
        for checks, bundles in (([], []), ([{"status": "failed"}], []), ([{"status": "passed"}], [{"local_checks_passed": False}])):
            self.assertFalse(release.make_report(checks, bundles, revision={}, full_tests=False)["local_checks_passed"])

    def test_rejects_nonpositive_timeout_before_running_commands(self):
        with mock.patch.object(release, "execute_check") as execute:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                release.main(["--timeout", "0"])
            self.assertEqual(error.exception.code, 2)
            execute.assert_not_called()

    def test_never_writes_evidence_inside_an_inspected_bundle(self):
        bundle = Path(self.temp.name) / "Game.app"
        with mock.patch.object(release, "execute_check") as execute:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                release.main(["--ios-app", str(bundle), "--output", str(bundle / "report.json")])
            execute.assert_not_called()

    def test_cli_writes_local_results_without_promoting_native_status(self):
        output = Path(self.temp.name) / "evidence" / "report.json"
        for status, code in (("passed", 0), ("failed", 1)):
            with self.subTest(status=status):
                with mock.patch.object(release, "execute_check", return_value={"status": status}), mock.patch.object(release, "revision", return_value={"commit": "test"}), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(release.main(["--output", str(output)]), code)
                report = json.loads(output.read_text())
                self.assertEqual(report["local_checks_passed"], code == 0)
                self.assertFalse(report["release_ready"])
                self.assertEqual(report["native_testing"]["status"], "pending")

    def test_demobots_entitlements_match_the_checked_templates(self):
        for platform, name in (("ios", "DemoBots-iOS.entitlements"), ("macos", "DemoBots-macOS.entitlements")):
            self.assertEqual((release.ROOT / "Examples/DemoBots/App" / name).read_bytes(),
                             (release.ROOT / f"Tools/templates/game-center-{platform}.entitlements").read_bytes())


if __name__ == "__main__":
    unittest.main()
