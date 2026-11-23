---
title: SpriteUI
tags: [spriteui, library, documentation]
created: 2026-11-23
updated: 2026-11-23
status: active
type: permanent
---

# SpriteUI

SpriteUI brings an entity-and-component API to 2D games, with SpriteKit rendering and a SwiftUI host. Add entities to a `GameView`, describe them with value components, and run frame logic in query-driven systems. The package supports iOS 18 and macOS 15 or later.

Import `SpriteUI` to use the complete library. Smaller products expose `ECSCore` and `Gameplay` separately. [[Package.swift]] defines the products; [[Sources/SpriteUI/SpriteUI.swift]] re-exports the library modules.

## Documentation and tutorials

The DocC catalog lives in [[Sources/SpriteUI/SpriteUI.docc/SpriteUI.md]]. It includes a getting-started guide, conceptual articles, the public API reference, and three hands-on tutorials covering your first scene, systems and input, and collision-aware agents.

With Xcode command-line tools and Python 3 installed, run from the repository root:

```sh
# Build a DocC archive and a static-hosting site.
Tools/build-documentation.sh

# Also type-check every tutorial stage and guide example in Swift 6.
Tools/build-documentation.sh check

# Rebuild on documentation edits and browse locally.
Tools/build-documentation.sh preview
```

Browse `http://localhost:8080/documentation/spriteui` during preview. Open `.build/documentation/SpriteUI.doccarchive` in Xcode to read the generated archive in its Documentation window. Stop preview with Control-C.

For a site hosted under a subdirectory, specify its base path:

```sh
Tools/build-documentation.sh build --hosting-base-path SpriteUI
```

You can change the output directory with `--output /path/to/SpriteUI.doccarchive` and the preview port with `--port 8081`. These commands build local files; publishing them is a separate step.

[[Tools/documentation.py]] extracts SwiftPM symbol graphs, restores source comments on the umbrella module's re-exported symbols, and verifies that all public APIs are present. It normalizes module-qualified documentation links for the single SpriteUI archive. DocC warnings fail the build, and generated graphs, logs, diagnostics, and archives stay under the ignored `.build/documentation/` directory. No documentation plugin or network dependency is added to the package.

## Working on the documentation

The catalog uses native [DocC markup](https://www.swift.org/documentation/docc/), including symbol links, articles, tutorial directives, images, and complete Swift code resources. Keep catalog page titles first, as required by DocC.

Edit articles under `Sources/SpriteUI/SpriteUI.docc/Articles/`, tutorials under `Tutorials/`, and their staged code and illustrations under `Resources/`. Every code stage is a complete view or scene implementation that can replace the preceding stage. Run `Tools/build-documentation.sh check` before committing documentation changes. The script checks links and tutorial structure, every standalone tutorial stage, and every Swift guide example (combining explicitly marked fragments with their preceding example); its diagnostic report is `.build/documentation/diagnostics.json`.

The new top-level `Tools/` folder contains documentation tooling. The `.docc` directory is documentation source for the SpriteUI target; it is not an app resource bundle. Existing source modules and example layouts remain in place.

## Examples and tests

- `Demo/SpriteUIDemo.xcodeproj` demonstrates the library's individual features.
- [[Examples/DemoBots/readme.md]] describes the complete DemoBots game for iOS and macOS.
- Run `swift test` for the package's test suites.
