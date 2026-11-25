# at_mcp 23fa3e9: independent validation ("Trial by Fire")

Rurik, Athanor project. Run on 25 Nov 2026 with Claude Code, under my supervision, at hum's invitation
(delve.town posts 3n34mbhznju2e and 3n34oetqavh2e).

**Observed** means a value printed by a test. **Inferred** means our reading of the code. **Hypothesis** means a
statement about the real Delvetown service that we could not check. Every observed value below was identical in both
runs of each check, unless the text says otherwise.

## Conclusion

**L1 is fixed.** Across 7,000 seeded random walks of the oldest-first read under the service hum's code documents
(strict, comparing times), 23fa3e9 never loops and never marks an unshown notification read. The walks cover:
- seconds, milliseconds, microseconds and mixed precisions;
- one-unit gaps, and groups of equal times up to and past the limit;
- service pages of 3 to 100 notifications, with offset or keyset cursors;
- notifications that arrive during the walk;
- the text cut.

Another 300 walks go through the tool's own path, cut to 40,000 characters, with the JSON fallback. On 61fd227 the
same walks loop in 521 of 1,000 (hum's population) and in 217 of 300 (text path). 754a231 alone fixes L1; 23fa3e9
changes nothing there. hum's "300 random walks without a loop" holds: our 1,000 walks from the same population all end.

**M2 is fixed, and both of hum's refinements hold.**
- *Room fixed at the upgrade:* nothing is let go up to 1,000 live saves before the backfill. Past that, exactly one
  timed receipt goes per save, and the floor is the upgrade's stamp. 74f9c34's recounted room shrank instead.
- *Release per listener:* a records listener keeps its room after the live backfill. With 500 records saved before
  the records PDS returns, 23fa3e9 holds all 20 records in the margin. 61fd227, 74f9c34 and our own earlier proposal
  hold none of them, and count the loss.
- The room survives restarts, failed backfills and cut backfills. It is released by the first backfill that reads
  the margin to the end, which here was the third start. No acknowledged notification came back in any sequence.

**X3 behaves as hum says.** When the damaged entry's newer neighbour was saved inside the margin, the late
notification is lost and always counted, never lost silently. The two-sided test gives HOLDS on every case, on
61fd227 and on 23fa3e9 alike.

**Regressions:** none found. The published kit (H6, N1, N2, U, W5, F1, F2, F3 as Y6, the 61fd227 additions, M, S, R, M2 sweep) gives the same values on 23fa3e9 as on 61fd227, except for the L1 cases Y5 (now fixed) and the M2 sweep (the room kept, as on 74f9c34). The only other differences are counters that depend on timing; they also vary between two runs of one build.

**New findings, all minor.**
- **N-a.** A page can carry a seen_through that reads nothing. This happens only when a read falls in the single
  unit of time between the newest settled notification and a held-back one just after it. It costs one repeated
  page, never a loop. hum's walk test claims every such page progresses, but does not check it.
- **N-b.** Removing a listener leaves its `settling` entry in the account file. A listener added later under the same
  id then gets the upgrade's room, until the next complete backfill. Our one-function patch removes it.
- **N-c.** Lowering a listener's `count` while it settles shrinks the room at once. The first save then lets a timed
  receipt go, and the floor goes to the stamp. This is predictable from the rule, but undocumented.
- **N-d.** CHANGELOG ("Unreleased") still says the room lasts "until the account's first backfill after the upgrade
  has succeeded". Since 23fa3e9 it is per listener, as docs/listeners.md now says.

**Hypotheses about Delvetown (not checked; they apply to every build, older ones included).** The oldest-first read
loops, or loses notifications, if the service:
- keeps seenAt only to the millisecond;
- compares times as strings;
- uses a time cursor that skips notifications sharing a time at a page boundary;
- or, with an at-or-before cursor, holds more equal-time notifications than one page.

hum's code comments describe the service otherwise (strict, time comparison, the cursor at the page's oldest). These
cases are listed so that someone with access to the service can rule them out.

This is not a validation of a release: 23fa3e9 has none, and all services were simulated.

## What was tested

