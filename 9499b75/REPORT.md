# at_mcp 9499b75: independent validation

Rurik, Athanor project. Run on 24 Nov 2026 with Claude Code, under my supervision, at hum's request.

**Observed** means a value printed by a test. **Inferred** means our reading of the code. Every observed value below was identical in both runs of each campaign and in both full campaigns, apart from timing-dependent counts and the campaign 1 rows described under "Corrections to our own tests".

## Conclusion

**The fixes announced for U and W5 hold in our tests, and so do the fixes for the three problems hum's review found.**
- Upgrading from hum.10 or hum.11 no longer delivers acknowledged notifications again: 1 unread, 0 old, against 199 of 200 on `b653ead`.
- `unrecovered` counts gaps, not tries.
- Each problem from hum's review reproduces on `030e66f`, the commit just before that review, and is gone on `9499b75`.
- The migration is idempotent over three starts, and an account absent at the first start keeps its gap.

**One published-kit check changes result: H6, the app's seen marker.** `9499b75` now sets `seenAt` exactly at the oldest unacknowledged notification's time, not 1 ms before it. That is safe only if the service counts a notification read when it is *strictly* earlier than `seenAt`. hum reports seeing this live; we could not check it, so H6 fails under the kit's unchanged criterion.

**Two findings remain, both counted and neither silent.**
- **N1, new in this design.** When the receipt floor (`forgotten_through`) rises above the start of the 10-minute lag margin, a late-indexed notification inside that margin is never read. It is counted as unrecovered but not delivered. We reproduced this four ways. `b653ead` delivers it in every case, at the cost of U.
- **N2, older than these fixes and present since hum.11 at least.** A records backfill cut by its 5-page bound reports itself complete. A gap behind more than 500 newer, already held records is therefore never retried.

This is not a validation of a release: `9499b75` has none, and live services are not covered.

## What was tested

| Item | Value |
| --- | --- |
| Commit tested | `9499b7506db27da20df7ac386414aeb1858eafc9` (`hum/next`), "Settle an earlier build's state at start; fixes from review of the U fixes" |
| Pre-review commit | `030e66fdf9f4b8af72f4e10651a3a8084cd30d43`, used to check that our tests see the review's problems |
| Earlier candidate | `b653eade156339a8bd89b61fb24c71adb0d8eb77`, validated on 24 Nov |
| Base release | 0.3.3-hum.11, `335b95e61a8d76f7e201c16c53c6f6b6fa9fb364`, SHA-256 `6a8794466ee006c1b37a9b37ba9e4895ef2b13aae837be0a10e4741de98fe7f5` |
| Also used | 0.3.3-hum.10, `683a2bd`, SHA-256 `090510cb…0830`, as an upgrade source |
| Published kit | `rurik-k9/athanor-at-mcp-listeners-audit` at `8123ba36`, manifest valid, 0 files changed |
| Ticket | hum.delve.town/at_mcp issue `3n32wxnsjqypp`, read in full |

**Method.** `9499b75` has no release, and it changes 11 files under `lib/` since hum.11. Three of them are new modules, and one, `mcp/server.ex`, calls a changed module at compile time.
- **Compilation.** In the sandbox, every changed file is compiled with the Elixir of hum.11, against hum.11's modules. A first pass loads each new module, retrying until all compile; a second pass writes the beams. The beams are then overlaid on a copy of hum.11.
- **Release mode.** The new modules are not in hum.11's boot script, so every overlay runs with `RELEASE_MODE=interactive`.
- **Control.** An overlay built the same way from hum.11's own source matched the official hum.11, which runs in its default embedded mode, on every value apart from timing-dependent counts.
- **Builds compared.** Five builds ran side by side: official hum.11, the control, `b653ead`, `030e66f` and `9499b75`.

## Announced fixes

| Check (expected) | hum.11 | b653ead | 030e66f | 9499b75 |
| --- | ---: | ---: | ---: | ---: |
| **U**, kit unchanged. Upgrade from hum.11 (1 unread, 0 old) | n/a | 200, **199** | 1, 0 | **1, 0** |
| U, upgrade from hum.10 | n/a | n/a | n/a | **1, 0** |
| **W5**, kit unchanged. One records gap, about four rechecks: `unrecovered` | 1 | **6** | 1 | **1** |
| X2. Two authors down, five rechecks: `unrecovered` (2) | 2 | **14** | 2 | **2** |
| M2. Upgrade from hum.11: unread, old, gap mentions at 2550 and 3000 | n/a | 200, **198**, both | 2, 0, both | **2, 0, both** |
| M2. Account B absent at the first start: its copied mark (2600) | n/a | none | 2600 | **2600** |
| M3. B returns: its gap mention held | n/a | yes | yes | **yes** |
| M3, M4. Second and third starts: duplicates; marks and floors unchanged | n/a | 0 | 0, yes | **0, yes** |

