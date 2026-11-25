#!/usr/bin/env python3
"""Validate, inspect, and provision Game Center draft metadata from a .gamekit bundle.

Python 3.10+, stdlib only; OpenSSL is used when signing with a .p8 key.
validate is offline. status/plan use GET only. apply requires --confirm-app.
No app creation, deletion, artwork upload, review submission, or release.
Request shapes follow Apple's App Store Connect OpenAPI 4.6.1.
"""

import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ORIGIN = "https://api.appstoreconnect.apple.com"
FORMATTERS = {
    "INTEGER", "DECIMAL_POINT_1_PLACE", "DECIMAL_POINT_2_PLACE", "DECIMAL_POINT_3_PLACE",
    "ELAPSED_TIME_CENTISECOND", "ELAPSED_TIME_MINUTE", "ELAPSED_TIME_SECOND",
    "MONEY_POUND_DECIMAL", "MONEY_POUND", "MONEY_DOLLAR_DECIMAL", "MONEY_DOLLAR",
    "MONEY_EURO_DECIMAL", "MONEY_EURO", "MONEY_FRANC_DECIMAL", "MONEY_FRANC",
    "MONEY_KRONER_DECIMAL", "MONEY_KRONER", "MONEY_YEN",
}
# Local bundle key, current endpoint version, resource stem, and writable attributes.
KINDS = {
    "leaderboards": ("v2", "Leaderboard", {
        "referenceName": str, "vendorIdentifier": str, "defaultFormatter": str,
        "submissionType": str, "scoreSortType": str, "scoreRangeStart": str,
        "scoreRangeEnd": str, "visibility": str, "activityProperties": dict,
    }),
    "achievements": ("v2", "Achievement", {
        "referenceName": str, "vendorIdentifier": str, "points": int,
        "showBeforeEarned": bool, "repeatable": bool, "activityProperties": dict,
    }),
    "gameActivities": ("v1", "Activity", {
        "referenceName": str, "vendorIdentifier": str, "playStyle": str,
        "minimumPlayersCount": int, "maximumPlayersCount": int,
        "supportsPartyCode": bool, "properties": dict,
    }),
    "challenges": ("v1", "Challenge", {
        "referenceName": str, "vendorIdentifier": str, "challengeType": str, "repeatable": bool,
    }),
}
REQUIRED = {
    "leaderboards": {"referenceName", "vendorIdentifier", "defaultFormatter", "submissionType", "scoreSortType"},
    "achievements": {"referenceName", "vendorIdentifier", "points", "showBeforeEarned", "repeatable"},
    "gameActivities": {"referenceName", "vendorIdentifier"},
    "challenges": {"referenceName", "vendorIdentifier", "challengeType"},
}
LOCAL_FIELDS = {
    "leaderboards": {"locale", "name", "formatterOverride", "formatterSuffix", "formatterSuffixSingular", "description"},
    "achievements": {"locale", "name", "beforeEarnedDescription", "afterEarnedDescription"},
    "gameActivities": {"locale", "name", "description"},
    "challenges": {"locale", "name", "description"},
}
MANUAL_STEPS = [
    "Upload and validate required artwork in App Store Connect or Xcode; this tool creates text metadata only.",
    "Enable Game Center for the intended app version and review multiplayer compatibility in App Store Connect.",
    "Review the draft components and submit them to Apple; creating drafts does not approve or release them.",
    "Verify native GameKit results separately; neither bundled metadata nor API success proves runtime availability.",
]


class SetupError(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def reject_constant(_):
    raise ValueError("Non-finite JSON number")


def identifier(value, label="identifier"):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}", value):
        raise SetupError(f"{label}: expected letters, digits, periods, underscores, or hyphens")
    return value


def unique(values, key, label):
    result = {}
    for value in values:
        name = key(value)
        if name in result:
            raise SetupError(f"{label}: duplicate {name}")
        result[name] = value
    return result


def info(kind):
    version, stem, _ = KINDS[kind]
    resource = "gameCenterActivities" if stem == "Activity" else f"gameCenter{stem}s"
    return {
        "type": resource, "path": f"/{version}/{resource}",
        "list": resource + ("V2" if version == "v2" else ""),
        "versionType": f"gameCenter{stem}Versions",
        "versionPath": f"/{version}/gameCenter{stem}Versions",
        "localizationPath": f"/{version}/gameCenter{stem}Localizations",
        "localizationType": f"gameCenter{stem}Localizations",
    }