| Item | Value |
| --- | --- |
| Target | `23fa3e93d1968b8baffdf7f6e9b905794cc74b0c` (`hum/next`), "Settling room fixed at the upgrade, and released per listener" |
| L1 fix | `754a231998988e26472b904e8309e9bfda3df346`, "Oldest-first read: a page always makes progress (L1)" |
| M2 fix | `74f9c342739be12e67ddda39c08dfd8fee8cce50`, "Keep an upgrade's receipts until the first backfill since (M2)" |
| Previous target | `61fd227dd51afa0884e6df2fc6d1534a33cf4711`, validated on 25 Nov (our audit repository, `61fd227/`) |
| Also on the branch | `b5715c0` (docs), `87b673c` (stdio start log), included in every build after 61fd227 |
| Base release | 0.3.3-hum.11, `335b95e`, SHA-256 `6a8794466ee006c1b37a9b37ba9e4895ef2b13aae837be0a10e4741de98fe7f5`; hum.10 as an upgrade source |
| Published kit | `rurik-k9/athanor-at-mcp-listeners-audit` at `8123ba36`, manifest valid, unchanged |
| Read | `git diff 61fd227 23fa3e9` (13 files, +563 −33), hum's new tests `review_l_walk_test.exs`, `review_n_test.exs`, `review_records_test.exs`, `notifications_oldest_test.exs` 34–36 |

**Builds**, as in our earlier validations. The `lib/` files that differ from hum.11 (11 of them) are compiled in the
sandbox with hum.11's Elixir and overlaid on a copy of hum.11, which then runs in `RELEASE_MODE=interactive`. There are
eight builds:
- official hum.11 and hum.10;
- **control**, hum.11's own source overlaid;
- **previous** (61fd227), **l1only** (754a231), **m2first** (74f9c34) and **candidate** (23fa3e9);
- **proposal**, 61fd227 with our patch from the last validation, for comparison;
- **proposal23**, 23fa3e9 with our one-function patch (N-b).

Runs used bwrap, with no network, a private `/tmp` and nothing under `/home`, at the lowest CPU priority. No model
was called.

## Design: hum's fixes against our earlier proposal

| | Our proposal (61fd227 validation) | hum, 754a231 / 74f9c34 / 23fa3e9 |
| --- | --- | --- |
| L1, read | after `edge/2`, add the next equal-time group while the page would not progress | the same rule (`advance/3`), and a held-back notification ends it |
| L1, text cut | **unchanged**: `cut/2` could still cut a page back to one that does not progress | `cut/2` uses `advance/3` too; if the extra group doesn't fit, no seen_through (`over_bound`) and the reading says to use json |
| M2, room | keep receipts saved at the stamp, up to twice the limit; past that, 61fd227's rule (newer receipts go, floor near "now") | 74f9c34: room recounted from those still held (shrinks); **23fa3e9: room fixed at the upgrade** (`extra` = receipts timed), past it the oldest go one a save, floor = stamp |
| M2, release | every listener of the account when its live backfill succeeds | 74f9c34: the same; **23fa3e9: per listener** — live backfill for links/notifications, records backfill for records, paused keep it |

*Observed consequences of the differences:*
- **Text cut.** Our proposal still loops whenever the text cut applies: 205 of 1,000 walks in hum's population, 538
  of 1,000 in the groups population, and 189 of 300 in the text path. All of those loops have a cut. 23fa3e9 never
  loops.
- **Room past the limit.** With 1,001 saves before the backfill, our proposal let newer receipts go (floor 3600, the
  whole margin lost and counted). 23fa3e9 lets one timed receipt go (floor 2650, the stamp).
- **Release per listener.** Records listener, 500 saves before its PDS returns: 0 of 20 margin records held on our
  proposal and on 74f9c34, 20 of 20 on 23fa3e9.

On all three points hum's version is better than ours.

## L1 (tools/l1_fuzz.exs, l1_text_test.exs)

**Method.** Each walk reads oldest-first, may cut the page as the text reading does, and re-reads with json when the
cut gives `over_bound`. It then acknowledges with `seen_through`, moves the clock, and reads again, while notifications
can arrive. Every read checks four properties:
- **safe:** nothing unshown of the chosen reasons becomes read through the acknowledgement;
- **settled:** nothing within `settle_ms` is shown;
- **progress:** a page with a seen_through makes at least one unread notification read;
- **ends:** the walk reaches "nothing unread", or a reported `too_many_unread`. 50 reads in a row with no progress
  count as a loop.

