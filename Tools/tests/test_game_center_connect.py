"""Offline contract, reconciliation, and authentication tests. Never contacts Apple."""
import base64
import copy
import importlib.util
import http.client
import io
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("game_center_connect", ROOT / "Tools/game-center-connect.py")
gc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gc)
FIXTURE = ROOT / "Examples/DemoBots/App/DemoBotsLocal.gamekit/gameCenterResources.json"
CONTRACT = json.loads((Path(__file__).parent / "fixtures/asc-game-center-4.6.1.json").read_text())


def check_schema(value, schema):
    """Validate the request subset used here against Apple's pinned OpenAPI schemas."""
    if "$ref" in schema:
        return check_schema(value, CONTRACT["components"]["schemas"][schema["$ref"].split("/")[-1]])
    if value is None and schema.get("nullable"):
        return
    kind = schema.get("type")
    expected = {"object": dict, "array": list, "string": str, "integer": int, "boolean": bool}.get(kind)
    if expected:
        assert type(value) is expected, (value, kind)
    if "enum" in schema:
        assert value in schema["enum"], (value, schema["enum"])
    if kind == "object":
        assert set(schema.get("required", [])) <= set(value), (value, schema.get("required"))
        props = schema.get("properties", {})
        if props:
            assert set(value) <= set(props), (set(value) - set(props))
        for key, child in value.items():
            if key in props:
                check_schema(child, props[key])
            elif isinstance(schema.get("additionalProperties"), dict):
                check_schema(child, schema["additionalProperties"])
    if kind == "array":
        for child in value:
            check_schema(child, schema["items"])


