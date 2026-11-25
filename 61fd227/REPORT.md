# at_mcp 61fd227: independent validation

Rurik, Athanor project. Run on 24 and 25 Nov 2026 with Claude Code, under my supervision, at hum's request.

**Observed** means a value printed by a test. **Inferred** means our reading of the code. Every observed value below was identical in both runs of each campaign and in both full campaigns, unless the text says otherwise. The exceptions are timing-dependent counts, and the proposal rows, which differ between campaigns by design (see "Our proposal").

## Conclusion

**The fixes for hum's second review hold.**
- **F1:** a record acknowledged under hum.11 comes back on `0497933` and stays out on `61fd227`.
- **F2:** 100 duplicates on `0497933`, none on `61fd227`.
- **F3:** a start crashes on `0497933` and succeeds on `61fd227`.
- **F4:** as documented, a cut read finished by the recheck is still counted.

**N2 is fixed.** A gap behind 1,200 held records and 600 new ones is read in full. 1,300 new records are read in one process with the recheck, or over three starts (501, 1,001, 1,301), with no duplicate. Beyond 50 reads (5,100 held records), the gap stays unread and is counted, as designed.

**No regression** in the published kit, the 335b95e supplement, or the b653ead and 9499b75 checks. That covers U, W5, the migration, restarts, absent accounts, rollbacks and hard kills. The only changes are those intended or explained below. The control overlay matched official hum.11.

**H6 holds in `ack_updates`** at every edge we tried: equal times, 1 ms apart either way, microsecond stamps, both acknowledged.

**New finding L1: the oldest-first read can loop for ever under a strict service.** Delvetown's read is strict, per the ticket and per `notifications_oldest.ex`. `seen_through` now stops one unit before the oldest unshown notification. When that notification is exactly one unit after the shown ones, nothing shown becomes read, and the next read shows the same notifications again.
- With one item per read, `61fd227` shows `n0` six times out of six.
- With two notifications at one time and a third 1 ms later, it never reaches the third.
- In a burst of 30 in 12 ms, it shows 55 items to reach 30.
- `9499b75`, which used the exact cap, reaches all of them under a strict service, but loses some under a non-strict one.

**N1.**
- **X3:** fixed when the damaged entry has a newer neighbour saved before the margin. When it is the newest entry, or its newer neighbour was saved inside the margin, the late notification is still lost and counted. Inferred: this is inherent to timing it by an upper bound.
- **M2:** stays the documented limit. It is wider than the live-save case: a first backfill after an upgrade that is cut also raises the floor, so the margin is never read on later starts.

**Our experimental proposal** (`tools/proposal.patch`) addresses both. Its M2 part protects receipts timed at an upgrade until the account's first backfill since then succeeds. The margin is then read on the first start, with or without a live save first, and on a later start after a cut. There were no duplicates, U did not come back, and the rollback, migration and self-state matrices did not change. Its second part extends an oldest-first page by one group whenever nothing shown would otherwise become read. No walk loops any more, under either kind of service; under a strict one, the newest shown notification can still be shown once more. It is an experiment for hum to judge, not a request.

This is not a validation of a release: `61fd227` has none, and live services are not covered.

## What was tested

| Item | Value |
| --- | --- |
| Commit tested | `61fd227dd51afa0884e6df2fc6d1534a33cf4711` (`hum/next`), "Fixes from the review of 16fa100..0497933; N1's upgrade case is a limit" |
| Pre-review commit | `0497933b298ac0edef24b5b94350aab2d8bbca02`, used to check that our tests see the second review's problems |
| Previous candidate | `9499b7506db27da20df7ac386414aeb1858eafc9`, validated on 24 Nov |
| Base release | 0.3.3-hum.11, `335b95e61a8d76f7e201c16c53c6f6b6fa9fb364`, SHA-256 `6a8794466ee006c1b37a9b37ba9e4895ef2b13aae837be0a10e4741de98fe7f5` |
| Also used | 0.3.3-hum.10, `683a2bd`, SHA-256 `090510cb…0830`, as an upgrade source |
| Published kit | `rurik-k9/athanor-at-mcp-listeners-audit` at `8123ba36`, manifest valid, 0 files changed |
| Ticket | hum.delve.town/at_mcp issue `3n32wxnsjqypp`, read in full, with its four comments |
| Also read | `git diff 9499b75 61fd227` (13 files) and `test/at_mcp/review_n_test.exs` |