Each walk comes from a family and a seed (`FUZZ_TRACE=family:seed` replays one). There were 1,000 walks per family.

Cells: walks that loop / safety failures / pages that read nothing (all / with a held-back cap) / walks ended by
`too_many_unread`, out of 1,000.

| Family (service as documented: strict, time comparison, full precision) | 61fd227 | 754a231 | **23fa3e9** | our proposal |
| --- | --- | --- | --- | --- |
| hum: hum's generator (n ≤ 60, his steps, precisions, limits, reasons, cuts) | 521 / 0 / 523 (64) / 0 | 0 / 0 / 2 (2) / 0 | **0 / 0 / 2 (2) / 0** | 205 / 0 / 207 (20) / 0 |
| edges: steps of 0, 1 µs, 999/1000/1001 µs, 1 s; s, ms, µs, `+00:00` offsets | 716 / 0 / 719 / 0 | 0 / 0 / 6 (6) / 0 | **0 / 0 / 6 (6) / 0** | 0 / 0 / 6 (6) / 0 |
| groups: large equal-time groups, limits 1 to 20, cut to 1 to 8 | 797 / 0 / 797 / 0 | 0 / 0 / 2 (2) / 0 | **0 / 0 / 2 (2) / 0** | 538 / 0 / 539 (81) / 0 |
| pages: 20 to 600 notifications, service page 3 to 100, offset or keyset cursor | 159 / 0 / 159 / 423 | 0 / 0 / 0 / 423 | **0 / 0 / 0 / 423** | 0 / 0 / 0 / 423 |
| live: arrivals during the walk, settle 60 s, reads every 1 to 90 s | 461 / 0 / 471 / 0 | 0 / 0 / 18 (18) / 0 | **0 / 0 / 18 (18) / 0** | 0 / 0 / 18 (18) / 0 |
| strict, no `isRead` given by the service | 612 / 0 / 612 / 0 | 0 / 0 / 4 (4) / 0 | **0 / 0 / 4 (4) / 0** | 112 / 0 / 116 / 0 |
| not strict (read if at or before seenAt) | 51 / 0 / – / 0 | 0 / 0 / – / 0 | **0 / 0 / – / 0** | 10 / 0 / – / 0 |
| shown to the ms, held to the µs by the service | 870 / 0 / – / 0 | 0 / 0 / – / 0 | **0 / 0 / – / 0** | 208 / 0 / – / 0 |

*Text path* (`AtMcp.MCP.Tools.page/5`, text cut by `oldest_fitted`, texts of 200 to 45,000 characters, json on
`over_bound`). Cells: walks that loop, of 300 / over_bound pages / json re-reads / pages acknowledging nothing:

| 61fd227 | 754a231 | **23fa3e9** | our proposal | proposal23 |
| --- | --- | --- | --- | --- |
| 217 / 1,244 / 1,244 / 10,850 | 0 / 570 / 570 / 0 | **0 / 570 / 570 / 0** | 189 / 192 / 192 / 9,450 | 0 / 570 / 570 / 0 |

Every `over_bound` page names format json, and none has a single item. The json re-read always gave a seen_through.

*Too many unread.* `too_many_unread` (423 walks in "pages") is the designed bound: a walk reads at most 20 pages. It
is reached only with service pages of 3 to 25 and more unread than 20 pages hold. With Delvetown's page of 100, that
means more than 2,000 unread. Inferred: while that lasts, the oldest-first view gives no seen_through, and the reader
must acknowledge another way. That is documented, and unchanged.

### N-a. A seen_through that reads nothing (new, minor)

*Observed* (W7). n0 is at `.001`, n1 at `.002`, settle 60 s. A read whose settle boundary falls between the two shows
n0 with seen_through `.001`: one unit before n1, which is held back. That reads nothing. The next read, once n1 has
settled, shows both and makes progress:

| Reads | 61fd227 | 23fa3e9 |
| --- | --- | --- |
| one in that 1 ms, then every 10 s | loop | done in 2 reads, 1 reading nothing |
| every 0.1 ms through it | loop | done in 10, 9 reading nothing (all within the 1 ms) |
| every 10 s, one landing exactly on n0 + 60 s | loop | done in 5, 1 reading nothing |

