# Trial by Fire, round c64be24: independent validation of at_mcp `c64be24` (hum/next)

Rurik's laboratory (Athanor project), run by Claude Code under the operator's supervision, 26 Nov 2026. A community
contribution to at_mcp's reliability. All data is synthetic, every network service is simulated, no real account was
used. Nothing here has been published or sent.

**Revision under test:** `c64be24bc06b7fb44e91369cb8007b2065b8f962`, "Review of aa73b9e: one read per login; retry
records while the stream is down", the tip of `hum/next` when fetched (26 Nov). It was checked to resolve to that hash
and to be on `hum/next` before anything ran. `177d2ee` was not tested.

**Builds:**
- **target**: c64be24.
- **previous**: 23fa3e9, our last validated round.
- **control**: 335b95e, the hum.11 sources recompiled.
- **official**: the 0.3.3-hum.11 release itself, checked against its sha256.
- **Bisection builds**: b653ead, 3d43966, 9281970, 9499b75, 916aebc, 0497933, 61fd227, 74f9c34.

**Method:** the changed `lib/` files are compiled in a network-less bwrap sandbox with hum.11's Elixir and overlaid on a
copy of the hum.11 release, as in earlier rounds (`tools/build_c64.sh`). Tests are `.exs` scripts evaluated inside the
release (`tools/run_c64.sh`). They use an injected clock, a programmable fake Constellation, fake repositories and
notifications, and relays that are a closed local port; "the stream connected" is announced by message. Values are
observed, not asserted. Every result file in `results/` is the raw output.

Hum's priorities, in order:
1. receipts: clock skew, records dated in the future, a damaged or truncated listener state file at start;
2. pagination ending: link pages that never run dry, unlisted subjects, read caps;
3. recheck under churn: listen/unlisten and login/logout loops, a second recheck chain, a mark that never moves.

## Summary

Every failure has a standalone reproducer in `repro/`: one file each, with its own fakes, needing only an at_mcp
release. `repro/reproduce.sh EMPTY_DIR` rebuilds everything from scratch:
- a fresh clone, checking that c64be24 resolves to the exact hash;
- the hum.11 release downloaded, with its sha256 checked;
- the overlays compiled in the sandbox;
- each case run on the builds that date it.

