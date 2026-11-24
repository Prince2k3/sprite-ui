#!/usr/bin/env python3
"""Build, check, or preview SpriteUI's DocC catalog with the installed Xcode tools."""

import argparse
import copy
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources/SpriteUI/SpriteUI.docc"
WORK = ROOT / ".build/documentation"
MODULES = {"ECSCore", "Gameplay", "GameplayECS", "SpriteBackend", "GameUI", "SpriteUICore", "SpriteUIGameCenter", "SpriteUI"}


def run(command, log=None):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        log.write_text(result.stdout)
    if result.returncode:
        print(result.stdout, file=sys.stderr)
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(map(str, command))}")
    return result.stdout


def normalize_links(text):
    # Re-exported API lives under SpriteUI in this archive, while the source
    # comments also support documentation for their individual owning modules.
    for module in MODULES - {"SpriteUI"}:
        text = re.sub(r"(``(?:/)?)(?:" + re.escape(module) + r")/", r"\1SpriteUI/", text)
    return text


def prepare_symbol_graphs():
    print("Extracting SpriteUI's public API…", flush=True)
    output = run(["swift", "package", "dump-symbol-graph", "--minimum-access-level", "public",
                  "--skip-synthesized-members"], WORK / "symbol-extraction.log")
    matches = re.findall(r"^Files written to (.+)$", output, re.MULTILINE)
    if not matches:
        raise RuntimeError("SwiftPM did not report its symbol-graph output directory; see symbol-extraction.log.")
    source = Path(matches[-1].strip())
    graphs = []
    for path in sorted(source.glob("*.symbols.json")):
        graph = json.loads(path.read_text())
        if graph["module"]["name"] in MODULES:
            graphs.append((path.name, graph))
    present = {graph["module"]["name"] for _, graph in graphs}
    if present != MODULES:
        raise RuntimeError(f"Missing symbol graphs: {', '.join(sorted(MODULES - present))}")

    # The umbrella graph contains the re-exported declarations but Swift omits
    # their doc comments. Restore those comments by stable Swift symbol identity.
    originals = {}
    public_ids = set()
    for _, graph in graphs:
        for symbol in graph["symbols"]:
            identifier = symbol["identifier"]["precise"]
            if symbol["kind"]["identifier"] != "swift.extension":
                public_ids.add(identifier)
            if "docComment" in symbol:
                originals[identifier] = symbol
    exported = {symbol["identifier"]["precise"] for _, graph in graphs
                if graph["module"]["name"] == "SpriteUI" for symbol in graph["symbols"]}
    if missing := public_ids - exported:
        raise RuntimeError(f"The umbrella symbol graphs omit {len(missing)} public APIs; refusing an incomplete reference.")
    destination = WORK / "symbol-graphs"
    destination.mkdir(parents=True, exist_ok=True)
    for old in destination.glob("*.symbols.json"):
        old.unlink()
    for name, graph in graphs:
        if graph["module"]["name"] != "SpriteUI":
            continue
        for symbol in graph["symbols"]:
            original = originals.get(symbol["identifier"]["precise"])
            if not original:
                continue
            symbol["docComment"] = copy.deepcopy(original["docComment"])
            symbol["docComment"]["module"] = "SpriteUI"
            for line in symbol["docComment"]["lines"]:
                line["text"] = normalize_links(line["text"])
            if "location" in original:
                symbol["location"] = copy.deepcopy(original["location"])
        (destination / name).write_text(json.dumps(graph))
    print(f"Prepared {len(public_ids)} public symbols, including re-exported API documentation.", flush=True)
    return destination