def read_bundle(path):
    """Normalize the supported subset; refuse unsupported data rather than dropping it."""
    path = Path(path)
    if path.is_dir():
        path /= "gameCenterResources.json"
    try:
        document = json.loads(path.read_text(), parse_constant=reject_constant)
        resources = document["resources"]
        if not isinstance(resources, dict):
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SetupError("Expected a readable .gamekit bundle with a resources dictionary") from error
    prefixes = {kind: "gameActivity" if kind == "gameActivities" else stem[0].lower() + stem[1:]
                for kind, (_, stem, _) in KINDS.items()}
    localization_keys = {kind: prefix + "Localizations" for kind, prefix in prefixes.items()}
    image_keys = {f"{prefix}{suffix}" for prefix in prefixes.values()
                  for suffix in ("Images", "DefaultImages")}
    known = set(KINDS) | set(localization_keys.values()) | image_keys | {"challengeLeaderboardRelationships"}
    unsupported = sorted(key for key, value in resources.items() if key not in known and value)
    if unsupported:
        raise SetupError("Not supported by draft setup: " + ", ".join(unsupported) + ". Use Xcode sync for these resources.")
    result = {kind: [] for kind in KINDS}
    for kind, (_, _, fields) in KINDS.items():
        entries = resources.get(kind, [])
        localizations = resources.get(localization_keys[kind], {})
        if not isinstance(entries, list) or not isinstance(localizations, dict):
            raise SetupError(f"{kind}: expected a resource array and localization dictionary")
        for entry in entries:
            if not isinstance(entry, dict) or not REQUIRED[kind].issubset(entry):
                raise SetupError(f"{kind}: missing required attributes {sorted(REQUIRED[kind])}")
            ignored = {"archived", "localID"} | ({"allowedDurations"} if kind == "challenges" else set())
            if set(entry) - set(fields) - ignored:
                raise SetupError(f"{kind}: unsupported attributes {sorted(set(entry) - set(fields) - ignored)}")
            if entry.get("archived", False) is not False:
                raise SetupError(f"{kind}: archived resources cannot be provisioned")
            vendor = identifier(entry["vendorIdentifier"], "vendorIdentifier")
            attrs = {}
            for key, expected in fields.items():
                value = entry.get(key)
                if value is None and key not in REQUIRED[kind]:
                    continue
                if type(value) is not expected or (expected is str and not value.strip()):
                    raise SetupError(f"{vendor}.{key}: expected nonempty {expected.__name__}")
                if expected is dict and not all(type(k) is str and type(v) is str for k, v in value.items()):
                    raise SetupError(f"{vendor}.{key}: expected string-to-string values")
                attrs[key] = value
            if len(vendor) > 100 or len(attrs["referenceName"]) > 255:
                raise SetupError(f"{vendor}: identifier or reference name is too long")
            enums = {"defaultFormatter": FORMATTERS, "submissionType": {"BEST_SCORE", "MOST_RECENT_SCORE"},
                     "scoreSortType": {"ASC", "DESC"}, "visibility": {"SHOW_FOR_ALL", "HIDE_FOR_ALL"},
                     "playStyle": {"SYNCHRONOUS", "ASYNCHRONOUS"}, "challengeType": {"LEADERBOARD"}}
            for key, allowed in enums.items():
                if key in attrs and attrs[key] not in allowed:
                    raise SetupError(f"{vendor}.{key}: unsupported value")
            if kind == "achievements" and not 1 <= attrs["points"] <= 100:
                raise SetupError(f"{vendor}.points: expected 1...100")
            if kind == "gameActivities":
                low, high = attrs.get("minimumPlayersCount", 1), attrs.get("maximumPlayersCount", 1)
                if not 1 <= low <= high:
                    raise SetupError(f"{vendor}: invalid player count range")
            for key in ("scoreRangeStart", "scoreRangeEnd"):
                if key in attrs and not re.fullmatch(r"-?[0-9]+", attrs[key]):
                    raise SetupError(f"{vendor}.{key}: expected an integer string")
            if all(k in attrs for k in ("scoreRangeStart", "scoreRangeEnd")) and int(attrs["scoreRangeStart"]) > int(attrs["scoreRangeEnd"]):
                raise SetupError(f"{vendor}: reversed score range")
            locales = localizations.get(vendor, [])
            if not isinstance(locales, list) or not locales:
                raise SetupError(f"{vendor}: supply at least one localization")
            clean = []
            for locale in locales:
                if not isinstance(locale, dict) or set(locale) - LOCAL_FIELDS[kind] - {"localID"}:
                    raise SetupError(f"{vendor}: unsupported localization fields")
                required = {"locale", "name"} | ({"beforeEarnedDescription", "afterEarnedDescription"} if kind == "achievements" else set())
                if any(type(locale.get(k)) is not str or not locale[k].strip() for k in required):
                    raise SetupError(f"{vendor}: localization missing required text")
                value = {k: v for k, v in locale.items() if k in LOCAL_FIELDS[kind] and v is not None}
                if any(type(v) is not str for v in value.values()):
                    raise SetupError(f"{vendor}: localization values must be strings")
                if "formatterOverride" in value and value["formatterOverride"] not in FORMATTERS:
                    raise SetupError(f"{vendor}: invalid formatter override")
                clean.append(value)
            unique(clean, lambda x: x["locale"], vendor + " locales")
            result[kind].append({"attributes": attrs, "localizations": sorted(clean, key=lambda x: x["locale"])})
        unique(result[kind], lambda x: x["attributes"]["vendorIdentifier"], kind)
        if set(localizations) - {x["vendorIdentifier"] for x in entries}:
            raise SetupError(f"{kind}: localization references an unknown resource")
        result[kind].sort(key=lambda x: x["attributes"]["vendorIdentifier"])
    boards = {x["attributes"]["vendorIdentifier"] for x in result["leaderboards"]}
    local_ids = unique(resources.get("leaderboards", []),
                       lambda x: identifier(x.get("localID", x["vendorIdentifier"]), "leaderboard localID"),
                       "leaderboard local IDs")
    relationships = resources.get("challengeLeaderboardRelationships", {})
    challenge_ids = {x["attributes"]["vendorIdentifier"] for x in result["challenges"]}
    if not isinstance(relationships, dict) or set(relationships) != challenge_ids:
        raise SetupError("Supply one leaderboard relationship for each challenge")
    for item in result["challenges"]:
        vendor = item["attributes"]["vendorIdentifier"]
        links = relationships[vendor]
        if not isinstance(links, list) or len(links) != 1 or not isinstance(links[0], dict):
            raise SetupError(f"{vendor}: expected exactly one leaderboard")
        # Xcode relationships may use localID rather than the permanent vendor identifier.
        local_id = identifier(links[0].get("leaderboardLocalID"), "leaderboardLocalID")
        board = local_ids.get(local_id, {}).get("vendorIdentifier")
        if board not in boards:
            raise SetupError(f"{vendor}: linked leaderboard is absent from this bundle")
        item["leaderboard"] = board
    if not any(result.values()):
        raise SetupError("The bundle contains no supported Game Center resources")
    return result


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def jwt_signature(der):
    """Convert OpenSSL's DER ECDSA signature to JWT's fixed-width R || S."""
    offset = 0

    def value(tag):
        nonlocal offset
        if offset + 2 > len(der) or der[offset] != tag:
            raise SetupError("OpenSSL did not return a P-256 signature")
        length = der[offset + 1]
        offset += 2
        if length >= 128 or offset + length > len(der):
            raise SetupError("Invalid ECDSA signature length")
        data = der[offset:offset + length]
        offset += length
        return data

    sequence = value(0x30)
    if offset != len(der):
        raise SetupError("Invalid ECDSA signature suffix")
    der, offset = sequence, 0
    integers = []
    for _ in range(2):
        integer = value(0x02)
        if not integer or integer[0] & 0x80:
            raise SetupError("Invalid ECDSA integer")
        integer = integer.lstrip(b"\0")
        if len(integer) > 32:
            raise SetupError("API keys must use the ES256 P-256 curve")
        integers.append(integer.rjust(32, b"\0"))
    if offset != len(der):
        raise SetupError("Invalid ECDSA signature suffix")
    return b"".join(integers)