**Method**, as for 9499b75.
- **Compilation.** The 11 `lib/` files that differ from hum.11 are compiled in the sandbox with hum.11's Elixir, in two passes. They are overlaid on a copy of hum.11 and run with `RELEASE_MODE=interactive`.
- **Control.** An overlay of hum.11's own source matched official hum.11 on all 229 result lines. The exceptions were one write timing (1 ms against 2 ms) and the number of writes reached before the hard kills.
- **Builds.** Six builds ran side by side: official hum.11, the control, `9499b75`, `0497933`, `61fd227`, and `61fd227` with our patch.
- **Runs.** Each build was run twice per campaign, with two full campaigns. There is also a supplement (`tools/supplement.sh`), run twice on the campaign-2 builds.
- **Sandbox.** bwrap, no network, a private `/tmp`, nothing under `/home`.

## Hum's second review (F1 to F4)

| Check (expected) | 0497933 | 61fd227 |
| --- | ---: | ---: |
| F1. A record acknowledged under hum.11, its receipt let go, comes back as a moderation drop; upgrade again: delivered again (no) | **yes** (floor 300) | **no** (floor 5000) |
| F2. Listener with count 200 raised to 300; rollback to hum.11, 100 receipts let go; upgrade again: delivered again (0) | **100** (no floor) | **0** (floor 2200) |
| F3 (Y6). A damaged receipt list for a listener the file no longer has, then a start | **crash** (`badmap`, `forgotten_through`) | **started**, 2 held |
| F4 (Y2). 1,300 new records after an outage, finished by the recheck: held, duplicates / `unrecovered` | 1,301, 0 / 1 | 1,301, 0 / 1 (counted, as documented) |

In both F1 and F2, the new mention made after the second upgrade is held on both builds.

## H6 and `seen_through` at their edges

### `ack_updates`, through the real `at_mcp-stdio` (`tools/e2e_h6x.py`)

The service is strict: a notification is read if it is earlier than `seenAt`. Columns: `seenAt` sent / B still unread / A now read.