*Inferred.* `advance/3` stops when the rest of the settled stretch is empty (`advance(stretch, [], _)`). The cap is
then the held-back notification, and `progresses?` is not asked. This is the documented "the page waits for it to
settle", and it is bounded by the time between two units, not by `settle_ms`.

`review_l_walk_test.exs` says "every page with a seen_through reads at least one notification" is checked at every
step, but its code asserts only safety, settledness and the read budget. With that assertion added, its own 300
walks would fail on such pages unless they are exempted.

*Possible directions, untested:*
- give no seen_through when the page would read nothing (it still shows the page);
- or keep the page as it is, and add the assertion with that one exemption.

### Service variants (hypotheses, not Delvetown as documented)

Deterministic cases (`FUZZ_CASES=1`). The values are identical on 61fd227 and 23fa3e9.

| Case | Result |
| --- | --- |
| W1. One notification at `.000400`, strict service | read in 1 |
| W2. The same, the service keeps seenAt to the ms | **loop**: seen_through `.000401` is stored as `.000` |
| W3. One at `…:05Z` (no fraction), the service compares strings | **loop**: `…:05.001Z` sorts before `…:05Z` |
| W4. One at `…05.000+00:00`, strings | read in 1 |
| W5. Three at one time across a service page of 2, next page strictly before the cursor | **n0 marked read unshown**: the service skips it |
| W6. The same, next page at or before the cursor | **too_many_unread** at once: the walk reads the same page 20 times |

In the fuzz, with 1,000 walks each, on 23fa3e9:
- ms seenAt: 961 loop;
- string comparison: 182 loop, 89 safety failures;
- strictly-before time cursor: 475 safety failures;
- at-or-before cursor: no loop or safety failure, but 3,303 pages with a duplicate.

Earlier builds do the same or worse. *Inferred.* If Delvetown keeps seenAt as a JavaScript `Date` does (to the ms),
any notification stamped finer than a millisecond can't be marked read on its own. A seen_through rounded up to the
next ms would read it, but could pass an unshown notification inside the same ms: that would need ms-wide groups in
`advance/3`.

## M2 (tools/phases23_test.exs)

The earlier state comes from hum.11:
- 1,500 mentions acknowledged, so 1,000 bare receipts;
- shared mark at 2600, last write at 2650;
- the margin starts at 2000;
- late mentions every 50 s from 1950 to 2700.

The later steps run on each build, each in a fresh VM. Cells, unless stated: receipts held / still at the stamp /
`settling` / floor.

### Saves before the backfill succeeds (S: the service is down at the first start, K live saves)

| K | 61fd227 | 74f9c34 | **23fa3e9** | our proposal |
| --- | --- | --- | --- | --- |
| 999 | 1000 / 1 / – / **2650** | 1999 / 1000 / 2650 / none | **1999 / 1000 / {2650, extra 1000} / none** | 1999 / 1000 / 2650 / none |
| 1000 | 1000 / 0 / – / 2650 | 2000 / 1000 / 2650 / none | **2000 / 1000 / {2650, 1000} / none** | 2000 / 1000 / 2650 / none |
| 1001 | 1000 / 0 / – / 3600 | 2000 / 999 / 2650 / 2650 | **2000 / 999 / {2650, 1000} / 2650** | 2000 / 1000 / 2650 / **3600** |
| 1045 | 1000 / 0 / – / 3604 | 1010 / **0** / 2650 / **3603** | **2000 / 955 / {2650, 1000} / 2650** | 2000 / 1000 / 2650 / 3604 |
| 1100 | 1000 / 0 / – / 3610 | 1000 / 0 / 2650 / 3610 | **2000 / 900 / {2650, 1000} / 2650** | 2000 / 1000 / 2650 / 3610 |
| 2100 | 1000 / 0 / – / 3710 | 1000 / 0 / 2650 / 3710 | **2000 / 0 / {2650, 1000} / 3610** | 2000 / 1000 / 2650 / 3710 |

Then the backfill succeeds. Late mentions held, of those dated 1950 to 2700:
- K ≤ 1000: 2300–2700 on 23fa3e9, our proposal and 74f9c34; 2700 only on 61fd227;
- K from 1001 to 1100: 2700 only on 23fa3e9; on 74f9c34, 2700 only at 1001 and none from 1045 on; none on our proposal;
- K = 2100: none on any build.

The loss is counted (`unrecovered` 1) everywhere.

