# at_mcp listeners: hum.6 to hum.9 test report (Athanor project)

**Revision 2.** Tests run on 23 Nov 2026 with Claude Code, under the supervision of the operator of the Athanor project. Measured results are unchanged from revision 1; this revision corrects wording, scope and attribution. **Later results on hum.10 are in the separate hum.10 report.**

In this report, **Observed** means a value printed by a test. **Inferred from code** means our reading of the source, which no test isolated.

## Summary

Observed on the published Linux x86_64 builds, with synthetic data and simulated services:

- **Fixed in hum.8:** `at_mcp-stdio` exits with status 1 on hum.6 and hum.7 when a listener saves before the client's first request. On hum.8 and hum.9 it stays up and the update is readable.
- **Fixed in hum.9:** with 120 replies in a gap, hum.6 to hum.8 recover 50 and hum.9 recovers 120.
- **Still present on hum.9:** a failed first backfill, or a restart during backfill, loses a mention in the gap.
- **Introduced with records listeners (hum.8 and hum.9):** three cases lose records after an interruption, with no count of the loss.
- **External queue:** read, commit, then acknowledge lost nothing and duplicated nothing when the consumer stopped before its ack (simulated by an exception) and when at_mcp received `kill -9`.

This campaign did **not** send SIGKILL to the consumer process, and did not kill-test or power-fail its SQLite database.

## Scope and limits

- **Services:** PDS, Constellation, Spacedust, notifications, profiles and repositories were all simulated. No live service was used.
- **Accounts:** no real account and no DelveTown account.
- **Network configuration:** the end-to-end test ran `at_mcp-stdio` with at_mcp's default Bluesky configuration and `app.bsky.*` records. Module tests used `town.delve.*` collection names with fakes.
- **MCP:** a raw JSON-RPC client, protocol `2025-06-18`, with `resources/subscribe`. The official MCP clients and `2026-07-28` subscriptions were not tested.
- **Durability:** test data was on tmpfs. `fsync` and power loss were not exercised.
- **Not tested:** the shared HTTP service, the wake webhook end to end, Jetstream replay from a real server, live quote and mention labels, and how often these failures occur in practice.

## Builds

| Build | Commit | Archive SHA-256 |
| --- | --- | --- |
| 0.3.3-hum.6 | `90e1dd6dd88f5c3174adbd0764fe54c44181d5bc` | `481a62002bc86e698ed4fa27cc18a2adc9924d41d23a16001eb024ba2b956ef1` |
| 0.3.3-hum.7 | `7435532de201a701173132948da1def43f49a1d8` | `c6650d8c02548b211200c3eaf17a4d8589ef7058291e5e666a6d010eb73bccdd` |
| 0.3.3-hum.8 | `e99041ea42858a6a3807655cf4b91e6bf40a01b7` | `b706a232c297a0b2ab6efe460909940607af0d94338c96663b6972248c7be662` |
| 0.3.3-hum.9 | `d39318b69a7a6e873bba4d23dc8c4c8f2315fa7c` | `ad33f08c8cec38ab18c3d06934fbd14fa3cbc541e388ebf7c083e0117e6756ca` |

Each archive matches its published checksum and each `BUILD` file names its commit. The checksum comes from the same host as the archive and we did not verify commit signatures, so this shows integrity, not independent provenance.

## Method

- Sandbox: `bwrap`, loopback only, no home directory, read-only install, no credentials. Linux 7.0, Elixir 1.19.6, OTP 28, Python 3.14.
- **Module tests** (`backfill_test.exs`, `store_test.exs`, `features_test.exs`) drive the released `AtMcp.Listeners` and `AtMcp.Updates` beams with an injected clock. Stream events are injected as messages.
- **End-to-end test** (`e2e_stdio.py`) runs the real `at_mcp-stdio` against local fakes.
- Backfill, feature and end-to-end tests ran twice per build with identical outcomes. Store checks ran once. The kill test performed 25 hard kills of the store writer per build.

```sh
cd kit && sha256sum -c SHA256SUMS && ./reproduce.sh /path/to/empty-dir results.txt
```

Requires `curl`, `sha256sum`, `tar`, `bwrap`, `awk` and `python3`. Our output is `results/results-2026-11-23.txt`. In that file, the labels B, C and D are defects 1, 2 and 3 below.

## Observed results

| Check | hum.6 | hum.7 | hum.8 | hum.9 |
| --- | --- | --- | --- | --- |
| Control: mention in a 1 h gap (expect 1) | 1 | 1 | 1 | 1 |
| **Defect 1:** first backfill fails, healthy restart (expect 1) | **0** | **0** | **0** | **0** |
| **Defect 2:** restart during backfill (expect 1) | **0** | **0** | **0** | **0** |
| **Defect 3:** 120 replies in a gap (expect 120) | **50** | **50** | **50** | 120 |
| Notification calls for those 120, cursor used | 1, no | 1, no | 1, no | 3, yes |
| stdio: save before the first request, process alive | **no** | **no** | yes | yes |
| stdio: told while not subscribed (expect 0) | **1** | **1** | 0 | 0 |
| stdio: told after unsubscribing (expect 0) | **1** | **1** | 0 | 0 |
| External queue, 120 live updates | 120 | 120 | 120 | 120 |
| External queue, consumer exception between commit and ack | no loss, no dup | same | same | same |
| External queue, `kill -9` of **at_mcp** before ack | no loss, no dup | same | same | same |
| at_mcp update store, 25 hard kills: missing / duplicated | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| **R3:** page 2 of a PDS backfill fails once (expect 251) | n/a | n/a | **101** | **101** |
| **R4:** PDS down at start, one live record, restart (expect 5) | n/a | n/a | **2** | **2** |
| **R5:** live record saved during the PDS read (expect 5) | n/a | n/a | **2** | **2** |
| **R6:** 651 records, 5-page bound: held, count after restart | n/a | n/a | 501, lost | 501, lost |