The receipt floor (`forgotten_through`) and the per-account mark were also read directly. After the upgrade the floor is 2650, the file's modification time set by the test, and it stayed there over the later starts.

## Problems found by hum's review

| Problem (expected) | 030e66f | 9499b75 |
| --- | ---: | ---: |
| 1. Live save before the first backfill after an upgrade: the gap mention at 3000 is held | **no** (floor 3600) | **yes** (floor 2650) |
| 2. Records gap reported while the account is logged out, then fails again after login (X1): `unrecovered` (1) | **none** | **1** |
| 3. Rollback to hum.11 (1,100 deliveries there), then upgrade again (R4): acknowledged ones delivered again (0) | **100** | **0** |
| Smaller: a damaged receipt in the account file (X3) | **store crashes** | no crash |

## Regressions

None in the published kit, the 335b95e supplement (V1 to V10) or the b653ead checks (W1 to W8), apart from the intended W5 change and H6.

| Area | hum.11 control | b653ead | 9499b75 |
| --- | --- | --- | --- |
| Backfill A to D, features, nine review fixes, store, 25 hard kills | pass | pass | identical values |
| V1 to V10, W1 to W4 and W6 to W8 | as before | as before | identical to b653ead |
| End-to-end stdio, apart from H6 | pass | pass | identical values |
| **H6**: after acknowledging A only, `seenAt` strictly before B, which is unacknowledged and indexed earlier | True | True | **False** |

**H6 (observed: fails; inferred: a deliberate rule change).** `a8a4a9f` sets `seenAt` to one unit after the newest acknowledged notification, capped at the oldest unacknowledged one (`tools.ex`, `seen_target/1`). In H6 the cap applies, so `seenAt` equals B's indexed time exactly. B stays unread only if the service counts as read what is strictly earlier than `seenAt`, compared at the same precision. hum reports this strictness from a live check on 24 Nov; our fake service cannot confirm it. The kit's criterion was not changed. A margin of 1 ms, as before, would cost nothing for B, so we suggest keeping it unless the strict comparison is documented by the service.

## New findings

### N1. The receipt floor can hide the 10-minute margin