| # | Finding | Status | Since | Standalone case |
|---|---|---|---|---|
| F1 | A damaged `listeners/streams.json` (one byte short, or valid JSON of the wrong shape) makes `Updates` raise on each use. Under the service's supervision and Listen's 2 s login retry, `AtMcp.Supervisor` gives up within seconds, and the application stops for every account. | confirmed | on hum.11, at the first live save (a records listener writing the stream's cursor); since 3d43966, also at any login and at a stream connect (bisected: b653ead survives both) | `repro/f1_streams_json.exs` |
| F2a | An account file whose `listeners` is `[]` (valid JSON) brings the supervisor down. | confirmed, **pre-existing** | the hum.11 release | `repro/f2_account_file_types.exs` |
| F2b | An account file whose `receipts` is `null` brings the supervisor down. | confirmed, **regression** | 9499b75: down in 8 of 8 runs on 9499b75 and on c64be24; survives on hum.11, b653ead, 3d43966, 11add1b; on 9281970, 6 of 7 runs survived and one went down (a timing effect, not explained) | same file (`results/f2-receipts-null-repeated-5x.txt`) |
| F2c | `next_seq`, `updates`, `bounds` or `settling` of the wrong type crash the children, which restart; the supervisor survives. Even then, the *undamaged* account's live record that arrives during the restarts is not saved (`repro/f2_account_file_types.exs`: `healthy_account_saved_live_record: false` for `next_seq: "x"` on c64be24, and for `receipts: null` on hum.11). | confirmed, minor | various | `tools/a1s_supervised.exs`; `repro/f2_account_file_types.exs` (`next_seq`) |
| F3a | A subject whose sources can't be listed, plus unlisten/listen of the same listener once per recheck interval: the gap is never counted, and the account's mark never moves, for as long as the loop lasts. | confirmed, reproduced as is | c64be24's hold rule (23fa3e9 let the gap go silently instead) | `repro/f3_mark_never_moves.exs` |
| F3b | The same with logout/login once per interval. | partly simulated: the stream's reconnect after each login is sent by hand (closed relays) | c64be24 | same file |
| F4 | The built-in listener's notifications poll starts from this host's clock at login. A clock more than 300 s ahead of the AppView at login makes the poll skip every notification indexed before that point: none saved, none counted. | confirmed in the poll path (the live stream and backfills, which may deliver them otherwise, are not modelled) | the hum.11 release | `repro/f4_poll_clock_ahead.exs` |
| C1 | Link pages that never run dry with records the listener takes: the read is cut at 5 pages per pass and counted once, and the mark never moves. The recheck reads 5 pages every interval, forever. | characterization (by design: "a real backlog") | c64be24 | `tools/a3_pagination.exs` |
| C2 | An unreadable account file is reported (`updates_unreadable`), and the other accounts are unaffected. Nothing sets the file aside, so that account stays without listeners until a person fixes it. | characterization | all builds | `tools/a1_damaged_state.exs` |
| C3 | Docs: "three passes in a row (a quarter hour)". Observed: three listings, the connect's and two recheck passes, so about 10 minutes at the default recheck. | documentation | c64be24 | `results/a4c-trace-c3.txt` |
| K2 | Clock constantly 120 s ahead of the AppView at fast save rates: losses at 12 and 16 saves/s, none at 10, against a predicted threshold of 8.3. Warm-up losses were not explained. | **inconclusive**, left as a hypothesis with its raw data | | `results/a6-clock-target.txt` |

What held, and the negative results, are in each axis below.

## Axis 1: receipts

### 1a. Damaged or truncated state files at start (`tools/a1_damaged_state.exs`, `tools/a1s_supervised.exs`)

There are two accounts, `me` and `other`, each with a records listener, three saved and acknowledged records, and a
connect. Then one of 50 mutations is applied to a copy of the state, the store starts again, both accounts log in, the
stream connects, and a live record arrives. Raw output: `results/a1-damaged-state-target.txt`, `...-previous.txt`,
`results/a1s-supervised*.txt`.

**Without supervision (A1),** as `Updates` and `Listeners` are left without a supervisor:
- *Held:*
  - The start never fails. Truncated or unreadable account files (empty, 1 byte, 10/50/90 %, last byte missing, NUL
    padding, top-level list, null, version 999) give `{:error, :updates_unreadable}` at login, and the other account
    keeps working.
  - A wrong mode (0644) gives `config_insecure`; a directory in place of the file gives `config_unavailable`. Both are
    visible, and the other account keeps working.
  - Damaged entries inside `receipts.f` (`[1]`, `[null]`, `["short"]`), a non-integer, negative or far-future
    `forgotten_through`, and malformed `ahead`/`ahead.f`/`settling.f` are absorbed: the file is rewritten valid, and the
    new record is held. A far-future `forgotten_through` is settled, as the docs say.
- *Crashes (the process raises):*
  - On the account file: `receipts` null, `[]`, `"x"`; `receipts.f "x"`; `listeners` `[]`, null, `"x"`;
    `listeners.f.spec "x"`; `listeners.f.bounds "x"`; `next_seq` `"x"` or null; `updates` `"x"` or `[1]`;
    `settling "x"`.
  - On `streams.json`: empty, cut at 50 %, last byte missing, `[]`, null, `{"streams":[]}`, `{"streams":"x"}`.
- *Silent:*
  - `listeners.f.spec.source "bogus"` and `listeners.f.cursor "x"`: the login succeeds, the account's new record is not
    delivered, and nothing is reported.

**Under supervision (A1s).** This reproduces the service's arrangement: `AtMcp.Supervisor` is one_for_one with the
default intensity (`lib/at_mcp/application.ex:108`), and `AtMcp.Listen` retries `Listeners.track` every 2 s, catching
exits (`lib/at_mcp/listen.ex:141-156`). Each retry crashes two children, so the intensity (3 restarts in 5 s) is
spent within one or two retries.

| Mutation | official hum.11 | b653ead | 3d43966 | 23fa3e9 | c64be24 |
|---|---|---|---|---|---|
| none (control) | up | up | up | up | up |
| account file cut at 50 % (unreadable) | up, error reported | up | up | up | up |
| account `receipts: null` | up (children restarted) | up | up | **down** | **down** |
| account `receipts: []` | up (restarted) | up | up | up (restarted) | up (restarted) |
| account `listeners: []` | **down** | **down** | **down** | **down** | **down** |
| account `next_seq: "x"` | up (restarted) | up | up | up | up |
| account `settling: "x"` | up | up | up | up (restarted) | up (restarted) |
| `streams.json` last byte missing | **down** | **down** | **down** | **down** | **down** |
| `streams.json` = `[]` | **down** | **down** | **down** | **down** | **down** |

"down" means `AtMcp.Supervisor` exits `:shutdown` within 12 s. In the service, that stops the application, for every
account. Bisection of `receipts: null` (`results/bisect-a1s-9281970-to-74f9c34.txt`): up on 9281970, down from 9499b75
("Settle an earlier build's state at start"), on through 916aebc,
0497933, 61fd227, 23fa3e9 and c64be24; the exception at login is `Protocol.UndefinedError` (Enumerable, nil) (A1).
Which code path 9499b75 added was not traced. The other "down" rows are the same on hum.11: older than this branch.

**F1, minimal case (`tools/r1_damaged_streams_file.exs`).** One account logs in. `streams.json` loses its last byte.
A supervisor like the service's holds `Updates` and `Listeners`, and a caller retries `track` every 2 s. The supervisor
shuts down within 9 s on 3d43966, 9281970, 9499b75, 23fa3e9 and c64be24 (`results/repro-r1-r2.txt`,
`results/bisect-r1-*.txt`). On hum.11 and b653ead this login-only case survives
(`results/repro-r1-control-and-official-hum11.txt`): there, `streams.json` is only decoded when a live save writes the
stream's cursor: `repro/f1_streams_json.exs`, case "live save", brings hum.11 down too, while its "connect" and
"login" cases do not. Cause, from the code: `Jason.decode!` on the file's
text in `Updates` (`stream_cursor`, `read_streams`, `settle_cursors`, `save_stream_cursor`; `lib/at_mcp/updates.ex`
lines 459, 935, 961, 1230 at c64be24), while account files go through `decode/1`, which returns
`{:error, :updates_unreadable}`.

**How likely.** at_mcp writes these files atomically: an exclusive temporary file, fsync, then rename
(`lib/at_mcp/private_file.ex`). It does not truncate them itself. The cases that remain are:
- a damaged disk or filesystem;
- a backup restored incomplete;
- a hand edit;
- another program, or a build writing a different shape.

The consequence, the whole service stopping and starting again, then stopping again under the systemd restart limits,
is what makes it worth reporting.

### 1b. Records dated in the future; this host's clock behind its sources (`tools/a2_ahead_clock.exs`)

The test uses a records listener whose receipt limit is the minimum (1,000), and saves live records at a controlled rate
on an injected clock. A record would come back as a duplicate if a read that pages by its date met it while it is
neither held by a receipt nor by a note. This is measured with `Updates.held/4` and the floor (`forgotten_through`).
Raw output: `results/a2-ahead-clock.txt`.

- **S1, one record dated ahead, then 1,100 ordinary saves.** Offsets tested: 1 h, 1 day, 1 year, 100 years, the
  largest 13-character key (`zzzzzzzzzzzzz`), and a key with its top bit set.
  - *Held on c64be24:* the record stays held by its note in every case.
  - *Held:* the floor stays about 99 s before the clock (the saves), and the account's mark never passes the clock.
  - *On 23fa3e9:* the record is exposed in every case (X5, the fix holds).
- **S2, the clock 300 s behind, every record dated 300 s after its save, 2,500 saves at 1 to 8 per second.** The docs
  put the threshold for duplicates at 1000 / 300 = 3.33 saves per second.
  - *Observed on c64be24:* no record exposed at 1, 2 and 3 per second; 196, 490 and 500 exposed at 4, 5 and 8 per
    second. The two-sided verdict is **HOLDS** at every rate: the documented limit is exact, both ways.
  - *On 23fa3e9:* exposed at every rate (299 at 1 per second).
- **Coverage limit.** The real records backfill run after each scenario did not read the repository (0 calls),
  because the saved Jetstream cursor makes the replay cover it. The S1/S2 verdicts therefore rest on the mechanism
  (`held` and the floor), not on an observed duplicate.

**The two clock cases left open in the first pass (`tools/a6_clock.exs`, `repro/f4_poll_clock_ahead.exs`).**
Raw output: `results/a6-clock-*.txt`.
- **K1, the clock 1 h ahead, then stepped back while running.** With the clock ahead at login, none of 1,300
  mentions, indexed at the real time, was saved, and none was counted. After the step back, none of 50 new ones was
  either. The control, with the clock right throughout, holds the receipt limit's worth of old ones and all 50 new ones.
  The cause is in the code:
  - `notified_through` starts at the host's clock when the account logs in (`Map.put_new(..., state.clock.())`);
  - it only moves forward (`max`, in `handle_info({:notified, ...})`);
  - the poll keeps only notifications indexed at or after `notified_through - 300`, before the floor check that would
    count them.

  The floor plays no part: it stayed unset. The negative control in `repro/f4_poll_clock_ahead.exs` (the clock right
  at login, ahead for one poll, then right again) is unaffected, so the cause is the start at login. The result is the
  same on 23fa3e9 and on the 0.3.3-hum.11 release. This is **F4**.
- **K2, a constant skew of 120 s, fast saves.** Losses at 12 and 16 saves/s; none at 4, 6, 8 and 10, against a
  predicted threshold of 8.3 saves/s. The warm-up phase also showed fewer held receipts than expected at higher
  rates, which we could not explain. K2 is **inconclusive**: a hypothesis with its raw data, not a finding.

## Axis 2: pagination ending (`tools/a3_pagination.exs`, `tools/a3b_trace.exs`)

The test uses a links listener on one subject, a connect, an hour's gap, a reconnect, and recheck passes every 300 ms
(and 3,000 ms in A3b). Raw output: `results/a3-pagination.txt`, `results/a3b-trace.txt`.

| Scenario | c64be24 | 23fa3e9 |
|---|---|---|
| 6 records in the gap (control) | all saved, mark moves, recheck stops | the same, but listings every pass |
| pages never dry, every page new, taken | cut at 5 pages per pass, counted once, mark **never moves**, recheck every interval for good (C1) | read 2 pages per pass, mark moves, nothing counted |
| the same page and cursor forever | 51 reads, given up, counted, mark moves, recheck stops | read every pass, nothing counted |
| empty pages forever | 50 reads, given up, counted, mark moves | read every pass, nothing counted |
| pages never dry, every record left out by a `from` filter | 50 reads, given up, counted, mark moves, recheck stops | read every pass, nothing counted |
| sources unlisted for 1 listing, then listed | gap read, 6 saved, nothing counted | 0 saved |
| sources unlisted for 2, 3, 4 or 10 listings | given up at the third listing, counted, mark moves, 0 saved | not counted |

The fixes for fork issue 3n2z7nxyaxy2e (a cut read is not success; reads spent on held or not-taken pages give up,
counted; an unlisted subject holds the mark for three tries, then is counted and let go) **hold**. The only unbounded
case is C1: a subject whose pages never run dry with records the listener takes. That case is consistent with the
docs' "real backlog", but it never ends.

Harness corrections during this axis, recorded so they are not mistaken for findings:
- the fake Constellation first returned the same sources and endless pages for every subject, including the account's
  own DID, which the built-in listener reads; that held the mark through the built-in listener. Scoped to the subject
  under test, the `from` case behaves as documented;
- the records for the unlisted case were first present before the gap, so they were read at the first connect.

## Axis 3: recheck under churn (`tools/a4_churn.exs`, traces `tools/a4c_debug_c3.exs`)

The recheck interval is 1,000 ms (5 min in the service). Listings of the subject under test are counted per interval.
Raw output: `results/a4-churn.txt`, `results/a4c-trace-c3.txt`.

- **C1/C2 control (no churn).** The subject is listed at the connect and in two passes, then given up, counted, and the
  mark moves.
- **C2, unlisten and listen every interval (F3a, reproduced as is).** One listing per interval, the mark stays at 0 and nothing is counted
  for all 12 intervals. This needs no harness help.
- **C1, logout and login every interval (F3b, partly simulated).** About two listings per interval, the mark stays at 0 and nothing is
  counted. *Harness note:* a login changes the stream's filters, so the stream restarts; with closed relays it never
  reconnects by itself (`working/a4b-debug-c1-harness-reconnect.txt` shows `connected?: false`). So the announcement
  the service's stream would send is sent by hand after each login. The C1 result depends on that emulation; C2 does
  not.
- **C3, a login 50, 300 or 500 ms before a reconnect.** Traced every 100 ms (`results/a4c-trace-c3.txt`): three
  listings at 0, 1 and 2 intervals, then given up. One listing per pass, so aa73b9e's double read (two misses per
  pass) is fixed in this ordering.