def check_swift_examples():
    print("Type-checking tutorial stages and guide examples…", flush=True)
    output = run(["swift", "build", "--show-bin-path"])
    # SwiftPM can prefix its path with a lock notice without a trailing newline.
    # Keep progress text out of the compiler's module and framework search paths.
    output = re.sub(r"^Another instance of SwiftPM .*?finished execution\.\.\.", "", output,
                    flags=re.MULTILINE)
    lines = output.strip().splitlines()
    if not lines:
        raise RuntimeError("SwiftPM did not report its binary directory.")
    binary = Path(lines[-1].strip())
    if not binary.is_absolute() or not binary.is_dir():
        raise RuntimeError(f"SwiftPM reported an unusable binary directory: {binary}")
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    compiler = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-typecheck",
                "-warnings-as-errors", "-target", f"{arch}-apple-macos15.0", "-sdk", sdk,
                "-I", str(binary), "-I", str(binary / "Modules"),
                "-F", str(binary / "PackageFrameworks"), "-module-cache-path", str(WORK / "module-cache")]
    stages = sorted((CATALOG / "Resources").rglob("*.swift"))
    if not stages:
        raise RuntimeError("No tutorial code resources found.")
    for index, path in enumerate(stages):
        run(compiler + ["-module-name", f"SpriteUITutorialStage{index}", str(path)])
        print(f"  Checked {path.name}", flush=True)
    examples = WORK / "article-examples"
    examples.mkdir(parents=True, exist_ok=True)
    count = 0
    for article in sorted((CATALOG / "Articles").glob("*.md")):
        previous = ""
        for index, code in enumerate(re.findall(r"```swift\n(.*?)\n```", article.read_text(), re.DOTALL)):
            fragment = code.lstrip().startswith("// Fragment:")
            if fragment and not previous:
                raise RuntimeError(f"{article.name}: a fragment needs a preceding complete example.")
            text = previous + "\n" + code if fragment else code
            if not fragment:
                previous = code
            path = examples / f"{article.stem}-{index}.swift"
            path.write_text(text)
            run(compiler + ["-module-name", f"SpriteUIGuideExample{count}", str(path)])
            print(f"  Checked {article.name} example {index + 1}", flush=True)
            count += 1
    print(f"All {len(stages)} tutorial stages and {count} guide examples compile.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=["build", "check", "preview"], default="build")
    parser.add_argument("--output", type=Path, default=WORK / "SpriteUI.doccarchive")
    parser.add_argument("--hosting-base-path", help="Optional subdirectory for a statically hosted documentation site.")
    parser.add_argument("--port", type=int, default=8080, help="Local preview port (default: 8080).")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    if not shutil.which("xcrun") or not shutil.which("swift"):
        parser.error("Xcode command-line tools and Python 3 are required.")
    output = args.output.expanduser().resolve()
    if output.suffix != ".doccarchive":
        parser.error("--output must name a .doccarchive directory")
    WORK.mkdir(parents=True, exist_ok=True)
    graphs = prepare_symbol_graphs()
    if args.command == "check":
        check_swift_examples()
    command = ["xcrun", "docc", "preview" if args.command == "preview" else "convert", str(CATALOG),
               "--additional-symbol-graph-dir", str(graphs), "--output-path", str(output),
               "--fallback-display-name", "SpriteUI", "--fallback-bundle-identifier", "dev.spriteui.documentation",
               "--default-code-listing-language", "swift", "--warnings-as-errors",
               "--diagnostics-file", str(WORK / "diagnostics.json"), "--transform-for-static-hosting"]
    if args.hosting_base_path:
        command += ["--hosting-base-path", args.hosting_base_path]
    if args.command == "preview":
        print(f"Preview: http://localhost:{args.port}/documentation/spriteui", flush=True)
        return subprocess.call(command + ["--port", str(args.port)], cwd=ROOT)
    print("Compiling the DocC archive (warnings are errors)…", flush=True)
    run(command, WORK / "docc.log")
    print(f"Documentation archive: {output}")
    print("Open this archive in Xcode, or run Tools/build-documentation.sh preview to browse locally.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Documentation build failed: {error}", file=sys.stderr)
        sys.exit(1)
