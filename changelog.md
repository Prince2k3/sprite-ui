---
title: SpriteUI Changelog
tags: [spriteui, releases]
created: 2026-11-25
updated: 2026-11-25
status: active
type: permanent
---

# Changelog

## 0.5.0 — 2026-11-25

The first tagged release of SpriteUI: a RealityKit-style API for 2D games,
backed by SpriteKit and hosted in SwiftUI.

### Engine

- Entity hierarchies, relative transforms, activation, prefabs, cloning, pooling,
  and managed scene transitions.
- Scheduled systems, typed events, fixed-step simulation, render interpolation,
  input recording and replay, and component snapshots.
- Sprites, text, shapes, materials, resources, animation, cameras, tile maps,
  particles, audio, split-screen viewports, and SwiftUI attachments.
- Collision queries, physics bodies, character controllers, joints, constraints,
  and direct entity manipulation.
- Input actions, rebinding, local-player device ownership, controller feedback,
  adaptive surfaces, and optional Duo hinge input.
- Bounded opt-in profiling, per-system and query timings, replication traffic,
  workload counts, JSON capture export, and Instruments signposts.

### Optional products and examples

- `Gameplay` supplies standalone agents, goals, navigation, spatial indexes,
  random generators, noise, decisions, state machines, strategists, quests, and leagues.
- `SpriteUIGameCenter` provides optional services, matchmaking, activities,
  challenges, and multiplayer session integration.
- `SpriteUISaves` provides typed player profiles, local persistence, wallet
  transactions, and optional cloud-save integration.
- Transport-independent replication includes interest management, bandwidth
  budgets, recovery, kinematic prediction, and validated historical interactions.
- DocC guides and tutorials with a GitHub Pages deployment workflow, a feature
  showcase, and the DemoBots example game.

### Compatibility and limitations

- Package language mode: Swift 6. Verified build toolchain: Xcode 27.2.
  The source uses newer SDK APIs; an older Xcode is not a supported build toolchain.
- Deployment targets: iOS 18 and macOS 15. Newer platform features are availability-gated.
- This is a pre-1.0 release. Public APIs and persisted/network formats may change
  in future minor releases; pin `0.5.0` when reproducible integration is needed.
- Signed two-account Game Center delivery and multi-device cloud-save validation
  remain pending. Native service integrations are experimental; local previews
  do not establish live-service compatibility. Native challenge definitions
  require Apple-side configuration and approval.
- Native SpriteKit physics is not deterministic rollback simulation. Profiling
  uses callback elapsed time, not GPU timing; exact draw-call and live-particle
  counts are unavailable.

For installation and product selection, see [[readme]]. For verification and
tagging, see [[releasing]]. Apple-derived DemoBots material retains its separate
license at `Examples/DemoBots/APPLE-LICENSE.txt`; the library uses MIT.
