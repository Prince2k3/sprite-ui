"""Run: python3 -B -m unittest discover -s Tools/tests -p 'test_documentation_redirects.py'."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from html.parser import HTMLParser
from pathlib import Path
from unittest import mock


TOOLS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("documentation", TOOLS / "documentation.py")
documentation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(documentation)


class PageParser(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.elements = []
        self.text = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))

    def handle_data(self, data):
        self.text.append(data)


class RedirectTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.catalog = self.root / "SpriteUI.docc"
        self.articles = self.catalog / "Articles"
        self.articles.mkdir(parents=True)
        (self.articles / "input-recording-and-replay.md").write_text("# Input recording and replay\n")
        self.mapping = self.root / "documentation-redirects.json"
        self.write_mapping({"running-input-replays": "input-recording-and-replay"})
        self.output = self.root / "SpriteUI.doccarchive"
        self.work = self.root / "work"
        self.patch = mock.patch.multiple(documentation, CATALOG=self.catalog,
                                         REDIRECTS=self.mapping, WORK=self.work)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def write_mapping(self, value):
        self.mapping.write_text(json.dumps(value), encoding="utf-8")

    def build(self, base=None):
        return documentation.write_tutorial_redirects(self.output, base)

    def test_root_and_prefixed_routes(self):
        for base, prefix in ((None, ""), ("", ""), ("/", ""),
                             ("swiftui-ecs", "/swiftui-ecs"),
                             ("/swiftui-ecs/", "/swiftui-ecs"),
                             ("docs/releases/v1_0", "/docs/releases/v1_0")):
            with self.subTest(base=base):
                self.assertEqual(self.build(base), 1)
                page = PageParser((self.output / "tutorials/spriteui/running-input-replays/index.html")
                                  .read_text(encoding="utf-8"))
                url = f"{prefix}/documentation/spriteui/input-recording-and-replay/"
                self.assertIn(("meta", {"http-equiv": "refresh", "content": f"0; url={url}"}),
                              page.elements)
                self.assertIn(("a", {"href": url}), page.elements)
                self.assertIn("Continue to the guide.", "".join(page.text))
                self.assertFalse(any(tag == "script" for tag, _ in page.elements))

    def test_unsafe_hosting_paths_are_refused_before_writing(self):
        for base in ("../", "docs/../other", "docs/./other", "//evil.example", "https://evil.example",
                     "docs//other", "docs?next=evil", "docs#fragment", "docs%2f..", "docs\\other",
                     'docs\"><script>alert(1)</script>', "docs&other", "docs;url=evil", "docs\nnext",
                     "docs next", 42):
            with self.subTest(base=base), self.assertRaises(ValueError):
                self.build(base)
        self.assertFalse(self.output.exists())

    def test_unsafe_and_malformed_slugs_are_refused(self):
        invalid = ("../escape", "/absolute", "nested/path", "Uppercase", "under_score", "two--hyphens",
                   "-leading", "trailing-", "", "a%2fb", 'a\"<script>', "a?b", "a#b", "a\nb", "café")
        for slug in invalid:
            for mapping in ({slug: "input-recording-and-replay"}, {"old-tutorial": slug}):
                with self.subTest(mapping=mapping), self.assertRaises(ValueError):
                    self.write_mapping(mapping)
                    self.build()
        self.assertFalse(self.output.exists())

    def test_non_string_targets_and_non_object_mappings_are_refused(self):
        for value in (None, [], ["old-tutorial"], "old-tutorial", 42,
                      {"old-tutorial": None}, {"old-tutorial": 42},
                      {"old-tutorial": []}, {"old-tutorial": {"article": "target"}}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.write_mapping(value)
                self.build()
        self.assertFalse(self.output.exists())

    def test_invalid_json_and_duplicate_keys_are_refused(self):
        for text in ('{"old-tutorial":',
                     '{"old-tutorial":"input-recording-and-replay",'
                     '"old-tutorial":"input-recording-and-replay"}'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.mapping.write_text(text)
                self.build()
        self.assertFalse(self.output.exists())

    def test_missing_mapping_is_refused(self):
        self.mapping.unlink()
        with self.assertRaises(FileNotFoundError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_missing_target_prevents_all_redirect_writes(self):
        self.write_mapping({"valid-tutorial": "input-recording-and-replay", "old-tutorial": "missing-guide"})
        with self.assertRaisesRegex(ValueError, "target article does not exist"):
            self.build()
        self.assertFalse(self.output.exists())

    def test_article_symlink_outside_catalog_is_refused(self):
        outside = self.root / "outside.md"
        outside.write_text("# Outside\n")
        (self.articles / "outside.md").symlink_to(outside)
        self.write_mapping({"old-tutorial": "outside"})
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_output_directory_symlink_cannot_escape_archive(self):
        outside = self.root / "outside"
        outside.mkdir()
        self.output.mkdir()
        (self.output / "tutorials").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "escape the output archive"):
            self.build()
        self.assertEqual(list(outside.iterdir()), [])

    def test_output_file_symlink_cannot_overwrite_outside_file(self):
        outside = self.root / "outside.html"
        outside.write_text("Keep this content")
        destination = self.output / "tutorials/spriteui/running-input-replays/index.html"
        destination.parent.mkdir(parents=True)
        destination.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escape the output archive"):
            self.build()
        self.assertEqual(outside.read_text(), "Keep this content")

    def test_empty_mapping_is_valid(self):
        self.write_mapping({})
        self.assertEqual(self.build(), 0)

    def invoke_main(self, command, conversion_error=None):
        events = []

        def convert(*args, **kwargs):
            events.append("convert")
            if conversion_error:
                raise conversion_error

        def redirects(*args):
            events.append("redirects")
            return 1

        with mock.patch.object(documentation.shutil, "which", return_value="/fake/tool"), \
                mock.patch.object(documentation, "prepare_symbol_graphs", return_value=self.root / "graphs"), \
                mock.patch.object(documentation, "check_swift_examples") as examples, \
                mock.patch.object(documentation, "run", side_effect=convert), \
                mock.patch.object(documentation, "write_tutorial_redirects", side_effect=redirects) as writer, \
                mock.patch.object(documentation.subprocess, "call", return_value=0) as preview, \
                mock.patch("sys.argv", ["documentation.py", command, "--output", str(self.output),
                                        "--hosting-base-path", "docs/releases"]), \
                contextlib.redirect_stdout(io.StringIO()):
            if conversion_error:
                with self.assertRaises(RuntimeError):
                    documentation.main()
            else:
                self.assertEqual(documentation.main(), 0)
            if command == "preview" or conversion_error:
                writer.assert_not_called()
            else:
                writer.assert_called_once_with(self.output, "docs/releases")
            self.assertEqual(preview.call_count, int(command == "preview"))
            self.assertEqual(examples.call_count, int(command == "check"))
        return events

    def test_build_and_check_write_only_after_successful_convert(self):
        for command in ("build", "check"):
            with self.subTest(command=command):
                self.assertEqual(self.invoke_main(command), ["convert", "redirects"])

    def test_failed_convert_does_not_write_redirects(self):
        self.assertEqual(self.invoke_main("build", RuntimeError("Conversion failed")), ["convert"])

    def test_preview_does_not_write_redirects(self):
        self.assertEqual(self.invoke_main("preview"), [])

    def test_unsafe_base_is_refused_before_starting_build(self):
        with mock.patch("sys.argv", ["documentation.py", "--hosting-base-path", "../escape"]), \
                mock.patch.object(documentation, "prepare_symbol_graphs") as prepare, \
                contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaises(SystemExit) as error:
            documentation.main()
        self.assertEqual(error.exception.code, 2)
        prepare.assert_not_called()
        self.assertFalse(self.work.exists())

    def test_verification_summary_contract(self):
        resources = self.catalog / "Resources"
        resources.mkdir()
        (resources / "stage.swift").write_text("import SpriteUI\n")
        (self.articles / "input-recording-and-replay.md").write_text("```swift\nimport SpriteUI\n```\n")
        binary = self.root / "bin"
        binary.mkdir()
        self.work.mkdir()
        output = io.StringIO()
        with mock.patch.object(documentation, "run", side_effect=[str(binary), "/fake/sdk", "", ""]), \
                contextlib.redirect_stdout(output):
            documentation.check_swift_examples()
        self.assertEqual(output.getvalue().splitlines()[-1],
                         "All 1 tutorial stages and 1 guide examples compile.")


if __name__ == "__main__":
    unittest.main()