| Case | 9499b75 | 61fd227 |
| --- | --- | --- |
| H6 (kit). Acknowledge A only, B unacknowledged and indexed earlier: `seenAt` before B | **False** | True |
| H7. A and B at the same time | `.000`, **False**, False | `.999` (1 ms before), True, False |
| H8. A 1 ms after B | `.000`, **False**, False | `.999`, True, False |
| H9. A 1 ms before B | `.001`, **False**, True | `.000` (A's own time), True, False |
| H10. B to the microsecond (`.000400`), A later | `.000400`, **False**, False | `.000399`, True, False |
| H11. Both acknowledged | `.002`, -, True | `.002`, -, True |

*Observed.* On `61fd227`, B always stays unread. In H7 and H9 the acknowledged A also stays unread at the service. In H7 that is unavoidable, because one `seenAt` cannot split equal times. In H9, a strict service would have allowed `seenAt` = B's time, which reads A and leaves B unread. That is the exact cap `9499b75` used. *Inferred:* for `ack_updates` this is only the service's unread state; at_mcp's own acknowledgements are unaffected.

### The oldest-first read (`AtMcp.NotificationsOldest.read`, a fake page)

| Case | 9499b75, 0497933 | 61fd227 |
| --- | --- | --- |
| Y5a. Two unread 1 ms apart, read one: `seen_through` | `05.001` | `05.000` (the shown one's own time) |
| Y5b. 2 ms apart | `05.001` | `05.001` |
| Y5c. Equal times: the group is not split | `05.001`, 2 shown | `05.001`, 2 shown |
| Y5d / Y5e. Microsecond stamps, mixed ms and µs | `.000401` / `.000400` | `.000400` / `.000399` |
| Y5g. `just_before` / `next_after`, ms and µs | absent on 9499b75 | `.999` / `.001`; `.000399` / `.000401` |

### L1. A walk of oldest-first reads loops under a strict service (new)

*Observed.* Each walk reads, acknowledges with the `seen_through` it got, and reads again (Y5h to Y5j in `x61fd_test.exs`, Z1 to Z6 in `z_walks_test.exs`). Cells: reads / items shown / distinct / all reached.

| Walk | Service | 9499b75 and 0497933 | 61fd227 | proposal |
| --- | --- | --- | --- | --- |
| Y5h / Z6. Three 1 ms apart, limit 1 | strict | n0, n1, n2 | **n0 ×6, never ends** | [n0 n1], [n1 n2] |
| Y5i. The same | not strict | n0, n2: **n1 lost** | n0, n1, n2 | [n0 n1], [n2] |
| Y5j. Three 2 ms apart, limit 1 | strict | n0, n1, n2 | n0, n1, n2 | n0, n1, n2 |
| Z1. Two at one time, a third 1 ms later, limit 1 | strict | 2 / 3 / 3 / yes | **6 / 12 / 2 / no** | 1 / 3 / 3 / yes |
| Z2. Ten 1 ms apart, limit 4 | strict | 3 / 10 / 10 / yes | 3 / 12 / 10 / yes | 3 / 12 / 10 / yes |
| Z3. The same | not strict | 2 / 8 / 8 / **no** | 3 / 10 / 10 / yes | 3 / 10 / 10 / yes |
| Z4. 30 in 12 ms (pairs at equal times), limit 5 | strict | 6 / 30 / 30 / yes | 11 / **55** / 30 / yes | 11 / 55 / 30 / yes |
| Z5. The same | not strict | 4 / 20 / 20 / **no** | 6 / 30 / 30 / yes | 6 / 30 / 30 / yes |

*Inferred.* `read/2` caps `seen_through` at `just_before(cap)`, `cap` being the oldest unshown notification (`notifications_oldest.ex:185` and `through/2` at `:308`). When `cap` is exactly one unit after the newest shown, `seen_through` is the newest shown's own time. A strict service then leaves it unread. If every shown notification sits at that time (one per page, or one group of equal times), nothing becomes read, and the next read starts from the same place. The same arithmetic applies to `cut/2` (`:275`). We did not test it.

*Who is affected.* Inferred: a reader of the oldest-first view whose page ends on a notification exactly one millisecond (or one microsecond, at that precision) before the next unshown one. With a page of one item, or a group of equal times, it never advances. With larger pages it shows the boundary notification again on every read.

*The trade-off.* The exact cap (`9499b75`) is right for a strict service and loses notifications under a non-strict one. One unit before (`61fd227`) is right for a non-strict service and loops under a strict one. Delvetown is strict.

## N2. Records backfill

| Check (expected) | hum.11, 9499b75 | 0497933, 61fd227 |
| --- | ---: | ---: |
| X6. PDS down, 600 live records saved, back, two restarts: gap held (3, 3) | 0, 0 | **3, 3** |
| Y4. 1,200 held newest, 600 made while stopped, a 3-record gap; recheck: held of 600 / of 3 / duplicates | 0 / 0 / 0 | **600 / 3 / 0** |
| Y2. 1,300 new records, one process with the recheck: held | 1 (hum.11), 501 | **1,301**, no duplicate |
| Y3. 1,300 new records, three starts, no recheck: held after each | 501, 501, 501 | **501, 1,001, 1,301**, no duplicate |
| R6b (kit features). After a restart: held (the kit's label expects the 150 past the bound to stay lost) | 501 | **651** (they are now read) |
| Y1. 5,100 held records (51 pages) in front of a 3-record gap: gap held / `unrecovered` | 0 / 1 | 0 / 1 (the 50-read bound, counted) |

*Y1's total held* is a timing count. It was 2,000 on most runs, but 1,880 and 1,933 on `61fd227` in campaign 1, and 501 on `0497933` in one run of each campaign. The supplement prints the count before and after the settle sleep (`y1_timing_test.exs`): the restart can come while the store is still taking the 5,100 live events. In the supplement, the 5-second read call timed out on `9499b75` (3 of 4 cases) and `0497933` (4 of 4), never on `61fd227` or the proposal. The gap and `unrecovered` values never changed.

## N1: X3 and M2

### X3, the damaged entry

The published X3 puts the damaged entry at the head of the list, the newest place. There `timed_receipts/2` has no newer neighbour, and the entry takes "now", 3700. The late mention at 3400 is then lost on all builds and counted: `{{true, true, nil, 3700}, false, 1}`. The supplement varies the place (`x3_place_test.exs`). The list holds receipts saved at 1900 and 3600, with mark 3600, and a mention at 3400 seen late. Cells: floor / mention at 3400 held.

| Damaged entry | 9499b75 | 61fd227 |
| --- | --- | --- |
| at the head (newest) | 3700 / no, counted | 3700 / no, counted |
| between the two | 3700 / no, counted | 3600 / no, counted |
| at the tail (oldest) | 3700 / no, counted | **1900 / yes** |

*Inferred.* The fix holds where the neighbour's time is older than the margin. Elsewhere the upper bound is inside the margin, so the loss is inherent to the rule. It stays counted, never silent.

### M2, late mentions across the margin on the first start after an upgrade from hum.11

Mentions are indexed late, every 50 s from 1950 to 2700. The margin starts at 2000, and hum.11's last write was at 2650. Cells: late mentions held at the first start / floor / unread at the next start, duplicates.

| Build | No live save first | Live save first |
| --- | --- | --- |
| 9499b75 | 2300–2700 / 2650 / 10, 0 | **2700 only** / 2650 / 3, 0 |
| 61fd227 | 2300–2700 / 2650 / 10, 0 | **2700 only** / 2650 / 3, 0 |
| proposal | 2300–2700 / none / **15, 0** | **2300–2700** / none / **16, 0** |

The migration matrix agrees. With a live save first, `61fd227` holds 3000 but not 2550. The proposal holds both, with no floor and no duplicate.

*Observed: a wider M2.* Without a live save, the first backfill is cut at five counted pages, so only 2300–2700 are read. The floor then stays at 2650, so no later start reads the rest of the margin (Q3: 10 unread on `9499b75` and `61fd227`). With the proposal, the next start reads it: 15 unread. By count, those are 2050–2250; 1950 and 2000 lie at or before the margin's start.

## Our proposal (`tools/proposal.patch`, 3 files, against 61fd227)

**M2 part**, in `updates.ex` and `listeners.ex`, identical in both campaigns.
- When `stamp_bare/3` times bare receipts at the first start after an upgrade (not after a rollback), it records `data["settling"][listener] = mtime`.
- While that is set, `keep_receipt/4` does not let go receipts saved at that stamp, up to twice the receipt limit. Past twice the limit, it falls back to 61fd227's rule.
- `Listeners.release_live/2`, reached when an account's backfill succeeds with what it found saved, calls the new `Updates.end_settling/2`, which removes `settling`.

So the stamp, an upper bound, cannot become the floor before the margin has been read once. After that, receipts are let go as before.

**Oldest-first part**, in `notifications_oldest.ex`, version 2. After `edge/2`, `advance/3` adds the next group of equal times while the oldest shown notification is not strictly before `just_before(cap)`. Fresh notifications are never shown. Version 1, used in campaign 1 and kept as `tools/proposal-v1.patch`, extended the page by at most twice the limit instead. It fixed Y5h but still looped on Z1. Version 2 fixes both.

| With the proposal | Result |
| --- | --- |
| U: upgrade from hum.10 / hum.11 (kit unchanged) | 1, 0 / 1, 0 |
| M2 sweep, migration with and without a live save | margin held, no floor, 0 duplicates (above) |
| Self-state S1, S2; rollback R1 to R4; F1, F2, F3 | identical to 61fd227 |
| Kit, V1 to V10, W1 to W8, X1 to X6, Y1 to Y4, Y6, hard kills | identical to 61fd227 |
| Y5 and Z walks | no loop under either service (table above); the page can hold one group more than `limit`. Y5e (ms then µs 0.4 ms later) shows 2 with version 1 and 1 with version 2, which extends only when needed |

*Costs and open points.*
- During one start after an upgrade, the file may hold up to twice the receipt limit.
- An account whose first backfill never succeeds keeps `settling` until one does.
- Under a strict service, the boundary notification can be shown once more, as on `61fd227`.
- A page may exceed `limit` by one group, which can bear on `cut/2`'s host bound.

## Regressions

None. Every value from the published kit (backfill A to D, features, the nine review fixes, store checks, 25 hard kills, end-to-end stdio), from V1 to V10, W1 to W8 and X1 to X4 is identical on `9499b75` and `61fd227`. The exceptions are the intended changes above: H6 to H11, X6, Y1 to Y6, R6b, and timings. The matrices also hold:

| Matrix | 61fd227 |
| --- | --- |
| U, hum.10 and hum.11 to 61fd227 | 1 unread, 0 old |
| W5, one records gap, about four rechecks: `unrecovered` / held | 1 / 4, 0 duplicates |
| Migration M1 to M4, account B absent at the first start | B's copied mark 2600, B's 3100 held after it returns, marks and floors unchanged over three starts |
| Self-state S1, S2 | as 9499b75 (S2: the 2550 mention after a burst stays counted, X4/S2 inherent) |
| Rollback R1 to R4 | as 9499b75: 0 acknowledged delivered again; 4550 late in the margin lost, counted |
| 25 hard kills | 0 missing, 0 duplicates on every build |

### X5: records dated after their receipts' save

*Observed.* In X5, 1,100 live records are acknowledged during an outage, with their receipts let go. After a restart, `0497933` and `61fd227` deliver 50 of them again: the 50 oldest, with `capped: 94`. `9499b75` delivers none. Run with the local clock past the records' own times (`x5_clock_test.exs`), every build delivers 0.

*Inferred.* X5's clock is frozen at the outage's start, and the records are dated 10 to 20 s after it. Their receipts are therefore saved "before" the records they stand for, and the floor, the newest such save time, is older than the records. `9499b75` never read that far, because held pages counted toward the bound. Now N2's fix reads past the held pages and reaches them. This is the case hum filed separately ("a record dated ahead of its save"). The same artefact explains the kit's U test run from a state written by the same build (200 unread, 199 old, on both `61fd227` and the proposal). A records author whose clock runs ahead could meet it live. A possible direction, untested: time a receipt as the later of its save time and its record's own date.

## Corrections to our own tests during this campaign

- **`e2e_h6x.py`.** A first draft did not clear the fake service's sockets between cases, so H7 to H11 read "not reached". A second draft dated A and B 30 s before each case's listener began, and they were treated as backfill. The final version dates each case from its own start, as the kit's H6 does. Only the final version is in the campaigns.
- **Y4.** The first version relied on backdated records. It was replaced before the campaigns.
- **F1's second phase.** In the first version, hum.11's start redelivered X as an ordinary update. The phase now starts only `Updates`, so X comes back only as a moderation drop, as in the review.
- **Campaign 2** was restarted once, a few minutes in, to carry the version 2 patch.

## Limits

- Overlays of 11 source files on hum.11, in interactive mode; not a built release. The control matched hum.11.
- All services were simulated: no live PDS, Spacedust, Constellation or Jetstream, and no cursor replay.
- The strictness of Delvetown's read is taken from the ticket and the code's documentation; we could not check it.
- No real account, data on tmpfs, modification times set by the tests.
- hum's own test suite was not run, because the sandbox has no Mix toolchain.
- `cut/2` and the interplay between `ack_updates` and the oldest-first read were not tested.

## Reproduce

```sh
work=$(mktemp -d)
tools/reproduce_validation.sh "$work" "$work/results.txt"
tools/supplement.sh "$work" "$work/supplement.txt"
```

Requires Linux x86_64, `git`, `curl`, `sha256sum`, `tar`, `awk`, `patch`, `python3` and `bwrap`. The script clones and checks the published kit. It fetches hum's repository and downloads hum.10 and hum.11, checking their pinned SHA-256. It builds five overlays plus the proposal, runs every build twice, then the matrices twice. It writes only under the work directory. A full campaign took 118 and 122 minutes on an Intel N95, and the supplement 8 minutes.

| File | Content |
| --- | --- |
| `tools/reproduce_validation.sh` | The whole campaign |
| `tools/supplement.sh` | Z walks, X5 clock, Y1 timing, X3 placement, on the campaign's builds |
| `tools/compile_overlay.exs` | Two-pass compilation in the sandbox |
| `tools/validation_test.exs`, `b653ead_test.exs`, `upgrade_test.exs`, `x9499_test.exs`, `phases_test.exs` | Earlier checks, unchanged |
| `tools/x61fd_test.exs` | Y1 to Y6 |
| `tools/phases61_test.exs` | M2 sweep (Q), F1, F2 phases |
| `tools/e2e_h6x.py` | H7 to H11 through the real `at_mcp-stdio` |
| `tools/z_walks_test.exs`, `x5_clock_test.exs`, `y1_timing_test.exs`, `x3_place_test.exs` | Supplement |
| `tools/proposal.patch` | Our experimental patch, version 2 |
| `tools/proposal-v1.patch` | Version 1, used for the proposal in campaign 1 |
| `results/results-61fd227-campaign1.txt`, `results-61fd227-campaign2.txt`, `supplement-61fd227.txt` | Raw output |
| `SHA256SUMS` | Checksums |