- **C4, 20 logout/login cycles of one account within one interval.** No extra reads afterwards, no duplicates, and the
  recheck stops.
- **C5, 20 reconnects within one interval.** One listing in the next interval, then none: **one chain**. On 23fa3e9:
  21 listings per interval, every interval.

**F3, minimal case (`tools/r2_relisten_holds_mark.exs`):**
- *Control:* the mark moves to the reconnect, and unrecovered is 1.
- *With unlisten/listen each interval:* the mark stays where it was and unrecovered stays nil, for 10 intervals.

The case reproduces on c64be24. On 23fa3e9 it does not, because 23fa3e9 lets such a gap go silently: the mark moves,
nothing is counted. That is the defect hum's e6d621e/e3232ef chain fixed. F3 is the cost of that fix under churn.
- *Who would hit it:* an agent that re-creates a listener (unlisten then listen) more often than every ten minutes
  while a subject's listing is failing; or, with the stream reconnecting, an account that logs out and in that often.
- *Consequences:*
  - nothing is ever counted for the gap;
  - the account's mark is held, so later backfills reach back further;
  - the account is read every recheck interval.

## Whole-build stress (`tools/a5_stress.exs`)

The test uses 4 accounts, each with a links and a records listener. Each seeded run is 150 random steps mixing:
- logout/login with a reconnect;
- unlisten/listen;
- reconnects;
- the subject's listing failing or working;
- live records, a fifth of them dated up to a day ahead;
- records appearing in Constellation for gaps;
- clock steps.

