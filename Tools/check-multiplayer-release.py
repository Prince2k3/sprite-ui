#!/usr/bin/env python3
"""Run local multiplayer checks and write evidence. Native two-account testing stays pending.

Exit 0 means the requested LOCAL checks passed, not multiplayer release approval.
No authentication, matchmaking, provisioning, or Apple account settings are changed.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("game_center_setup", ROOT / "Tools/check-game-center-setup.py")
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)
FOCUSED_SUITES = r"Network.*Tests|KinematicMovementTests|InMemoryNetwork.*Tests|GameCenter.*Tests|DemoBotsCoopTests"
NATIVE_CHECKS = (
    ("signed_accounts", "Verify device/Mac signatures, provisioning, capabilities, and two independent Game Center accounts."),
    ("activity_routes", "Verify configured two-player activity, party codes, cold/warm invitations, and cross-platform compatibility."),
    ("round", "Match two accounts; move, shoot, confirm shared cures/score, and finish a round on both devices."),
    ("recovery", "Save, interrupt/background, reconnect the original roster, approve the checkpoint, and verify fresh baselines and neutral input."),
    ("account_changes", "Sign out/change account or lose a peer during preparation and play; verify teardown, deliberate retry, and no stale effects."),
)


def execute_check(command, log, *, timeout, kind, runner=subprocess.run):
    """Capture a fresh log; errors, timeouts, or an empty Swift selection fail closed."""
    log = Path(log)
    log.parent.mkdir(parents=True, exist_ok=True)
    result = {"command": list(command), "log": str(log.resolve()), "status": "failed", "kind": kind}
    started = time.monotonic()
    try:
        with log.open("w", encoding="utf-8") as output:
            process = runner(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                             text=True, timeout=timeout, check=False)
        result["exit_code"] = process.returncode
        content = log.read_text(encoding="utf-8", errors="replace")
        passed = process.returncode == 0
        if kind == "swift":
            counts = [int(value) for value in re.findall(r"Test run with (\d+) tests?[^\n]* passed", content)]
            result["tests_passed"] = sum(counts)
            # Swift Testing summaries are emitted once per test bundle, even for a filtered selection.
            passed = passed and bool(counts) and sum(counts) > 0
            if not counts or sum(counts) == 0:
                result["error"] = "No passing Swift Testing summary; an empty selection is not evidence."
        if kind == "documentation":
            match = re.search(r"All (\d+) tutorial stages and (\d+) guide examples compile\.", content)
            passed = passed and match is not None
            if match:
                result["tutorial_stages"] = int(match[1]); result["guide_examples"] = int(match[2])
            else:
                result["error"] = "Missing documentation compilation summary."
        result["status"] = "passed" if passed else "failed"
    except (OSError, subprocess.TimeoutExpired) as error:
        result["error"] = str(error)
    result["seconds"] = round(time.monotonic() - started, 3)
    return result


def make_report(checks, bundles, *, revision, full_tests):
    """Keep local evidence and unperformed native checks separate, including on local failures."""
    return {
        "schema_version": 1,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "revision": revision,
        "scope": "local full suite" if full_tests else "local multiplayer suite",
        "local_checks_passed": bool(checks) and all(item["status"] == "passed" for item in checks)
                               and all(item["local_checks_passed"] for item in bundles),
        "checks": checks,
        "bundle_checks": bundles,
        "native_testing": {"status": "pending", "checks": [
            {"id": code, "status": "pending", "description": message} for code, message in NATIVE_CHECKS
        ]},
        "release_ready": False,
        "limitation": "Local fixtures and supplied entitlement plists do not prove signed Game Center delivery or App Store Connect configuration.",
    }


def revision():
    try:
        value = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, timeout=10, check=True).stdout
        return {"commit": value, "working_tree_dirty": bool(dirty)}
    except (OSError, subprocess.SubprocessError):
        return {"commit": None, "working_tree_dirty": None}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full-tests", action="store_true", help="Run the complete Swift suite instead of the multiplayer selection.")
    parser.add_argument("--documentation", action="store_true", help="Also compile all DocC examples and the archive with warnings as errors.")
    parser.add_argument("--ios-app", type=Path, help="Built DemoBots .app to inspect with its supplied, unverified iOS entitlement template.")
    parser.add_argument("--macos-app", type=Path, help="Built DemoBotsMac .app to inspect with its supplied, unverified macOS entitlement template.")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/multiplayer-validation/report.json")
    parser.add_argument("--timeout", type=int, default=900, help="Positive timeout per command, in seconds.")
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    output = args.output.expanduser().resolve()
    # Logs belong in an evidence directory, never in either inspected .app bundle.
    for bundle in (args.ios_app, args.macos_app):
        if bundle is not None and output.is_relative_to(bundle.expanduser().resolve()):
            parser.error("--output must be outside the inspected app bundles")
    command = ["swift", "test"]
    if not args.full_tests:
        command += ["--filter", FOCUSED_SUITES]
    checks = [execute_check(command, output.parent / "swift-tests.log", timeout=args.timeout, kind="swift")]
    checks.append(execute_check([sys.executable, "-B", "-m", "unittest", "discover", "-s", "Tools/tests"],
                                output.parent / "tool-tests.log", timeout=args.timeout, kind="python"))
    if args.documentation:
        checks.append(execute_check(["Tools/build-documentation.sh", "check"], output.parent / "documentation.log", timeout=args.timeout, kind="documentation"))
    bundles = []
    for bundle, platform, identifier in ((args.ios_app, "ios", "dev.spriteui.demobots"), (args.macos_app, "macos", "dev.spriteui.demobots.mac")):
        if bundle is None:
            continue
        report = SETUP.check_bundle(bundle, expected_bundle_id=identifier,
                                    entitlements_file=ROOT / f"Tools/templates/game-center-{platform}.entitlements")
        if report["platform"] != platform:
            report["errors"].append({"code": "platform_mismatch", "message": f"Expected {platform} bundle layout."})
            report["local_checks_passed"] = False
        bundles.append(report)
    report = make_report(checks, bundles, revision=revision(), full_tests=args.full_tests)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Local checks: {'PASSED' if report['local_checks_passed'] else 'FAILED'}. Report: {output}")
    print("Native signed two-account testing: PENDING. Release approval: NOT ESTABLISHED.")
    return 0 if report["local_checks_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
