#!/usr/bin/env python3
"""Read-only local Game Center setup checks for an iOS or macOS .app bundle.

Exit 0 means local checks passed, 1 means a local validation error, and 2 means
invalid CLI arguments. App Store Connect state always requires manual review.
No bundle files or Apple account settings are changed. Uses only Python's stdlib.
"""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError


GAME_CENTER = "com.apple.developer.game-center"
SANDBOX = "com.apple.security.app-sandbox"
NETWORK_PERMISSIONS = {
    "com.apple.security.network.client": "Outgoing Connections (Client)",
    "com.apple.security.network.server": "Incoming Connections (Server)",
}
SUPPLIED_SOURCE = "supplied plist not verified signed bundle"


def read_signed_entitlements(bundle):
    """Extract entitlements from the signature; this does not verify its validity."""
    try:
        result = subprocess.run(
            ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(
            f"Cannot inspect signed entitlements: {error}. Run on macOS with codesign available, "
            "or use --entitlements FILE for explicitly unverified static validation."
        ) from error
    if result.returncode:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"codesign failed (exit {result.returncode}): {diagnostic or 'no diagnostic'}. "
            "Build and sign the app with Game Center enabled, then check the resulting .app."
        )

    # Current codesign emits the plist on stdout and diagnostics on stderr.
    # Older versions may emit XML amid stderr diagnostics. Never mix the streams.
    for stream in (result.stdout, result.stderr):
        if stream.startswith(b"bplist00"):
            return stream
        start = stream.find(b"<?xml")
        if start < 0:
            start = stream.find(b"<plist")
        end = stream.find(b"</plist>", max(start, 0))
        if start >= 0 and end >= start:
            return stream[start:end + len(b"</plist>")]
    raise RuntimeError(
        "codesign returned no entitlement plist. Enable Game Center in Signing & Capabilities, "
        "rebuild and sign the app, then inspect the resulting .app."
    )


