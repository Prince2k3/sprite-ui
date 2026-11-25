# Check a multiplayer round before release

Two local windows can agree on a score while the real game still fails when a friend backgrounds their device. Test the actions players depend on: meet, move, fire, finish, leave, and resume. Then repeat the native flows with signed accounts.

Local checks make game rules and message handling repeatable. Signed-device checks establish that the configured Apple services work for those players. Keep the evidence for both.

## Play a round with delayed messages

Open DemoBots → Co-op Debug Arena and start local co-op. It uses independent player worlds and service coordinators. Set a nonzero Delay, enable Vary packet delay, and raise Unreliable loss.

Move, stop, and fire at a moving bot. Watch the local predicted player respond, then compare confirmed hits and shared score. Reliable lobby control, membership, commands, recovery, and receipts keep their delivery/order; unreliable movement results and poses may be lost. The controls affect future fixture sends, rather than simulating every Internet failure.

The useful questions are about the game:

- Does the lobby wait until both players have compatible content and are ready?
- Does movement settle on the host's position after input stops, even if the last pose was lost?
- Do a blocked shot, rapid firing, and a respawned target obey the host's rules?
- Do both players receive one shared result when the round ends?
- After saving and interrupting, does recovery use the approved checkpoint and wait for both baselines?
- Does backgrounding or closing clear held input and temporary effects before another round starts?

The preview clock must advance during preparation as well as play. Its matching, handoff, and recovery deadlines use that clock; native services use elapsed wall time. Let the bundled view own fixture updates instead of adding another pump. See <doc:demobots-cooperative-multiplayer> for the sample's code entry points.

## Run the repeatable local checks

From the repository root, run `python3 -B Tools/check-multiplayer-release.py`. The default selection covers sessions, recovery, movement, interactions, interest management, preview services, the combined DemoBots round, and Python tool tests. Use `--full-tests --documentation` when you need the full package suite and strict DocC compilation.

The tool writes logs and a JSON report under `.build/multiplayer-validation/`. A zero exit means the requested local checks passed. A failed command, timeout, empty Swift selection, or missing test summary fails the gate. It does not sign in or change Apple configuration.

Read failures in terms of the player action they threaten. Scope tests check whether a player receives the right actors and parents. Traffic tests check deferrals and repair of lost final poses. Recovery tests check fresh worlds and epochs, cleared old input, and the baseline gate. These are controlled cases, not measured Internet latency guarantees.

Entity budgets cover only entity traffic; commands and control messages have their own limits. Membership frames and recovery payloads must fit their packet/archive limits. Oversized state fails rather than being automatically split or streamed. Scope also does not protect secret component data. See <doc:replication-interest-and-bandwidth> before interpreting traffic numbers.

## Prepare the app that players will actually run

Use matching bundle identifiers, development team, provisioning, and enabled Game Center capabilities. The DemoBots iOS and macOS entitlement templates live under `Examples/DemoBots/App/`; the Mac template includes sandbox networking. Mac signing is disabled by default for local builds, so enable it for signed validation. Configure the `dev.spriteui.demobots.coop` two-player activity and intended platform/version compatibility in App Store Connect.

After building, the local gate can accept `--ios-app /path/to/DemoBots.app` and `--macos-app /path/to/DemoBotsMac.app`. These options inspect supplied artifacts and entitlement templates; they do not build them or verify the templates against signed bundles. An omitted artifact supplies no bundle evidence.

`Tools/check-game-center-setup.py` can inspect entitlements extracted from a signed app. Even that check cannot establish signature authenticity, remote provisioning, or App Store Connect readiness. See <doc:game-center-services> for setup.

## Use the sample's native test lab

DemoBots includes a Debug-only Game Center Test Lab. Its preview mode exercises achievement progress, best scores, activity entry and completion, and challenge attempts without accounts. Opening the lab does not authenticate or report campaign progress.

The DemoBots Local Game Center and DemoBotsMac Local Game Center schemes enable GameKit Debug Mode and select native GameKit in the lab. Sign in and choose operations there. On a supported physical device, use Debug → GameKit → Manage Game Progress to inspect/reset progress and exercise activity entry points. Apple's [configuration guide](https://developer.apple.com/documentation/gamekit/initializing-and-configuring-game-center) describes that workflow.

`App/DemoBotsLocal.gamekit` provides the sample definitions and is excluded from Release resources. Run `python3 Examples/DemoBots/Tools/check-game-center-testing.py` to check identifiers, challenge links, party counts, artwork, exclusions, and scheme flags. Bundled definitions and a successful ordinary leaderboard submission do not establish that a native challenge catalog loaded or consumed an attempt. Reopen the lab after externally resetting an achievement, since the wrapper retains known increasing progress.

## Record signed two-player observations

Signed two-account testing remains **pending** at the user's request. Generated local reports retain `native_testing.status` as pending and `release_ready` as false. Local fixture success cannot promote that status.

For each signed test, record the app revision, OS/platforms, account pair, steps, and observed result:

| Player flow | What to observe | Status |
| --- | --- | --- |
| Sign in | Intended app records, valid signing/capabilities, two distinct accounts, cancellation and retry | Pending |
| Join friends | Same-code matching, cold/warm invitations, intended iOS/macOS compatibility | Pending |
| Play and finish | Both move and shoot; cures, final receipts, score, and completion agree | Pending |
| Resume | Save, interrupt/background, fresh same-roster match, approved offer, baseline gates, neutral input | Pending |
| Lose a peer or change accounts | Gameplay stops during setup/play; a deliberate retry has no stale effects | Pending |

A simulator can check layouts, controls, and local cleanup. It cannot establish signed two-account transport. Native challenge reporting and the remaining Game Progress Manager checks also remain unverified; partial single-device checks do not establish release readiness.

When a recovery test fails, return to <doc:multiplayer-recovery-and-rejoining> and locate the last phase both players reached. When entry fails, use <doc:activity-party-matchmaking-and-handoff> to distinguish finding the roster, preparing content, readiness, and committing play.