class FakeAPI:
    def __init__(self):
        self.resources = {gc.info(k)["type"]: [] for k in gc.KINDS}
        self.versions, self.locales, self.requests = {}, {}, []
        self.sequence, self.posts = 0, 0
        self.fail_after_accepting = None
        self.grouped = False

    def all(self, path):
        return self.request("GET", path)["data"]

    def request(self, method, path, body=None):
        self.requests.append((method, path, copy.deepcopy(body)))
        url = urllib.parse.urlsplit(path)
        parts = url.path.strip("/").split("/")
        if method == "GET":
            assert any(re.fullmatch(re.escape(template).replace(r"\{id\}", r"[^/]+"), url.path)
                       for template in CONTRACT["getPaths"]), path
            if parts == ["v1", "apps"]:
                return {"data": [{"id": "app1", "attributes": {"bundleId": "dev.spriteui.demobots", "name": "DemoBots"}}]}
            if parts == ["v1", "apps", "app1", "gameCenterDetail"]:
                return {"data": {"id": "detail1", "relationships": {"gameCenterGroup": {"data": {"id": "group1"} if self.grouped else None}}}}
            if parts[:3] == ["v1", "gameCenterDetails", "detail1"]:
                if parts[3] == "gameCenterAppVersions":
                    return {"data": []}
                return {"data": copy.deepcopy(self.resources[parts[3].removesuffix("V2")])}
            if parts[-1] == "versions":
                return {"data": copy.deepcopy(self.versions[parts[2]])}
            if parts[-1] == "localizations":
                return {"data": copy.deepcopy(self.locales[parts[2]])}
            if parts[:2] == ["v1", "gameCenterChallenges"] and len(parts) == 3:
                item = next(x for x in self.resources["gameCenterChallenges"] if x["id"] == parts[2])
                return {"data": copy.deepcopy(item)}
            raise AssertionError(path)
        assert method == "POST", method
        check_schema(body, {"$ref": CONTRACT["paths"][url.path]})
        self.posts += 1
        self.sequence += 1
        data = copy.deepcopy(body["data"])
        data["id"] = f"resource{self.sequence}"
        if data["type"] in self.resources:
            self.resources[data["type"]].append(data)
            version = {"type": body["included"][0]["type"], "id": f"version{self.sequence}",
                       "attributes": {"version": 1, "state": "PREPARE_FOR_SUBMISSION"}}
            self.versions[data["id"]] = [version]
            self.locales[version["id"]] = []
        else:
            version_id = data["relationships"]["version"]["data"]["id"]
            self.locales[version_id].append(data)
        if self.posts == self.fail_after_accepting:
            raise gc.SetupError("Connection lost after server accepted this write")
        return {"data": copy.deepcopy(data)}


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "gameCenterResources.json"
        self.document = json.loads(FIXTURE.read_text())

    def read(self):
        self.path.write_text(json.dumps(self.document))
        return gc.read_bundle(self.path)

    def test_real_bundle_is_reusable_without_an_account(self):
        result = gc.read_bundle(FIXTURE.parent)
        self.assertEqual({k: len(v) for k, v in result.items()},
                         {"leaderboards": 1, "achievements": 1, "gameActivities": 2, "challenges": 1})
        challenge = result["challenges"][0]
        self.assertNotIn("allowedDurations", challenge["attributes"])
        self.assertEqual(challenge["leaderboard"], "dev.spriteui.demobots.repair_score")

    def test_missing_locales_and_unsupported_resources_are_not_silently_skipped(self):
        for mutate in [lambda r: r.pop("challengeLocalizations"),
                       lambda r: r.update(leaderboardSets=[{"referenceName": "Group"}]),
                       lambda r: r["leaderboards"][0].update(recurrenceDuration="P1D")]:
            self.document = json.loads(FIXTURE.read_text())
            mutate(self.document["resources"])
            with self.assertRaises(gc.SetupError):
                self.read()

    def test_invalid_field_types_duplicates_and_archives_are_rejected(self):
        for field, value in [("repeatable", "yes"), ("points", True), ("points", 101), ("archived", True)]:
            self.document = json.loads(FIXTURE.read_text())
            self.document["resources"]["achievements"][0][field] = value
            with self.subTest(field=field), self.assertRaises(gc.SetupError):
                self.read()
        self.document = json.loads(FIXTURE.read_text())
        self.document["resources"]["challenges"] *= 2
        with self.assertRaisesRegex(gc.SetupError, "duplicate"):
            self.read()

    def test_links_must_resolve_before_any_network_access(self):
        self.document["resources"]["challengeLeaderboardRelationships"]["dev.spriteui.demobots.repair_challenge"][0]["leaderboardLocalID"] = "missing"
        with self.assertRaisesRegex(gc.SetupError, "absent"):
            self.read()

    def test_local_ids_are_resolved_to_permanent_vendor_ids(self):
        resources = self.document["resources"]
        resources["leaderboards"][0]["localID"] = "local-board-id"
        resources["challengeLeaderboardRelationships"]["dev.spriteui.demobots.repair_challenge"][0]["leaderboardLocalID"] = "local-board-id"
        self.assertEqual(self.read()["challenges"][0]["leaderboard"], "dev.spriteui.demobots.repair_score")

    def test_reversed_score_ranges_and_player_ranges_are_invalid(self):
        self.document["resources"]["leaderboards"][0].update(scoreRangeStart="100", scoreRangeEnd="0")
        with self.assertRaisesRegex(gc.SetupError, "reversed"):
            self.read()
        self.document = json.loads(FIXTURE.read_text())
        self.document["resources"]["gameActivities"][0].update(minimumPlayersCount=3, maximumPlayersCount=2)
        with self.assertRaisesRegex(gc.SetupError, "player count"):
            self.read()

    def test_duplicate_locale_and_unknown_localization_fail(self):
        locs = self.document["resources"]["challengeLocalizations"]
        locs["dev.spriteui.demobots.repair_challenge"] *= 2
        with self.assertRaisesRegex(gc.SetupError, "duplicate"):
            self.read()
        self.document = json.loads(FIXTURE.read_text())
        self.document["resources"]["challengeLocalizations"]["not-a-challenge"] = []
        with self.assertRaisesRegex(gc.SetupError, "unknown"):
            self.read()

    def test_validate_never_constructs_a_client(self):
        with patch.object(gc, "Client", side_effect=AssertionError("network")), patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(gc.main(["validate", "--bundle-id", "dev.spriteui.demobots", "--gamekit", str(FIXTURE)]), 0)


class PlanningTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.manifest = gc.read_bundle(FIXTURE)
        self.bundle = "dev.spriteui.demobots"

    def plan(self):
        return gc.make_plan(self.api, self.bundle, self.manifest)

    def apply(self, plan=None):
        plan = plan or self.plan()
        return gc.apply_plan(self.api, plan, self.bundle, plan["sha256"])

    def test_plan_reads_only_and_uses_current_endpoints_and_inline_versions(self):
        plan = self.plan()
        self.assertTrue(all(method == "GET" for method, _, _ in self.api.requests))
        self.assertFalse(plan["conflicts"])
        creates = [x for x in plan["operations"] if x["action"] == "create"]
        self.assertEqual(len(creates), 5)
        self.assertIn("/v2/gameCenterLeaderboards", [x["path"] for x in creates])
        self.assertIn("/v2/gameCenterAchievements", [x["path"] for x in creates])
        self.assertIn("/v1/gameCenterActivities", [x["path"] for x in creates])
        for op in creates:
            self.assertEqual(op["body"]["data"]["relationships"]["versions"]["data"][0], op["body"]["included"][0])

    def test_apply_creates_linked_localized_drafts_and_second_run_is_empty(self):
        result = self.apply()
        self.assertEqual(len(result["created"]), 10)
        challenge = self.api.resources["gameCenterChallenges"][0]
        board = self.api.resources["gameCenterLeaderboards"][0]
        self.assertEqual(challenge["relationships"]["leaderboardV2"]["data"]["id"], board["id"])
        self.assertEqual(self.plan()["operations"], [])
        self.assertEqual(self.apply()["created"], [])
        self.assertEqual(self.api.posts, 10)

    def test_accepted_write_with_lost_response_is_reconciled_on_rerun(self):
        self.api.fail_after_accepting = 6
        with self.assertRaisesRegex(gc.SetupError, "5 confirmed writes"):
            self.apply()
        self.api.fail_after_accepting = None
        self.apply()
        self.assertEqual(sum(map(len, self.api.resources.values())), 5)
        self.assertEqual(sum(map(len, self.api.locales.values())), 5)
        self.assertEqual(self.plan()["operations"], [])

    def test_existing_metadata_drift_blocks_all_writes(self):
        self.apply()
        self.api.resources["gameCenterLeaderboards"][0]["attributes"]["submissionType"] = "MOST_RECENT_SCORE"
        self.api.posts = 0
        plan = self.plan()
        self.assertTrue(plan["conflicts"])
        with self.assertRaisesRegex(gc.SetupError, "conflicts"):
            self.apply(plan)
        self.assertEqual(self.api.posts, 0)

    def test_optional_empty_property_maps_match_server_null(self):
        self.apply()
        for kind in ["gameCenterLeaderboards", "gameCenterAchievements"]:
            self.api.resources[kind][0]["attributes"]["activityProperties"] = None
        self.assertEqual(self.plan()["operations"], [])

    def test_existing_localization_drift_is_not_overwritten(self):
        self.apply()
        next(iter(self.api.locales.values()))[0]["attributes"]["name"] = "Someone else's title"
        with self.assertRaisesRegex(gc.SetupError, "conflicts"):
            self.apply()

    def test_live_versions_are_never_modified_to_add_missing_text(self):
        self.apply()
        for versions in self.api.versions.values():
            versions[0]["attributes"]["state"] = "LIVE"
        self.assertEqual(self.plan()["operations"], [])
        self.api.locales[next(iter(self.api.locales))] = []
        with self.assertRaisesRegex(gc.SetupError, "conflicts"):
            self.apply()

    def test_changed_plan_and_wrong_app_are_refused_before_writes(self):
        plan = self.plan()
        with self.assertRaisesRegex(gc.SetupError, "Plan changed"):
            gc.apply_plan(self.api, plan, self.bundle, "not-the-reviewed-plan")
        with self.assertRaisesRegex(gc.SetupError, "confirm-app"):
            gc.apply_plan(self.api, plan, "another.bundle", plan["sha256"])
        self.assertEqual(self.api.posts, 0)

    def test_wrong_target_is_rejected_before_credentials_are_loaded(self):
        with patch.object(gc, "Credentials", side_effect=AssertionError("credential access")), patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(gc.main(["apply", "--bundle-id", self.bundle, "--confirm-app", "another.bundle",
                                      "--plan-sha256", "anything", "--gamekit", str(FIXTURE)]), 1)

    def test_grouped_apps_require_explicitly_supported_tooling(self):
        self.api.grouped = True
        with self.assertRaisesRegex(gc.SetupError, "Grouped"):
            self.plan()
        self.assertEqual(self.api.posts, 0)

    def test_at_prefixed_metadata_remains_literal_during_dependency_resolution(self):
        self.manifest["challenges"][0]["localizations"][0]["name"] = "@leaderboards:dev.spriteui.demobots.repair_score"
        self.manifest["gameActivities"][0]["attributes"]["properties"] = {"label": "@literal"}
        self.apply()
        self.assertEqual(self.plan()["operations"], [])
        challenge = self.api.resources["gameCenterChallenges"][0]
        version_id = self.api.versions[challenge["id"]][0]["id"]
        self.assertEqual(self.api.locales[version_id][0]["attributes"]["name"], "@leaderboards:dev.spriteui.demobots.repair_score")