def load_dictionary(data):
    """Accept XML or binary plists, but require the dictionary used by Apple."""
    try:
        value = plistlib.loads(data)
    except ExpatError as error:
        raise ValueError(f"malformed XML plist: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("plist root must be a dictionary")
    return value


def check_bundle(bundle, *, entitlements_file=None, expected_bundle_id=None,
                 codesign_reader=read_signed_entitlements):
    """Validate local metadata using an injectable signed-entitlement reader."""
    bundle = Path(bundle).expanduser().resolve()
    report = {
        "bundle": str(bundle),
        "platform": None,
        "bundle_identifier": None,
        "entitlements_source": SUPPLIED_SOURCE if entitlements_file is not None else "signed bundle via codesign",
        "signature_verified": False,
        "local_checks_passed": False,
        "errors": [],
        "manual_checks": [
            {
                "code": "app_store_connect_app_version", "status": "unknown",
                "message": "Manually confirm the matching app record and app version have Game Center "
                           "enabled in App Store Connect. This tool cannot check server state or "
                           "automatically configure your Apple account.",
            },
            {
                "code": "multiplayer_compatibility", "status": "unknown",
                "message": "Manually review multiplayer compatibility for the intended app versions "
                           "and platforms in App Store Connect. Bundle entitlements cannot establish it.",
            },
        ],
    }

    def error(code, message):
        report["errors"].append({"code": code, "message": message})

    if bundle.suffix.lower() != ".app" or not bundle.is_dir():
        error("app_bundle", f"{bundle} is not an existing .app directory. Pass the built app bundle.")
        return report

    mac_layout = (bundle / "Contents").is_dir()
    report["platform"] = "macos" if mac_layout else "ios"
    info_path = bundle / "Contents" / "Info.plist" if mac_layout else bundle / "Info.plist"
    try:
        info = load_dictionary(info_path.read_bytes())
    except (OSError, ValueError, TypeError, OverflowError) as failure:
        error("info_plist", f"Cannot read {info_path}: {failure}. Rebuild the app with a valid Info.plist dictionary.")
        info = {}

    bundle_id = info.get("CFBundleIdentifier")
    if (not isinstance(bundle_id, str)
            or re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id) is None):
        error("bundle_identifier", "Info.plist CFBundleIdentifier must be a nonempty reverse-DNS string "
              "using letters, digits, hyphens, and dots; no wildcards or unresolved build variables. "
              "Set the target's Product Bundle Identifier and rebuild.")
    else:
        report["bundle_identifier"] = bundle_id
        if expected_bundle_id is not None and bundle_id != expected_bundle_id:
            error("bundle_identifier_mismatch", f"Info.plist bundle identifier {bundle_id!r} does not match "
                  f"expected {expected_bundle_id!r}. Check the target and build configuration.")

    try:
        if entitlements_file is not None:
            supplied = Path(entitlements_file).expanduser()
            report["entitlements_file"] = str(supplied.resolve())
            data = supplied.read_bytes()
        else:
            data = codesign_reader(bundle)
        entitlements = load_dictionary(data)
    except (OSError, ValueError, TypeError, OverflowError, RuntimeError) as failure:
        code = "supplied_entitlements" if entitlements_file is not None else "signed_entitlements"
        error(code, f"Cannot validate {report['entitlements_source']}: {failure}. "
              "Provide a valid entitlement plist dictionary or rebuild and sign the app with its entitlements.")
        return report

    if entitlements.get(GAME_CENTER) is not True:
        error("game_center", f"{GAME_CENTER} must be Boolean true (not a string or integer). "
              "Enable Game Center in the target's Signing & Capabilities, then rebuild and sign the app.")

    for key in ("application-identifier", "com.apple.application-identifier"):
        if key not in entitlements:
            continue
        value = entitlements[key]
        if not isinstance(value, str) or "." not in value or not value.split(".", 1)[0]:
            error("application_identifier", f"{key} must be a string in PREFIX.bundle.identifier form. "
                  "Rebuild with the signing profile for this app.")
        elif report["bundle_identifier"] and value.split(".", 1)[1] != bundle_id:
            error("application_identifier", f"{key} {value!r} does not match Info.plist "
                  f"CFBundleIdentifier {bundle_id!r}. Select the matching app signing profile and rebuild.")

    if mac_layout:
        if SANDBOX in entitlements and type(entitlements[SANDBOX]) is not bool:
            error("sandbox_type", f"{SANDBOX} must be Boolean true or false. Correct the macOS entitlement "
                  "type and rebuild; network requirements cannot be inferred from this value.")
        if entitlements.get(SANDBOX) is True:
            for key, setting in NETWORK_PERMISSIONS.items():
                if entitlements.get(key) is not True:
                    error("sandbox_network", f"Sandboxed macOS apps require {key} as Boolean true. "
                          f"Enable App Sandbox > Network > {setting}, then rebuild and sign the app.")

    report["local_checks_passed"] = not report["errors"]
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Built iOS or macOS .app bundle (read only).")
    parser.add_argument("--json", action="store_true", help="Emit one JSON report; exit status still reflects local errors.")
    parser.add_argument("--bundle-id", "--expected-bundle-id", dest="expected_bundle_id",
                        help="Expected CFBundleIdentifier, compared exactly against Info.plist.")
    parser.add_argument("--entitlements", type=Path, metavar="FILE",
                        help="Use a supplied plist for CI/static checks instead of codesign: "
                             "supplied plist not verified signed bundle.")
    args = parser.parse_args(argv)
    report = check_bundle(args.app, entitlements_file=args.entitlements,
                          expected_bundle_id=args.expected_bundle_id)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        outcome = "PASSED" if report["local_checks_passed"] else "FAILED"
        print(f"Local Game Center checks: {outcome}")
        print(f"Bundle: {report['bundle']}")
        print(f"Bundle identifier: {report['bundle_identifier'] or 'unknown/invalid'}")
        print(f"Entitlements source: {report['entitlements_source']}")
        print("Signature validity is not verified. No app files or Apple account settings are changed.")
        for item in report["errors"]:
            print(f"ERROR [{item['code']}]: {item['message']}")
        for item in report["manual_checks"]:
            print(f"UNKNOWN (manual) [{item['code']}]: {item['message']}")
    return 0 if report["local_checks_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