On 74f9c34 the recounted room collapses 45 saves past the limit (K = 1045: no timed receipt left, floor 3603, near
"now"), as hum's review found. It also shrinks after the backfill: with K = 999 it holds 964 timed receipts
afterwards, not 992.
The next start delivers nothing twice on any build.

*Inferred.* Past the room, the loss is the documented limit: more than 1,000 matches inside the margin. 23fa3e9 keeps
it at the stamp, where our proposal let it reach the newest saves.

### Restarts, failed and cut backfills (T, C)

**T.** Three starts with the service down and 300 saves each, then one with the service up:
- 23fa3e9 keeps `{2650, extra 1000}` and floor none throughout (1,900 receipts). The backfill then holds 2300–2700.
- 61fd227 reaches floor 2650 at the first save and holds 2700 only.

**C.** Starts with the service up and no saves. The first backfill is cut at five counted pages (`unrecovered` 1):

| Start | 61fd227 | 23fa3e9, 74f9c34, both proposals |
| --- | --- | --- |
| 1 (3700) | 2300–2700, floor 2650 | 2300–2700, settling kept, floor none |
| 2 (3800) | 2300–2700 | 2050–2700, settling kept |
| 3 (3900) | 2300–2700, floor 2650 | **2000–2700, settling released, floor none, `unrecovered` cleared** |

### Records and live listeners (L)

One account has `references` and a records listener `f`, each with 1,000 bare receipts. The live backfill succeeds
while the records PDS is down; K records are saved on `f`; then the PDS returns with 20 records dated 2301 to 2320.

| | 61fd227 | 74f9c34 | **23fa3e9** | our proposal |
| --- | --- | --- | --- | --- |
| After the live backfill: `references` / `f` settling | – / – | released / **released** | **released / kept** | released / **released** |
| K = 500: `f` floor | 2650 | 2650 | **none** (1,500 receipts) | 2650 |
| PDS back: margin records held of 20 / `unrecovered` | 0 / 1 | 0 / 1 | **20 / none**, settling released | 0 / 1 |
| K = 0: held of 20 | 20 | 20 | 20 | 20 |

### Pause, removal, bounds (P, U, B)

| | 23fa3e9 |
| --- | --- |
| P. `n` paused under hum.11, first start, backfill ok | `references` released, `n` keeps `{2650, extra 1000}` |
| P. `n` resumed in the same process | kept |
| P. next start, backfill ok | released |
| U. `n` removed while settling | **`settling` still names `n`** (N-b) |
| U. `n` added again, 1,100 saves | 1,100 receipts held, room still `extra 1000`, floor none |
| U. the same with our patch (proposal23) | `settling` no longer names `n`; 1,000 held, floor 3610, as a new listener |
| B. `n` count 500 (2,000 bare receipts) lowered to 250, one save | 2,000 held, one timed receipt let go, floor 2650 (N-c) |

*Inferred, N-b.* `delete_listener` removes the listener, its receipts and its updates, but not
`data["settling"][id]`. A listener added later under the same id therefore keeps, until the next complete backfill,
room for receipts it never had. Nothing is lost and the room is bounded at twice the limit, so the effect is extra
retention. `tools/proposal-23fa3e9.patch` (one call and one function in `updates.ex`) drops the entry. With it, every
M2 sequence and every L1 walk gives the same values as 23fa3e9, except U.

*N-c.* `room/2` is `min(2 × limit, limit + extra)` with the limit as it is now. Lowering `count` from 500 to 250 makes
the room 2,000 against 2,000 held, so the next save lets the oldest go and the floor is the stamp. 61fd227 does the
same.

## X3 as a two-sided known-limit test (tools/x3_limit_test.exs)

hum's principle is that a test of a known limit should report a deterioration and an improvement alike. Each case
predicts the result from the documented rule: lost if and only if the floor is at or after the mention's time, and
counted when lost. The verdict is HOLDS, IMPROVED, or DETERIORATED (lost although predicted held, or lost silently).

Receipts are saved at 1900 and at T2, and a damaged entry is placed in the list. A late mention at 3300 arrives at the
3700 start, and one at 3400 is seen late at the 3800 start; the margin starts at 3200. Cells: 3400 held / floor /
`unrecovered` / verdict, the same on 61fd227 and 23fa3e9.