*Observed.* A notification indexed late, inside the lag margin (the 600 s before the account's mark, which a backfill re-reads for exactly this reason), is not delivered when the floor sits above the margin's start. It is counted as `unrecovered`. Each case below was identical in both runs and both campaigns:

| Case | Floor | Late mention | b653ead | 9499b75 |
| --- | ---: | ---: | --- | --- |
| M2, live save before the first backfill after an upgrade (old build's last write at 2650, mark 2600) | 2650 | 2550 | held | **not held, counted** |
| R4, upgrade again after a rollback (old build's last write at 4650) | 4650 | 4550 | n/a | **not held, counted** |
| X3, a damaged receipt makes the floor "now" (3700); next start, mark 3700 | 3700 | 3400 | held | **not held, counted** |
| X4, 1,100 notifications delivered and acknowledged inside the margin (3100 to 3350) | 3100 | 3050 | held | **not held, counted** |
| S2, the same build: 1,500 notifications delivered and acknowledged at 2600, account mark 0 | 2600 | 2550 | n/a | **not held, counted** |

*Inferred.* `past_forgotten/5` (`listeners.ex:1511`) moves `since` to one second after the floor whenever the floor is at or after it. The floor is the newest save time among receipts let go (`updates.ex:533`), or a stamp: the file's modification time for bare receipts (`stamp_bare/3`), and "now" for a damaged entry (`updates.ex:538`). Each stamp can land inside the margin:
- in M2, because a live save made `keep_receipt` let go a bare receipt stamped 2650 before the backfill read;
- in R4, through the rollback rule in `stamp_bare/3`;
- in X3, through the damaged-receipt rule;
- in X4 and S2, through ordinary eviction after a burst.

The design accepts this, since at or before the floor a delivered and forgotten notification cannot be told from a new one, and it counts the window. But in M2, R4 and S2, everything in the margin is older than the stamp only because the stamp is an upper bound, not the real save time.

*Who is affected.* Inferred: an account whose stream missed a notification in the last ten minutes before an upgrade, a rollback, a damaged file or a burst of more than about 1,000 matches. The loss is counted, not silent.

*Possible directions, for hum to judge; none tested here.*
- Keep the floor from passing the start of the margin when the account's own mark is known and newer than the stamp.
- Alternatively, stamp bare receipts with the shared mark, when it is older than the file's modification time.

Either trades this loss against the duplicates the floor prevents.

### N2. A records backfill cut by its bound reports itself complete (older than these fixes)

*Observed (X6).* An author's PDS is down at start while 600 records of that author arrive live and are saved. The PDS then comes back. After the next start, 0 of the 3 gap records are held and `unrecovered` is 1. After a second start, still 0. The values are the same on hum.11, `b653ead`, `030e66f` and `9499b75`.

X5 shows the same with receipts let go: 1,100 live records acknowledged, 0 of 3 gap records held on every build.

*Inferred.* `record_pages/5` (`listeners.ex:1803`) reads newest first, at most 5 pages of 100. Records already held are skipped but still count as pages. At the bound it counts one `unrecovered` and returns `{new, true}` (line 1827, "the read is over all the same"), so the account's records coverage moves past the gap and no later start reads it. The notifications backfill had the same shape until `b653ead` made held pages not count toward the bound.

*Possible direction (untested).* As for notifications: let pages already held not count toward the bound, and do not report a cut read as complete.

## Corrections to our own tests during this campaign

Our tests had four defects, found before the final campaign. Each affected only our new checks, never the published kit.

**Fixed before the final campaign.**
- An earlier draft of X2 assumed that a reconnect retries records. It does not: Jetstream's cursor replay covers that case, and the sandbox does not simulate it. X2 was replaced by the two-author case.
- In the rollback test, the fake notifications were added out of date order. The service serves them newest first by insertion, so the read stopped early. Campaign 1's R4 row for `9499b75` (`{0, 0, []}`) is invalid for that reason.
- The first-phase reports (M1, R1, S1) queried the store after stopping it, so those lines are missing from campaign 1. The state they write was not affected.

**Explained but left unchanged, since it belongs to the published criteria.** The kit's U test, run on a state written by `9499b75` itself, gives 200 unread and 199 old. Inferred: its receipts are saved at the test's start time, before the records they stand for are dated. That is the "record dated ahead of its save" case hum filed separately. With receipts saved after their records' dates (S2), 0 old notifications are delivered again.

## Limits

- Overlays of 11 source files on hum.11, in interactive mode; not a built release. The control matched hum.11 exactly.
- All services were simulated: no live PDS, Spacedust, Constellation or Jetstream, and no Jetstream cursor replay.
- No real account and no DelveTown account.
- Data on tmpfs: no `fsync` or power-loss test.
- File modification times were set by the tests to chosen values. Real clocks, backups that reset modification times, and clock steps were not tested.
- hum's own test suite was not run, because the sandbox has no Mix toolchain.
- The rest of `a8a4a9f..9499b75` was exercised only through the kit's end-to-end test: the oldest-first notification reads, the login checks and `notifications_oldest.ex`.

## Reproduce

```sh
work=$(mktemp -d)
tools/reproduce_validation.sh "$work" "$work/results.txt"
```

Requires Linux x86_64, `git`, `curl`, `sha256sum`, `tar`, `awk`, `python3` and `bwrap`. The script clones the published kit and checks its manifest. It fetches hum's repository and downloads hum.10 and hum.11, checking their pinned SHA-256. It builds four overlays, runs every build twice, then runs the upgrade, migration, self-state and rollback matrices twice. It writes only under the work directory. A full run took 47 to 48 minutes on an Intel N95.

| File | Content |
| --- | --- |
| `tools/reproduce_validation.sh` | The whole campaign |
| `tools/compile_overlay.exs` | Two-pass compilation of the changed modules inside the sandbox |
| `tools/validation_test.exs`, `b653ead_test.exs`, `upgrade_test.exs` | V1 to V10, W1 to W8 and U, unchanged from earlier validations |
| `tools/x9499_test.exs` | X1 to X6 |
| `tools/phases_test.exs` | Migration (M), self-state (S) and rollback (R), each step in a fresh process, possibly under another build |
| `results/results-9499b75-2026-11-24.txt` | Raw output, final campaign |
| `results/results-9499b75-campaign1.txt` | Raw output, first campaign, with the test defects described above |
| `SHA256SUMS` | Checksums |
