---
title: Releasing SpriteUI
tags: [spriteui, releases, verification]
created: 2026-11-25
updated: 2026-11-25
status: active
type: permanent
---

# Releasing SpriteUI

All products in this package share one version. Keep the public overview in
[[readme]] and compatibility changes in [[changelog]]. The library is MIT-licensed;
retain the separate Apple license with DemoBots material.

## Verify a candidate

Use Xcode 27.2 or a compatible newer toolchain. From the repository root:

```sh
swift test
python3 -B -m unittest discover -s Tools/tests
Tools/build-documentation.sh check
git diff --check
```

Build a fresh consuming app against the candidate Git tag using an exact package
version. Verify both `SpriteUI` and `SpriteUICore`, including an iOS simulator
build and a macOS build. A local Git mirror can establish version resolution
before a remote repository exists; it does not verify remote access.

Exercise the example app on a simulator or device. Record native service checks
separately: offline tests do not complete signed two-account Game Center or
multi-device cloud-save validation. Keep unverified integrations marked experimental.

## Tag and publish

Commit only intended release files, then create an annotated semantic-version
tag, such as `git tag -a 0.5.0 -m "SpriteUI 0.5.0"`. Do not move a published tag.
SwiftPM reads the Git tag; there is no separate package-manifest version to update.

The repository remote is `git@github.com:Prince2k3/sprite-ui.git`; package consumers
can use `https://github.com/Prince2k3/sprite-ui.git`. Publishing the branch and tag
requires explicit authorization. Keep `api-consolidation.md` and
`game-center-testing.md` out of release commits.

## Publish documentation

The `.github/workflows/` directory contains the documentation build and GitHub
Pages deployment workflow. It checks all tutorial stages and guide examples on
the Xcode 27 runner, then generates a static DocC site with the repository's
hosting base path. Pull requests only build; successful `main` builds deploy.
Generated archives stay in `.build/` and Actions artifacts, outside Git history.

In repository **Settings → Pages**, select **GitHub Actions** as the source.
After pushing, inspect the Documentation workflow and its `github-pages`
environment. The expected public address is
`https://prince2k3.github.io/sprite-ui/documentation/spriteui/`. This site follows
`main`; it is not a separately hosted archive for every release tag. An existing
environment approval policy still applies.

## Organize learning content

The DocC catalog has a five-lesson introductory course under `Tutorials/`.
Task guides under `Articles/` explain features a game may need later; the API
reference is separate from the learning path. DemoBots is a sample app based on
Apple's example, not part of the course.

`Documentation/previous-tutorials/` preserves the former feature-specific lesson
prose outside the public catalog. Its runnable Swift stages remain in catalog
Resources and are still compiled. `Tools/documentation-redirects.json` maps old
public tutorial addresses to their replacement guides. The documentation builder
writes static redirects after conversion so existing web links keep working.