class Response(io.BytesIO):
    def __init__(self, data):
        super().__init__(json.dumps(data).encode())


class QueueOpener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        value = self.responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return Response(value)


class ClientTests(unittest.TestCase):
    def client(self, opener):
        return gc.Client(gc.Credentials({"ASC_TOKEN": "sensitive.token.value"}), opener, sleep=lambda _: None)

    def test_pagination_visits_every_page_and_sends_auth_only_to_apple(self):
        opener = QueueOpener({"data": [{"id": "1"}], "links": {"next": gc.ORIGIN + "/v1/apps?cursor=two"}},
                             {"data": [{"id": "2"}]})
        self.assertEqual(len(self.client(opener).all("/v1/apps")), 2)
        self.assertEqual(opener.requests[0].get_header("Authorization"), "Bearer sensitive.token.value")

    def test_foreign_pagination_links_and_cycles_fail_closed(self):
        for next_link in ["https://example.com/v1/apps", "https://api.appstoreconnect.apple.com.evil/v1/apps", "/v1/apps"]:
            opener = QueueOpener({"data": [], "links": {"next": next_link}})
            with self.subTest(next_link=next_link), self.assertRaises(gc.SetupError):
                self.client(opener).all("/v1/apps")
            self.assertEqual(len(opener.requests), 1)
        self.assertIsNone(gc.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.com"))

    def test_get_retries_rate_limit_but_post_is_never_retried(self):
        limited = lambda: urllib.error.HTTPError(gc.ORIGIN, 429, "rate", {"Retry-After": "0"}, io.BytesIO(b'{}'))
        opener = QueueOpener(limited(), {"data": []})
        self.assertEqual(self.client(opener).all("/v1/apps"), [])
        opener = QueueOpener(limited(), {"data": []})
        with self.assertRaisesRegex(gc.SetupError, "HTTP 429"):
            self.client(opener).request("POST", "/v1/gameCenterChallenges", {})
        self.assertEqual(len(opener.requests), 1)

    def test_credentials_and_raw_server_messages_are_not_logged(self):
        error = urllib.error.HTTPError(gc.ORIGIN, 401, "secret", {},
                                       io.BytesIO(b'{"errors":[{"code":"sensitive.token.value","detail":"private key"}]}'))
        with self.assertRaises(gc.SetupError) as failure:
            self.client(QueueOpener(error)).request("GET", "/v1/apps")
        self.assertNotIn("sensitive.token.value", str(failure.exception))
        self.assertNotIn("private key", str(failure.exception))

    def test_missing_auth_and_bad_response_are_actionable(self):
        with self.assertRaisesRegex(gc.SetupError, "ASC_TOKEN"):
            gc.Credentials({})
        with self.assertRaisesRegex(gc.SetupError, "resource array"):
            self.client(QueueOpener({"data": None})).all("/v1/apps")
        with self.assertRaises(gc.SetupError):
            self.client(QueueOpener()).request("DELETE", "/v1/apps/1")

    def test_malformed_error_envelopes_remain_structured(self):
        for errors in [None, 1, "not-an-array"]:
            failure = urllib.error.HTTPError(gc.ORIGIN, 403, "forbidden", {}, io.BytesIO(json.dumps({"errors": errors}).encode()))
            with self.subTest(errors=errors), self.assertRaisesRegex(gc.SetupError, "HTTP 403"):
                self.client(QueueOpener(failure)).request("POST", "/v1/gameCenterChallenges", {})

    def test_truncated_successful_write_response_has_recovery_guidance(self):
        class BrokenResponse(Response):
            def read(self, size):
                raise http.client.IncompleteRead(b"partial", 100)

        class BrokenOpener:
            def open(self, request, timeout):
                return BrokenResponse({})

        with self.assertRaisesRegex(gc.SetupError, "write may have reached Apple"):
            self.client(BrokenOpener()).request("POST", "/v1/gameCenterChallenges", {})


class AuthenticationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required to sign JWTs")
    def test_real_es256_signing_and_individual_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "test.p8"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            env = {"ASC_KEY_ID": "TESTKEY", "ASC_ISSUER_ID": "test-issuer", "ASC_PRIVATE_KEY_PATH": str(key)}
            for individual in [False, True]:
                credentials = gc.Credentials(env, individual=individual, clock=lambda: 1000)
                token = credentials.token()
                header, payload, signature = token.split(".")
                decode = lambda x: base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
                self.assertEqual(json.loads(decode(header))["alg"], "ES256")
                claims = json.loads(decode(payload))
                self.assertEqual(claims["exp"] - claims["iat"], 600)
                self.assertEqual(claims.get("sub"), "user" if individual else None)
                self.assertEqual(claims.get("iss"), None if individual else "test-issuer")
                raw = decode(signature)
                self.assertEqual(len(raw), 64)
                integers = []
                for part in [raw[:32], raw[32:]]:
                    part = part.lstrip(b'\0') or b'\0'
                    if part[0] & 0x80:
                        part = b'\0' + part
                    integers.append(b'\x02' + bytes([len(part)]) + part)
                encoded = b''.join(integers)
                sigfile = Path(directory) / "signature.der"
                sigfile.write_bytes(b'\x30' + bytes([len(encoded)]) + encoded)
                public = Path(directory) / "public.pem"
                subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)], check=True, capture_output=True)
                verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(sigfile)],
                                          input=(header + "." + payload).encode(), capture_output=True)
                self.assertEqual(verified.returncode, 0)
                self.assertEqual(credentials.token(), token)

    def test_malformed_or_wrong_curve_signature_is_rejected(self):
        for signature in [b"", b"\x30\x00", b"\x30\x03\x02\x01\xff", b"not DER"]:
            with self.subTest(signature=signature), self.assertRaises(gc.SetupError):
                gc.jwt_signature(signature)


if __name__ == "__main__":
    unittest.main()