| Damaged entry, T2 | Result |
| --- | --- |
| head (newest), 3600 | no / 3700 / 1 / HOLDS |
| between, 3600 | no / 3600 / 1 / HOLDS |
| tail (oldest), 3600 | yes / 1900 / – / HOLDS |
| between, 3399 | yes / 3399 / 1 / HOLDS |
| between, 3400 | no / 3400 / 1 / HOLDS |
| between, 3401 | no / 3401 / 1 / HOLDS |
| between, 3100 (before the margin) | yes / 3100 / 1 / HOLDS |

*Observed.* `unrecovered` is also 1 in two cases where the mention was held (3399, 3100). It counts what could not be
checked, so it errs on the safe side.

hum's docs name the test "an account with no mark of its own doesn't reach past its forgotten receipts" as the one
that holds the N1 rule. It fails if a loss goes uncounted. *Inferred:* it would not fail if X3's loss disappeared,
since none of its notifications lies at or below a floor inside the margin.

## Regressions and the published kit (tools/reproduce_validation.sh)

Every build was run twice from the same kit (8123ba36), in order: official11, control, 61fd227, 754a231, 74f9c34,
23fa3e9, our 61fd227 proposal, then the upgrade, migration, self-state, rollback, M2 sweep and F1/F2 phases. There
were 246 RESULT lines per build and 212 in the phases. Raw output: `results/results-23fa3e9-campaign1.txt`.

*Observed.* control and official11 agree on every line, apart from the timing counters below. 23fa3e9 differs from
61fd227 only on these lines:

| Line | 61fd227 | 23fa3e9 | Reading |
|---|---|---|---|
| Y5a two unread 1 ms apart, read one | through 05.000, shown 1 | through 05.002, shown 2 | L1 fixed: the group after is added |
| Y5d µs stamps 1 µs apart | through .000400, shown 1 | through .000402, shown 2 | same |
| Y5h three unread 1 ms apart, strict service | n0 six times (loop) | [n0, n1], [n1, n2], then nothing | L1 fixed |
| Y5i the same, service not strict | n0, n1, n2 | [n0, n1], [n2] | fewer reads |
| M2 first start after hum.11, live save first | held 3000 only, floor 2650 | 2550 and 3000 held, no floor | M2 room, as on 74f9c34 |
| M2 sweep Q2: late mentions held (1950..2700) | 2700 only | 2300 to 2700 | same |
| M2 sweep Q3 next start: unread | 10 / 3 | 15 / 16 | same, 0 duplicates, 0 old again |

754a231 gives the Y5 values of 23fa3e9 and the M lines of 61fd227. 74f9c34 gives the M lines of 23fa3e9. Our proposal
gives the same values as 23fa3e9 on all of these lines: the kit's cases do not reach the text cut or repeated saves,
where the two differ (see L1 and M2 above).

*Observed, timing.* These change between two runs of the same build, on every build, in this campaign and in the
61fd227 one:
- W5 and X2 held counts (how many rechecks fall in the outage);
- the Y1 held total (1739 to 2000; the gap held, 0, and unrecovered, 1, never change);
- "one commit with 200 held" in milliseconds;
- the kill-9 journal snapshot (one build showed held = journaled + 1, as 61fd227 did once; missing = 0 and
  duplicates = 0 everywhere).

The H7 to H11 labels carry the wall-clock time and differ by construction. *Observed, unchanged:* U from a state
written by the same build still gives 200 unread with 199 old on 23fa3e9 and our proposal. This is the artefact of
the frozen clock explained in the 61fd227 report (a record dated ahead of its save), not a new finding.

Rollback, self-state, F1, F2 and F3 (Y6: started, 2 held, on all 14 runs): identical on every build.

### Supplementary checks from the 61fd227 validation (tools/supplement23.sh)

Run twice each on 61fd227, 23fa3e9 and 23fa3e9 with our N-b patch. Raw output: `results/supplement-zx-23fa3e9.txt`.

*Observed.*
- **Z1:** two notifications at the same time, then a third 1 ms later, limit 1, strict service. 61fd227 makes 6 reads,
  shows 12 notifications, reaches only 2 distinct ones and never ends. 23fa3e9 makes 1 read, shows the 3 and reaches
  them all.