class Credentials:
    def __init__(self, env=None, individual=False, clock=time.time):
        env = os.environ if env is None else env
        self.supplied = env.get("ASC_TOKEN")
        self.key_id = env.get("ASC_KEY_ID")
        self.issuer = env.get("ASC_ISSUER_ID")
        self.path = env.get("ASC_PRIVATE_KEY_PATH")
        self.individual, self.clock = individual, clock
        self.cached, self.expires = None, 0
        if not self.supplied and not (self.key_id and self.path and (individual or self.issuer)):
            raise SetupError("Set ASC_TOKEN, or ASC_KEY_ID + ASC_PRIVATE_KEY_PATH + ASC_ISSUER_ID (team key). "
                             "For an individual key omit the issuer and pass --individual-key.")
        if self.supplied and (len(self.supplied.split(".")) != 3 or any(c.isspace() for c in self.supplied)):
            raise SetupError("ASC_TOKEN must be a JWT; do not include the Bearer prefix")

    def token(self):
        if self.supplied:
            return self.supplied
        now = int(self.clock())
        if self.cached and now < self.expires - 60:
            return self.cached
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        claims = {"iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
        claims.update({"sub": "user"} if self.individual else {"iss": self.issuer})
        message = (b64(canonical(header).encode()) + "." + b64(canonical(claims).encode())).encode()
        try:
            signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(Path(self.path).expanduser()),
                                     "-passin", "pass:"], input=message, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise SetupError("Cannot sign JWT. Install OpenSSL and check ASC_PRIVATE_KEY_PATH.") from error
        if signed.returncode:
            raise SetupError("Cannot sign JWT. Check that the .p8 file is an unencrypted App Store Connect API key.")
        self.cached = message.decode() + "." + b64(jwt_signature(signed.stdout))
        self.expires = now + 600
        return self.cached


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, credentials, opener=None, sleep=time.sleep):
        self.credentials = credentials
        self.opener = opener or urllib.request.build_opener(NoRedirect())
        self.sleep = sleep

    @staticmethod
    def url(path):
        url = urllib.parse.urljoin(ORIGIN, path)
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com"
                or parsed.fragment or not parsed.path.startswith(("/v1/", "/v2/"))):
            raise SetupError("Refused a request outside Apple's App Store Connect API")
        return url

    def request(self, method, path, body=None):
        if method not in {"GET", "POST"}:
            raise SetupError("Draft setup supports GET and POST only")
        url = self.url(path)
        for attempt in range(3):
            token = self.credentials.token()
            req = urllib.request.Request(url, data=None if body is None else canonical(body).encode(), method=method,
                                         headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                                                  "Accept": "application/json", "User-Agent": "SpriteUI-GameCenterSetup/1"})
            try:
                with self.opener.open(req, timeout=30) as response:
                    data = response.read(16 * 1024 * 1024 + 1)
                    if len(data) > 16 * 1024 * 1024:
                        raise SetupError("App Store Connect response exceeded the size limit")
                    value = json.loads(data, parse_constant=reject_constant)
                    if not isinstance(value, dict):
                        raise ValueError()
                    return value
            except urllib.error.HTTPError as error:
                if method == "GET" and error.code in {429, 500, 502, 503, 504} and attempt < 2:
                    delay = error.headers.get("Retry-After", "1")
                    error.close()
                    self.sleep(min(int(delay), 5) if delay.isdigit() else 1)
                    continue
                codes = []
                try:
                    errors = json.loads(error.read(65536)).get("errors", [])
                    if isinstance(errors, list):
                        codes = [str(e.get("code", "UNKNOWN")) for e in errors if isinstance(e, dict)]
                except (ValueError, AttributeError, OSError, http.client.HTTPException):
                    pass
                finally:
                    error.close()
                hint = {401: "Check API key identity, JWT expiry, and the Mac's clock.",
                        403: "Check API key roles and access to this app.",
                        404: "Check the app record, Game Center setup, and API resource IDs.",
                        409: "Server state changed or metadata conflicts; run plan again."}.get(error.code, "Run plan again before retrying writes.")
                detail = (", ".join(codes) or "no error code")[:300].replace(token, "[redacted]")
                raise SetupError(f"App Store Connect HTTP {error.code} ({detail}). {hint}") from None
            except (urllib.error.URLError, TimeoutError, OSError, http.client.HTTPException):
                raise SetupError("App Store Connect connection failed. A write may have reached Apple; run plan before retrying.") from None
            except (ValueError, UnicodeError):
                raise SetupError("App Store Connect returned invalid JSON; run plan before retrying writes.") from None

    def all(self, path):
        values, seen = [], set()
        while path:
            url = self.url(path)
            if url in seen or len(seen) >= 100:
                raise SetupError("Invalid or excessive App Store Connect pagination")
            seen.add(url)
            document = self.request("GET", url)
            data = document.get("data")
            if not isinstance(data, list) or not all(isinstance(x, dict) for x in data):
                raise SetupError("Expected an App Store Connect resource array")
            values.extend(data)
            links = document.get("links", {})
            if not isinstance(links, dict):
                raise SetupError("Invalid App Store Connect pagination object")
            path = links.get("next")
            if path is not None and not isinstance(path, str):
                raise SetupError("Invalid App Store Connect pagination link")
        return values