In one hum.7 kill run, the store held one more update than the writer had journaled. The writer journals after the commit, so a kill between the two would produce this (inferred from the test's code).

## at_mcp anomalies

Line numbers refer to `lib/at_mcp/listeners.ex` at `e99041e`.

**Defects 1 and 2.**
- *Observed:* stream live at T, mention at T+1800 s. At T+3600 s every source fails, or the process is killed 120 ms into a slow notifications read. After a restart with healthy services, 0 of 1 is held.
- *Inferred from code (line 320):* the connect handler saves `mark_live(now)` before the backfill has answered, so the next horizon can pass the gap.
- *Not tested:* events in the last 10 minutes before the failed connect, the 5-minute recheck, partial failure of sources.

**R3.**
- *Observed:* 250 records in a gap over 36 hours. `listRecords` fails on page 2 at the first start. 101 records are held, one from before the gap. A healthy restart leaves 101, and `unrecovered` is empty.
- *Inferred from code (lines 1182 and 1197):* `record_pages` stops at the first held record, and page 1 is now held.

**R4.**
- *Observed:* gap over 36 hours, 3 records, PDS down at start. One live record arrives. After a healthy restart, 2 of 5 are held and `unrecovered` is empty.
- *Inferred from code (lines 641 and 1481):* the live record saves a fresh cursor, so the restart treats the gap as replayable and does not read the PDS. Our test injected events and did not run a real Jetstream replay.

**R5.**
- *Observed:* a live record saved while `listRecords` runs leaves 2 of 5 held. The same slow read with no live record holds 4 of 4.
- *Inferred from code (line 1182):* the live record is the newest result, is already held, and stops the read.

**R6.**
- *Observed:* 651 records, 501 held, `unrecovered` is 1. After a restart it is empty and the 150 are still missing.

**Listener features (observed on hum.8 and hum.9).**

| Feature | Works | Limit |
| --- | --- | --- |
| Per-sender wake cap | 10 replies: 10 kept, 6 wakes, 4 capped; other senders unaffected; resets after one hour | A restart allowed 6 more wakes in the same hour |
| `from` | Only the named sender is kept | |
| `last_saved` | Absent until a match, unchanged by a duplicate, survives a restart | |
| Quiet vs. dead stream | | A connected quiet stream and a dead one both show a `stream_live_at` 7,150 s old |
| Operator pause | Holds against the agent's `listen` and across a restart | Resume not tested |
| Records after a clean gap | Recovered from the PDS over 36 h, without duplicates | Real Jetstream replay not tested |

**Still open from our first report (observed through hum.9):** an unread update dropped by a bound keeps its receipt, so a later backfill cannot bring it back.

## Defects in our own bridge (not at_mcp defects)

Our staged, undeployed read/commit/ack prototype has two defects:

1. **Missing thread root.** The prototype takes the root from `reply_root`, which is null in the `get_updates` post in our fixture (the fixture's `getPosts` holds the root only inside the record). The queue then records the item as its own root. *Observed:* a bot reply through the listener path escaped our per-thread limit, while the same reply through the notification path was correctly ignored. A root field in `get_updates` would help, but the fault to fix before any use is in our bridge.
2. **Records updates acknowledged without being queued.** *Observed:* the prototype maps `records:*` sources to no queue reason and acknowledges them. They would be lost if a records listener were enabled.

The prototype passed its 14 earlier tests once. Three end-to-end runs on hum.8 showed no loss or duplicate in its covered cases.

## Listeners compared with an external queue

| Guarantee | Listeners | Our external queue | Evidence |
| --- | --- | --- | --- |
| Persistence | JSON per account, atomic replace | SQLite with state history | at_mcp store kill-tested on tmpfs. SQLite not kill-tested here. Power loss not tested |
| Deduplication | Per listener, bounded receipts | Per URI, unbounded | Observed in the end-to-end tests |
| Ack after durable storage | Cumulative `through` | Commit precedes ack | Observed with a consumer exception and with `kill -9` of at_mcp |
| Restart | Unread is redelivered | Interrupted work is recovered | Listener side observed. Queue side not tested here |
| Retries and deferrals | Not its role | Recorded per item | Not tested here |
| Publishing and execution limits | Not its role | Enforced by the queue's runner | Not tested here |
| Loop protection | Wake cap per sender | Per-thread limit | Listener cap observed. Queue limit bypassed by our bridge (see above) |
| Priority | Oldest first | Ordered lanes | Queue ordering observed through the real tools |
| Items that cannot be handled now | Waits within bounds | Deferred with a reason | Bounds observed. Deferral not tested here |
| Missed-event recovery | Backfill, with the defects above | Reconciliation poll | Not stress-tested here |

## Recommendations

1. **Defects 1 and 2:** take the horizon from a `backfilled_through` mark, advanced per account only once every source has answered and its matches are committed. Retry failed backfills with backoff.
2. **R3 and R5:** skip held records, as `pages/8` does, and stop only at the listener's start or a per-author completed mark.
3. **R4:** record that a records backfill is owed, and do not treat a fresh cursor as coverage until it completes.
4. **R6:** persist `unrecovered`.
5. **Liveness:** expose the connected state, or move `stream_live_at` on a heartbeat.
6. **Sender cap:** persist hits, or document that a restart resets them.
7. **`get_updates`:** expose the thread root.
8. **Receipts:** do not keep a receipt for an update dropped unread.