A quiet phase follows: listings work, with no churn. The run uses seeds 1 to 8 and a recheck of 200 ms. Raw output:
`results/a5-stress.txt`.

- **c64be24, all 8 seeds:**
  - no crash, and the same `Updates` and `Listeners` processes throughout;
  - no record saved twice;
  - after the quiet phase, the recheck has stopped, no account is held and there are 0 listings per interval;
  - no account mark past the clock.
- **23fa3e9:** after the quiet phase, 2 to 4 accounts were still held and listings ran at 99 to 136 per interval (many
  chains). c64be24 fixes this.

Coverage limit: few saves per listener, so no receipt was let go and the floors stayed unset (`nil`). The stress run
does not exercise the floor.

## What our own earlier rounds missed

F1's login trigger (3d43966) and F2's `receipts: null` case (9499b75) were both in builds that we validated: 9499b75,
61fd227 and 23fa3e9. Those rounds tested damaged *entries* (X3) but never a damaged or wrongly typed *file*, and never
under the service's supervision. The damaged-state test (`tools/a1_damaged_state.exs`, `tools/a1s_supervised.exs`) is
now part of the kit and should be run in every round.

## What was not covered

- **Hum's ExUnit suite was run, with the operator's authorization** (`results/exunit-c64be24-summary.txt`, full log
  `results/exunit-c64be24-full-log.txt`):
  - *Run:* `MIX_ENV=test mix test` on a `git archive` of c64be24, with the suite's default exclusions (`:goal`, `:e2e`,
    `:hosts`), in bwrap with no network and a private `/tmp`.
  - *Toolchain:* precompiled OTP 28.4.3 and Elixir 1.19.6 from builds.hex.pm, sha256-checked; the release runs erts
    16.4.0.6, a patch apart. Dependencies were fetched beforehand with `mix deps.get`, which checks each package
    against `mix.lock`.
  - *Result:* **1,703 tests, 0 failures, 22 skipped, 47 excluded** (482 s).
  - *The skips:* most need variables this environment doesn't set (`MCP_CLIENT_PATH`, `TEST_ACCOUNT_RELEASE`, `BENCH`:
    the MCP SDK client, a built production release, the bench). Three are hum's own known-limit tests, skipped by tag:
    `review_dbf4a1d_test.exs:194`, `review_9b5d2dc_test.exs:143` and `review_5270f0e_test.exs:171`. As skips, they
    report neither a limit getting worse nor one disappearing. CONTRIBUTING.md says CI fails on any skip with every
    variable set. We did not check how these three are treated there.
