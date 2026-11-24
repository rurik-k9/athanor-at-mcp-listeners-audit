# at_mcp b653ead: independent validation

Rurik, Athanor project. Run on 24 Nov 2026 with Claude Code, under my supervision.

**Observed** means a value printed by a test. **Inferred** means our reading of the code. Every observed value below was the same in three full campaigns, each running every scenario twice, apart from timing-dependent counts.

## Conclusion

**All three fixes announced in `b653ead` hold in the tested scenarios.** The cut notifications backfill is now counted and retried past what it already holds, each account keeps its own live mark, and a failed records backfill is retried in-process. We saw no regression in the published kit or in the earlier supplementary checks.

**One new loss-free but user-visible defect appears with `b653ead`. It affects anyone upgrading.** When an account has no live mark of its own, its first start delivers again, as unread, notifications that were already acknowledged and are older than the receipts window. That is always the case for state written by hum.10 or `335b95e`. In our test, 199 of the 200 unread updates after the upgrade were old. This happens on the upgrade path only; it is not a regression of an existing scenario. We suggest fixing it before the release, or documenting it.

This is not a validation of a release: `b653ead` has none, and live services are not covered.

## What was tested

| Item | Value |
| --- | --- |
| Commit tested | `b653eade156339a8bd89b61fb24c71adb0d8eb77` (`hum/next`, "Per-account live marks; retry what a backfill missed") |
| Previous candidate | `335b95e61a8d76f7e201c16c53c6f6b6fa9fb364`, validated on 23 Nov |
| Base release | 0.3.3-hum.10, `683a2bd226ee3bacd00af8d4d025017052040e12`, SHA-256 `090510cbfa24c96e259c5d1b16d52f3ab3d95de148085b56f3ae8f02fd3d0830` |
| Published kit | `rurik-k9/athanor-at-mcp-listeners-audit` at `8123ba36ba86e3abe470d611975ce1097b78955b`, manifest valid, 0 files changed |
| `listeners.ex` beam from `b653ead` | SHA-256 prefix `769f42204658a064`, identical in both campaigns |

Between `335b95e` and `b653ead`, the only change under `lib/` is `listeners.ex`; `repos.ex` is unchanged (identical beam). As for `335b95e`, the two modules were compiled inside the sandbox with the Elixir from the hum.10 release, then overlaid on a copy of that release.

**Method control.** The same overlay built from hum.10's own source (`683a2bd`) matched the official hum.10 on every value, apart from timing-dependent counts. Four builds ran side by side: official hum.10, the control overlay, `335b95e`, and `b653ead`.

`hum/next` has moved since `b653ead` (for example `3237c2f`, "safe-seen"). Those later commits were not tested.

## The three fixes

| Check (expected) | hum.10 | 335b95e | b653ead | Status |
| --- | ---: | ---: | ---: | --- |
| **1. Cut notifications backfill (V4).** 300 mentions, 5-page bound: held / `unrecovered` / held after restart | 250 / none / 250 | 250 / none / 250 | 250 / **1** / **300** | **Fixed** |
| 1. 600 mentions, three starts (W2): held after each, duplicates (250, 500, 600, 0) | 250, 250, 250 | 250, 250, 250 | **250, 500, 600**, 0 | **Fixed** |
| 1. Account mark while cut, then after full recovery (held, 3800) | n/a | n/a | held at start, **3800** | **Fixed** |
| 1. 400 mentions, no restart, recheck every 0.6 s (W3): held, duplicates (400, 0) | 250 | 250 | **400**, 0 | **Fixed** |
| **2. One account absent from a run (V5).** B's gap held (1) | 0 | 0 | **1** | **Fixed** |
| 2. Marks of A and B after that run, then after B returns (W4) | n/a | n/a | A 3600, B held; then 3700, 3700 | **Fixed** |
| **3. Records backfill fails, PDS returns, no restart (V10).** Held (4) | 1 | 1 | **4** | **Fixed** |
| 3. PDS down for about four rechecks, then back (W5): held, duplicates (4, 0) | 1 | 1 | **4**, 0 | **Fixed** |

Times are seconds after the test's origin. "n/a" means the build has no per-account mark.

## Regressions

None observed.

| Area | 335b95e | b653ead |
| --- | --- | --- |
| Published kit: backfill A to D, features, nine review fixes, store, end-to-end stdio | pass | identical values |
| A, B, R4, large R4, repeated R4, `listRecords` counted (validated on 23 Nov) | pass | pass |
| Failed first backfill, account mark (W1): mark held, 1 recovered, then 3700 | n/a | as expected |
| Two healthy accounts, two starts (W8): 1 each, no duplicate, both marks 3700 | n/a | as expected |
| Commit before ack, SIGKILL of the consumer or of at_mcp | no loss, no duplicate | same |
| 25 hard kills during writes: missing / duplicated | 0 / 0 | 0 / 0 |

**Expected changes, not regressions.** In checks V1, V3 and V6, the shared mark `listeners_live` now moves while a backfill is held (3600 instead of 0). This matches the new design: that mark only reports when the stream was last live, and no backfill reads it. The per-account marks behave as the old shared mark was meant to (W1, W2, W4, W7).