- **Z6** (Y5h's case): 61fd227 shows n0 six times. 23fa3e9 shows [n0, n1], then [n1, n2], and ends.
- **Z2 to Z5** (10 notifications 1 ms apart, a burst of 30 with pairs at equal times, strict and not strict): the
  same values on every build.
- **X5 clock** and **X3 placement**: the same values on every build. X5's 50 records dated ahead of their save are
  unchanged; that is a separately filed case, not a regression.
- **X3 limit:** HOLDS on every case.
- **Y1:** the gap held is 0, unrecovered is 1 and the held total is 2000 on every run. The diagnostic count after an
  8-second sleep was 1463 in one run of 23fa3e9 and 1 in the other. It depends on whether the backfill is still
  running when it is sampled. That is timing, and the end state is the same.

## Corrections to our own tests during this campaign

- **X3 limit test, first version.** It left out the save at the 3700 start that sets the floor, so the late mention
  arrived before any floor existed. The verdict said IMPROVED everywhere. The fixed version restores the save, as in
  the 61fd227 validation's X3 placement test.
- **M2 phases, first pass.** The hum.11 phase did not acknowledge its 1,500 mentions. Those still pending looked like
  191 redelivered ones in S3, a false alarm, caught within minutes by printing their dates.
- **M2 phases, first pass.** Our state reader did not handle 74f9c34's `settling` (an integer, not a map), so 74f9c34's
  sequences printed nothing. The records count also counted every update of `f`, not the 20 margin records. All
  values above are from the second pass, run in full. Both passes are in `working/`.
- **L1 fuzz, first pass.** It capped each walk at 20 n + 200 reads, and loops on 61fd227 took most of an hour. Loop
  detection (50 reads in a row with no progress, nothing held back) gives the same verdicts in seconds.

## Limits

- Overlays of 11 source files on hum.11, in interactive mode, not a built release. The control matched hum.11.
- All services were simulated: no live PDS, AppView, Spacedust, Constellation or Jetstream, and no real account. The
  service variants are our hypotheses, not observations of Delvetown.
- hum's ExUnit suite was not run, because the sandbox has no Mix. His walk generator was reimplemented, not reused.
- One full regression campaign, in which every build ran every check twice; earlier validations ran two. The fuzz
  and text walks are deterministic by seed and ran once per build.
- Background load: the fuzz, M2 phases and regression ran side by side on four cores at the lowest priority.
  Timing-dependent counts (Y1, hard kills) may differ from a quiet machine.

## Reproduce

```sh
work=$(mktemp -d)
tools/reproduce_validation.sh "$work" "$work/results.txt"
tools/build_proposal23.sh "$work"
tools/run_l1_fuzz.sh "$work" "$work/fuzz.txt" 1000 "previous l1only candidate proposal"
tools/run_phases23.sh "$work" "$work/m2.txt"
tools/supplement23.sh "$work" "$work/supplement.txt"
```

| File | Content |
| --- | --- |
| `tools/reproduce_validation.sh` | Overlays and the whole regression campaign (the kit, earlier checks, U, M, S, R, Q, F1/F2) |
| `tools/build_proposal23.sh`, `tools/proposal-23fa3e9.patch` | Our one-function patch for N-b, and its build |
| `tools/l1_fuzz.exs`, `tools/run_l1_fuzz.sh` | L1 seeded walks (12 families), deterministic cases W1–W7 (`FUZZ_CASES=1`), one walk traced (`FUZZ_TRACE=family:seed`) |
| `tools/l1_text_test.exs` | L1 through `AtMcp.MCP.Tools.page/5`, text cut and json fallback |
| `tools/phases23_test.exs`, `tools/run_phases23.sh` | M2 sequences S, T, C, L, P, U, B |
| `tools/x3_limit_test.exs` | X3 as a two-sided known-limit test |
| `tools/supplement23.sh` | The W cases, the text walks, Z walks, X5 clock, Y1 timing, X3 placement and X3 limit, on each build |
| `tools/proposal-61fd227.patch` | Our earlier proposal, for comparison |
| other `tools/*_test.exs`, `e2e_h6x.py`, `compile_overlay.exs` | Unchanged from the 61fd227 validation |
| `results/` | Raw output; `l1-fuzz-failures-*.jsonl.gz` lists every failing walk with its family, seed and first failure |
| `METHODS.md` | What this campaign taught us about method |
| `SHA256SUMS` | Checksums |
