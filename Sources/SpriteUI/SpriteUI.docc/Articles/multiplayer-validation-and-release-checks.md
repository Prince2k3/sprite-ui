# Multiplayer validation and release checks

Collect reproducible local evidence, then verify native Game Center behavior separately with signed accounts.

## Run the local gate

From the repository root, run `python3 -B Tools/check-multiplayer-release.py`. The default selection exercises network sessions, recovery, movement, interactions, interest management, Game Center preview services, and the integrated DemoBots co-op round. It also runs the Python tool tests. Use `--full-tests --documentation` for the complete package suite and strict DocC compilation.

The tool writes fresh command logs and a JSON report under `.build/multiplayer-validation/`. A zero exit means the requested **local** checks passed. Missing test summaries, an empty Swift selection, command failure, or timeout fails the check. The report records the checkout revision and whether the working tree was dirty. It never authenticates, matches players, changes provisioning, or modifies Apple account settings.

After building DemoBots for the Duo simulator and Mac, optionally pass `--ios-app /path/to/DemoBots.app --macos-app /path/to/DemoBotsMac.app`. These checks compare bundle IDs and inspect the supplied entitlement templates. Their source is explicitly **unverified against the signed bundle**. Omit an app option when that artifact is unavailable; an omitted bundle has no recorded bundle evidence. The report does not claim that it built either app. Build failures must be resolved separately.

`Tools/check-game-center-setup.py` can inspect entitlements extracted from an actually signed app instead. Even that read-only check does not verify signature authenticity, provisioning, or App Store Connect state. See <doc:game-center-services> for the setup contract.

## Exercise the combined game under adverse delivery

Open DemoBots → Co-op Debug Arena, or use the asset-free host in <doc:demobots-cooperative-multiplayer>. Local co-op uses two independent service coordinators and worlds. Set Delay to a nonzero one-way delay, enable Vary packet delay, and raise Unreliable loss. These controls affect future local fixture sends only. Reliable lobby, membership, recovery, commands, and receipts retain delivery/order; unreliable movement and poses can be lost. This is not a model of every real-world network failure.

GameCenterPartyPreview accepts an optional delay, loss rate, and seed, exposes bounded pending packet/byte counts, and keeps the zero-delay default compatible with existing callers. Its controlled clock must advance even during preparation: preview matchmaking, handoff, and recovery deadlines share that clock, so an unrelated blocked renderer does not expire a paused fixture. Native Game Center deadlines retain elapsed wall-time behavior. DemoBots waits for readiness and the exact recovery offer rather than assuming a fixed number of zero-time flushes. Cancellation still stops that wait.

The local regression coverage includes:

- Per-player scope entry/exit, forced owned actors/ancestors, reliable membership, stale pose-base rejection, and atomic malformed-frame validation.
- Independent entity-byte credits, priority/aging, small-packet packing, loss repair for the last stationary pose, and bounded queues during repeated scope changes.
- Activity readiness and baseline handoff into separate worlds, prediction convergence, historical beam validation, cooldowns, and one authoritative shared score.
- Approved recovery into fresh worlds/epochs with old held input and pending actions cleared, plus cancellation during delayed preparation.
- Input cancellation and re-arming, explicit teardown, and the client handshake gate before it can issue shots.

These are bounded deterministic scenarios, not measured Internet latency guarantees. The entity budget applies to entity replication; application/control lanes have their own limits and are reported separately. Membership snapshots and recovery payloads must fit the documented packet/archive limits. Oversized state fails explicitly; there is no implicit snapshot chunking or asset streaming. Scope is a publication policy, not a security boundary. See <doc:replication-interest-and-bandwidth> and <doc:multiplayer-interactions-and-lag-compensation>.

## Prepare signing without inventing an identity

The DemoBots XcodeGen project supplies `App/DemoBots-iOS.entitlements` for device builds and `App/DemoBots-macOS.entitlements` for the Mac target. The Mac template includes sandbox client/server networking. Simulator builds do not require the iOS Game Center entitlement. These files mirror the setup templates under `Tools/templates/`.

Select a real development team, matching bundle identifiers and profiles, and enable the corresponding capabilities in Xcode and the developer portal. The example does not select a team. Its Mac target keeps signing disabled by default for local builds; explicitly enable signing when preparing the signed validation build. Configure the `dev.spriteui.demobots.coop` two-player activity and intended version/platform compatibility in App Store Connect. An entitlement file alone cannot perform those steps.

## Use the DemoBots local GameKit setup

DemoBots includes a Debug-only Game Center Test Lab alongside the campaign and co-op arena. The default preview exercises achievement progress, best-score submission, explicit activity lifecycle/entry acceptance, and separate challenge attempts without accounts. Opening or switching modes never authenticates or reports campaign progress. Closing cancels outstanding operations and releases the service facade.

The example's `App/DemoBotsLocal.gamekit` defines First Repair, Repair Score, Repair Test, the two-player co-op activity, and Repair Challenge linked to Repair Score. IDs are shared with the test model. Placeholder images are opaque RGB at the dimensions required by Xcode's activity/challenge editor. The local bundle is excluded from Release app resources.

Choose the shared DemoBots Local Game Center or DemoBotsMac Local Game Center scheme for Apple's local tools. These schemes enable GameKit Debug Mode and open the test lab with native GameKit selected. Sign in and choose each operation explicitly. The normal schemes keep this flag off. XcodeGen's post-generation helper preserves the distinction. Use Debug → GameKit → Manage Game Progress with a supported physical device to inspect/reset progress and exercise Repair Test entry points; consult Apple's [configuration guide](https://developer.apple.com/documentation/gamekit/initializing-and-configuring-game-center).

Run `python3 Examples/DemoBots/Tools/check-game-center-testing.py` to verify the sample IDs, challenge relationship, party counts, local artwork, Release exclusions, and shared scheme flags. Reopen the lab after resetting an achievement externally because the service wrapper deliberately retains monotonic known progress. The reusable SDK API is unchanged; this configuration belongs to the consuming app. Actual Game Progress Manager execution and signed two-account delivery remain pending.

## Keep the native gate pending until observed

This checkout's native two-account testing remains **pending**, at the user's request. Every generated local report keeps `native_testing.status` as pending and `release_ready` as false. There is no flag that promotes local fixtures into native evidence.

Record the signed app revisions, OS/platforms, account pair, steps, and observed results for each native check:

| Native check | Required observations | Current status |
| --- | --- | --- |
| Signing and accounts | Valid signatures/profiles/capabilities, intended app records, two distinct Game Center accounts | Pending |
| Party entry | Same-code matchmaking; configured cold/warm activity invitations; intended iOS/macOS compatibility | Pending |
| Complete round | Both players move/shoot; final receipts and shared cures/score agree; both see round completion | Pending |
| Recovery | Save, interrupt/background, fresh same-roster match, exact offer approval, baseline gates, neutral input | Pending |
| Account/peer changes | Sign-out/account change or peer loss during setup/play stops gameplay; deliberate retry creates no stale effects | Pending |

A Duo simulator check can verify folding, local background cleanup, controls, and the preview round. It cannot establish successful signed two-account Game Center transport. Retain that distinction when deciding whether to ship. See <doc:activity-party-matchmaking-and-handoff> and <doc:multiplayer-recovery-and-rejoining>.