def resource_id(resource):
    try:
        return identifier(resource["id"], "API resource ID")
    except (KeyError, TypeError) as error:
        raise SetupError("App Store Connect response omitted a resource ID") from error


def attributes(resource):
    if not isinstance(resource, dict) or not isinstance(resource.get("attributes"), dict):
        raise SetupError("App Store Connect response omitted resource attributes")
    return resource["attributes"]


def locate_app(client, bundle_id):
    identifier(bundle_id, "bundle ID")
    apps = client.all("/v1/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 200}))
    if len(apps) != 1 or attributes(apps[0]).get("bundleId") != bundle_id:
        raise SetupError("Expected exactly one matching App Store Connect app. Create the app record first and check key access.")
    app = apps[0]
    detail = client.request("GET", f"/v1/apps/{resource_id(app)}/gameCenterDetail?include=gameCenterGroup").get("data")
    if not isinstance(detail, dict):
        raise SetupError("No Game Center detail exists. Enable Game Center for the app in App Store Connect first.")
    if detail.get("relationships", {}).get("gameCenterGroup", {}).get("data"):
        raise SetupError("Grouped Game Center resources are not supported by this app-scoped draft setup; use Xcode sync.")
    return app, detail


def load_catalog(client, detail_id):
    result = {}
    for kind in KINDS:
        spec = info(kind)
        entries = client.all(f"/v1/gameCenterDetails/{detail_id}/{spec['list']}?limit=200")
        unique(entries, lambda x: identifier(attributes(x).get("vendorIdentifier"), "server vendorIdentifier"), "server " + kind)
        result[kind] = []
        for entry in entries:
            item = dict(entry)
            versions = client.all(f"{spec['path']}/{resource_id(entry)}/versions?limit=200")
            for version in versions:
                resource_id(version)
                attributes(version)
            item["setupVersions"] = versions
            result[kind].append(item)
    return result


def relation(resource_type, value):
    return {"data": {"type": resource_type, "id": value}}


def selected_version(versions):
    if not versions:
        raise SetupError("Resource has no version; inspect it in App Store Connect")
    if any(type(attributes(v).get("version")) is not int for v in versions):
        raise SetupError("Resource version numbers are missing")
    ordered = sorted(versions, key=lambda v: v["attributes"]["version"], reverse=True)
    if len(ordered) > 1 and ordered[0]["attributes"]["version"] == ordered[1]["attributes"]["version"]:
        raise SetupError("Resource has ambiguous latest versions")
    return ordered[0]


def make_plan(client, bundle_id, manifest):
    app, detail = locate_app(client, bundle_id)
    detail_id = resource_id(detail)
    catalog = load_catalog(client, detail_id)
    operations, conflicts, bindings = [], [], {}
    for kind, items in manifest.items():
        spec = info(kind)
        existing = {x["attributes"]["vendorIdentifier"]: x for x in catalog[kind]}
        for item in items:
            attrs = item["attributes"]
            vendor = attrs["vendorIdentifier"]
            key, version_key = f"{kind}:{vendor}", f"version:{kind}:{vendor}"
            current = existing.get(vendor)
            if current is None:
                relationships = {"gameCenterDetail": relation("gameCenterDetails", detail_id),
                                 "versions": {"data": [{"type": spec["versionType"], "id": "initial-version"}]}}
                if kind == "challenges":
                    relationships["leaderboardV2"] = relation("gameCenterLeaderboards", "@leaderboards:" + item["leaderboard"])
                body = {"data": {"type": spec["type"], "attributes": attrs, "relationships": relationships},
                        "included": [{"type": spec["versionType"], "id": "initial-version"}]}
                operations.append({"action": "create", "key": key, "path": spec["path"], "body": body})
                operations.append({"action": "find-version", "key": version_key,
                                   "path": f"{spec['path']}/@{key}/versions?limit=200"})
                locales, editable = {}, True
            else:
                bindings[key] = resource_id(current)
                server_attrs = attributes(current)
                differing = sorted(k for k, v in attrs.items() if server_attrs.get(k) != v
                                   and not (k in {"activityProperties", "properties"} and v == {} and server_attrs.get(k) is None))
                if current.get("attributes", {}).get("archived") is True:
                    differing.append("archived")
                if differing:
                    conflicts.append(f"{key}: existing attributes differ ({', '.join(differing)}); no overwrite planned")
                if kind == "challenges":
                    challenge = client.request("GET", f"{spec['path']}/{resource_id(current)}?include=leaderboardV2").get("data")
                    if not isinstance(challenge, dict):
                        raise SetupError("Challenge response omitted resource data")
                    link = challenge.get("relationships", {}).get("leaderboardV2", {}).get("data")
                    expected = bindings.get("leaderboards:" + item["leaderboard"])
                    if not isinstance(link, dict) or not expected or link.get("id") != expected:
                        conflicts.append(f"{key}: existing leaderboard association differs; inspect it in App Store Connect")
                try:
                    version = selected_version(current["setupVersions"])
                except SetupError as error:
                    conflicts.append(f"{key}: {error}")
                    continue
                bindings[version_key] = resource_id(version)
                editable = version.get("attributes", {}).get("state") == "PREPARE_FOR_SUBMISSION"
                remote_locales = client.all(f"{spec['versionPath']}/{resource_id(version)}/localizations?limit=200")
                locales = unique(remote_locales, lambda x: identifier(attributes(x).get("locale"), "server locale"), key + " server locales")
            for locale in item["localizations"]:
                current_locale = locales.get(locale["locale"])
                if current_locale:
                    if any(current_locale.get("attributes", {}).get(k) != v for k, v in locale.items()):
                        conflicts.append(f"{key}/{locale['locale']}: text differs; no overwrite planned")
                elif not editable:
                    conflicts.append(f"{key}/{locale['locale']}: latest version is not an editable draft")
                else:
                    operations.append({"action": "create-localization", "path": spec["localizationPath"],
                                       "key": key + "/" + locale["locale"],
                                       "body": {"data": {"type": spec["localizationType"], "attributes": locale,
                                                         "relationships": {"version": relation(spec["versionType"], "@" + version_key)}}}})
    result = {"app": {"id": resource_id(app), "bundleId": bundle_id, "name": app.get("attributes", {}).get("name")},
              "gameCenterDetailId": detail_id, "operations": operations, "bindings": bindings,
              "conflicts": conflicts, "manualSteps": MANUAL_STEPS}
    result["sha256"] = hashlib.sha256(canonical(result).encode()).hexdigest()
    return result


def app_version_status(client, detail_id):
    versions = client.all(f"/v1/gameCenterDetails/{detail_id}/gameCenterAppVersions?limit=200")
    result = []
    for version in versions:
        app_version = client.request("GET", f"/v1/gameCenterAppVersions/{resource_id(version)}/appStoreVersion").get("data")
        result.append({"id": resource_id(version), "enabled": attributes(version).get("enabled"),
                       "appStoreVersion": {"id": resource_id(app_version), **attributes(app_version)}})
    return result


def resolve_reference(value, bindings):
    if not isinstance(value, str) or not value.startswith("@"):
        return value
    try:
        return bindings[value[1:]]
    except KeyError as error:
        raise SetupError("Unresolved resource dependency: " + value[1:]) from error


def resolve_relationships(body, bindings):
    # Only generated relationship IDs are references. User attributes stay literal,
    # including names and property-map values that happen to begin with '@'.
    result = json.loads(canonical(body))
    for relationship in result["data"].get("relationships", {}).values():
        data = relationship["data"]
        for item in data if isinstance(data, list) else [data]:
            item["id"] = resolve_reference(item["id"], bindings)
    return result


def apply_plan(client, plan, confirmed_bundle_id, expected_sha):
    if confirmed_bundle_id != plan["app"]["bundleId"]:
        raise SetupError("--confirm-app must exactly match the target bundle ID")
    if expected_sha != plan["sha256"]:
        raise SetupError("Plan changed. Run plan again and review its new sha256 before applying.")
    if plan["conflicts"]:
        raise SetupError("Resolve all reported conflicts before applying; no writes were made")
    bindings, completed = dict(plan["bindings"]), []
    for operation in plan["operations"]:
        try:
            path = "/".join(resolve_reference(part, bindings) for part in operation["path"].split("/"))
            if operation["action"] == "find-version":
                version = selected_version(client.all(path))
                if version.get("attributes", {}).get("state") != "PREPARE_FOR_SUBMISSION":
                    raise SetupError("Created version is not an editable draft")
                bindings[operation["key"]] = resource_id(version)
                continue
            response = client.request("POST", path, resolve_relationships(operation["body"], bindings))
            bindings[operation["key"]] = resource_id(response.get("data"))
            completed.append(operation["key"])
        except SetupError as error:
            raise SetupError(f"Stopped after {len(completed)} confirmed writes. {error} "
                             "No write is retried automatically. Run plan to reconcile partial server state.") from error
    return {"app": plan["app"], "created": completed, "manualSteps": MANUAL_STEPS}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "status", "plan", "apply"):
        command = sub.add_parser(name)
        command.add_argument("--bundle-id", required=True)
        if name != "status":
            command.add_argument("--gamekit", required=True, type=Path, help=".gamekit directory or gameCenterResources.json")
        if name != "validate":
            command.add_argument("--individual-key", action="store_true", help="Use sub=user instead of a team issuer in the JWT")
        if name == "apply":
            command.add_argument("--confirm-app", required=True)
            command.add_argument("--plan-sha256", required=True, help="sha256 from a freshly reviewed plan")
    args = parser.parse_args(argv)
    try:
        identifier(args.bundle_id, "bundle ID")
        manifest = None if args.command == "status" else read_bundle(args.gamekit)
        if args.command == "validate":
            report = {"bundleId": args.bundle_id, "valid": True,
                      "counts": {k: len(v) for k, v in manifest.items()}, "manualSteps": MANUAL_STEPS}
        else:
            # Check the explicit target before reading credentials or issuing any request.
            if args.command == "apply" and args.confirm_app != args.bundle_id:
                raise SetupError("--confirm-app must exactly match --bundle-id")
            client = Client(Credentials(individual=args.individual_key))
            if args.command == "status":
                app, detail = locate_app(client, args.bundle_id)
                catalog = load_catalog(client, resource_id(detail))
                report = {"app": {"id": resource_id(app), "bundleId": args.bundle_id},
                          "resources": {kind: [{"id": resource_id(x), **x.get("attributes", {}),
                                                "versions": [{"id": resource_id(v), **v.get("attributes", {})} for v in x["setupVersions"]]}
                                               for x in values] for kind, values in catalog.items()},
                          "appVersions": app_version_status(client, resource_id(detail)),
                          "manualSteps": MANUAL_STEPS}
            else:
                report = make_plan(client, args.bundle_id, manifest)
                if args.command == "apply":
                    report = apply_plan(client, report, args.confirm_app, args.plan_sha256)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 3 if report.get("conflicts") else 0
    except SetupError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