- **No real service:** no live Constellation, Spacedust, Jetstream, PDS or AppView, and no real account. Every result
  is simulated.
- **The supervision in A1s/R1** is modelled on `application.ex` and `listen.ex`, not the full service: its other
  children, MCP sessions and logins were not started.
- **Clock:** K1/F4 were tested on the poll path only. K2 is inconclusive.
- **Storage incident during this round:** the temporary space's per-user quota ran out mid-round and stopped the
  first clean reproduction. No result was lost; see `governance` incident note (not part of this dossier). The clean
  reproduction was then rerun from an empty directory: `results/clean-reproduce-output.txt`.
- **Read caps of the notifications backfill:** the W5 tie cases were covered in earlier rounds, not here.
- **Login and logout** were tested on one account per loop; concurrent churn of many accounts was tested only through
  the A5 stress.

## Reproduce

From an empty directory, with network for the clone and the release download only:

```sh
repro/reproduce.sh "$(mktemp -d)"     # checks c64be24's exact hash and the release's sha256, builds, runs F1-F4
```

Its full output from a run on 26 Nov is `results/clean-reproduce-output.txt`. After that run, the printed *labels* of
F2 and F3 were corrected, with no change to what the cases do: the F2 label first named the wrong commit, and the F3
control printed "UNEXPECTED" on 23fa3e9, where the result is the expected older behaviour. Those cases were then run
again on the same clean builds: `results/clean-reproduce-f2-f3-rerun-after-label-fix.txt` and
`results/clean-reproduce-f2-final-labels.txt`.

The bench used for the axes (prelude, fakes, all scenarios):


```sh
W=$(mktemp -d)        # holds: at_mcp.git (bare clone of knotless.dev/hum.delve.town/at_mcp), audit/ (the kit
                      # repository at 8123ba36), and at_mcp-0.3.3-hum.11-linux-x86_64.tar.gz
tools/build_c64.sh "$W"                                   # control, previous, target
tools/run_c64.sh "$W" out.txt "target previous" "r1_damaged_streams_file r2_relisten_holds_mark"
tools/run_c64.sh "$W" out.txt "target previous" "a1_damaged_state a1s_supervised a2_ahead_clock a3_pagination a4_churn"
tools/run_c64.sh "$W" out.txt "target previous" "a5_stress" SEEDS="1 2 3 4 5 6 7 8" STEPS=150
tools/build_c64.sh "$W" c3d4=3d43966 b653=b653ead          # bisection builds
```

Each reproducer prints `RESULT ... verdict REPRODUCED` or `NOT REPRODUCED`.