## New anomaly

**U. On upgrade, already acknowledged notifications are delivered again.**

*Observed.* Phase 1 writes the state that an earlier build leaves behind for a long-lived account. The built-in listener exists, 1,500 mentions were delivered and acknowledged earlier (their receipts were committed oldest first, as in the kit's H3), and the shared live mark sits 1,000 s before the restart. There is no per-account mark. Phase 2 adds one mention in the gap and starts. Values were the same in both campaigns:

| State written by, then started by | Unread after start | Already acknowledged among them | New gap mention held |
| --- | ---: | ---: | --- |
| 335b95e, then 335b95e (control) | 1 | 0 | yes |
| hum.10, then hum.10 (control) | 1 | 0 | yes |
| **hum.10, then b653ead** | **200** | **199** | yes |
| **335b95e, then b653ead** | **200** | **199** | yes |
| b653ead, then b653ead | 200 | 199 | yes |

No mention is lost: the gap mention is held in every case. The cost is a burst of old updates, presented as unread and new, capped by the listener's count bound (200 for the built-in listener).

The last row shows the same effect without any upgrade. In phase 1 the account's first backfill was cut, so it never got a mark of its own, and the next start reached back again.

*Inferred.* In `backfill/2` (`listeners.ex`, about line 1380), `horizon` comes only from `listeners_live:<did>`. When that is missing, `since` falls back to the listener's start (lines 1414 and 1448). With `new?`, pages that are already held don't count toward the bound, so the read goes on (up to 50 reads) past the newest 1,000 receipts. `Updates` keeps at least 1,000 receipts per listener (`@min_receipts`), or four times the count bound. Acknowledged notifications older than that window are no longer recognized. The kit's store check 8, "acked record re-offered after 1000 newer", already shows this limit. `b653ead` makes it reachable on a normal start.

*Who is affected.* Inferred: every existing installation on its first start after upgrading, for each account whose listener has seen more than about 1,000 matching notifications since it began. Afterwards, any account whose own mark is absent or held, for example after a cut first backfill. The receipts here were committed directly instead of being produced by a real delivery history. That is the kit's established technique, but it is one difference from a live account.

*Possible directions, for hum to judge. Neither was implemented or tested here, and their effect is not demonstrated.*
- On a start where an account has no mark of its own, seed it once from the shared `listeners_live` mark when that mark exists. Earlier builds used that mark, so it may limit the first start after an upgrade to the same reach as before. It is a lead, not a verified fix: it would not cover an account whose first backfill is cut (the last row above), and its interaction with the per-account fixes is untested.
- Separately, stop a backfill's read once a full page lies entirely beyond the oldest receipt the listener still holds, instead of only after 50 reads.

## Minor observation

**`unrecovered` counts failed attempts, not gaps (W5).** With the PDS down through about four rechecks, one records gap was counted 6 times; on `335b95e`, which does not retry, it was counted once. Nothing is lost, and the gap is recovered once with no duplicate. If `unrecovered` is meant to count what is missing, a retry of the same gap should not add to it. If it is meant to count attempts, the documentation could say so.

## Still open from earlier reports

These were not retested as defects and are unchanged:
- `unrecovered` does not survive a restart (R6).
- An unread update dropped by a bound cannot be restored.
- The per-sender wake cap resets on restart.
- A quiet stream and a dead stream look the same.

## Limits

- `b653ead` was tested as a source overlay on hum.10, not as a built release.
- All services were simulated: no live PDS, Spacedust, Constellation or Jetstream, and no real Jetstream replay.
- No real account and no DelveTown account.
- Data on tmpfs: no `fsync` or power-loss test.
- hum's own test suite was not run, because the sandbox has no Mix toolchain.
- The upgrade test builds the earlier state with committed receipts, not a recorded history.

## Reproduce

```sh
work=$(mktemp -d)
tools/reproduce_validation.sh "$work" "$work/results.txt"
```

Requires Linux x86_64, `git`, `curl`, `sha256sum`, `tar`, `awk`, `python3` and `bwrap`. The script clones the published kit and checks its manifest. It fetches hum's repository and downloads hum.10, checking its pinned SHA-256. It builds three overlays, runs everything twice, and writes only under the work directory. A full run took 31 to 32 minutes on an Intel N95.

| File | Content |
| --- | --- |
| `tools/reproduce_validation.sh` | The whole campaign |
| `tools/compile_overlay.exs` | Compiles the two modules inside the sandbox |
| `tools/validation_test.exs` | V1 to V10, unchanged from the `335b95e` validation |
| `tools/b653ead_test.exs` | W1 to W8, checks of the per-account marks and retries |
| `tools/upgrade_test.exs` | U, state written by one build and started by another |
| `results/results-b653ead-2026-11-24.txt` | Raw output, final campaign, produced by these tools exactly |
| `results/results-b653ead-campaign1.txt`, `-campaign2.txt` | Earlier campaigns, same values. Campaign 1's upgrade step covered only 335b95e to b653ead; in both, the W2 line is cut at 260 characters by a longer label |
| `SHA256SUMS` | Checksums of the files above |
