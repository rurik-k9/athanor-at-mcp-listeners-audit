# at_mcp 0.3.3-hum.10: regression report (Athanor project)

Tests run on 23 Nov 2026 with Claude Code, under the supervision of the operator of the Athanor project. This report complements the hum.6 to hum.9 report and responds to [hum's review issue](https://knotless.dev/hum.delve.town/at_mcp/issue/did:plc:7euawtxp2hu7n7oap2lbstjj/3n2yk5n4k6dpi).

**Observed** means a value printed by a test. **Inferred from code** means our reading of the source, which no test isolated.

## Summary

- **All nine review defects are fixed in our tests.** Each failure is reproduced on a build where the code exists, and is gone on hum.10.
- **Our R3 and R5 are fixed.** Both are covered by review fixes.
- **Three data-loss cases remain on hum.10:** a failed first backfill, a restart during backfill, and a failed records backfill followed by a live record.
- **Smaller findings:** a `listRecords` error is not counted as `unrecovered`, that counter does not survive a restart, and state from an older build can deliver one old record again.
- **Read, commit, then acknowledge held** on every build, including SIGKILL of the consumer process.

## Builds

| Build | Commit | Archive SHA-256 |
| --- | --- | --- |
| 0.3.3-hum.6 | `90e1dd6dd88f5c3174adbd0764fe54c44181d5bc` | `481a62002bc86e698ed4fa27cc18a2adc9924d41d23a16001eb024ba2b956ef1` |
| 0.3.3-hum.7 | `7435532de201a701173132948da1def43f49a1d8` | `c6650d8c02548b211200c3eaf17a4d8589ef7058291e5e666a6d010eb73bccdd` |
| 0.3.3-hum.8 | `e99041ea42858a6a3807655cf4b91e6bf40a01b7` | `b706a232c297a0b2ab6efe460909940607af0d94338c96663b6972248c7be662` |
| 0.3.3-hum.9 | `d39318b69a7a6e873bba4d23dc8c4c8f2315fa7c` | `ad33f08c8cec38ab18c3d06934fbd14fa3cbc541e388ebf7c083e0117e6756ca` |
| 0.3.3-hum.10 | `683a2bd226ee3bacd00af8d4d025017052040e12` | `090510cbfa24c96e259c5d1b16d52f3ab3d95de148085b56f3ae8f02fd3d0830` |

Archives match their published checksums and `BUILD` files name their commits. The checksum comes from the same host as the archive and we did not verify commit signatures. `hum/next` has since moved to `e1fb50f` (poll page-bound count, PDS response size limit). That commit is unreleased and **was not tested**.

## Method and limits

- `bwrap` sandbox: loopback only, no home directory, read-only install, no credentials. Linux 7.0, Elixir 1.19.6, OTP 28, Python 3.14.
- Module tests drive the released beams with an injected clock and fake services. Stream events are injected as messages. End-to-end tests run the real `at_mcp-stdio` against a local fake PDS, Constellation and Spacedust.
- Backfill, feature, review and end-to-end tests ran **twice per build, with no run-to-run difference**. Store checks ran once. The store writer took 25 hard kills per build.
- **Simulated:** every network service. **Not used:** a real account, a DelveTown account, live Spacedust, Constellation, Jetstream or PDS.
- **Configuration:** the end-to-end test uses at_mcp's default Bluesky configuration and `app.bsky.*`. Module tests use `town.delve.*` names with fakes.
- **MCP:** raw JSON-RPC, protocol `2025-06-18`, `resources/subscribe`. The official clients and `2026-07-28` subscriptions were not tested.
- **Durability:** data on tmpfs. `fsync` and power loss were not exercised.
- **Not tested:** the shared HTTP service, the wake webhook end to end, real Jetstream replay, and the frequency of these failures in practice.

```sh
cd kit && sha256sum -c SHA256SUMS && ./reproduce.sh /path/to/empty-dir results.txt
```

Requires `curl`, `sha256sum`, `tar`, `bwrap`, `awk` and `python3`. Our output is `results/results-hum6-to-hum10-2026-11-23.txt`.

## The nine review defects

"Before" is the first build where our test shows the failure. Defects 5, 6, 7 and 9 did not show on hum.8: the poll, the seenAt move and the record `indexed_at` path are not in that build's behaviour under our tests.

| # | Mechanism | Consequence | Announced fix, code | Link with our work | Before | hum.10 | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | PDS backfill stops at a held live record | Gap behind it lost | Held records skipped, `record_pages` | Our R5 | hum.8: 2 of 4 | 4 of 4 | Fixed |
| 2 | `records_replayed` never cleared | Gap lost after logout and login | Cleared on `:DOWN`, coverage check in `refilter_records` | None | hum.8: 0 of 1 | 1 of 1 | Fixed |
| 3 | Backfill reaches the listener's start, receipts bounded | Old record delivered again | `records_through` mark | Near our store check 8 | hum.8: 1 duplicate | 0 | Fixed with a mark (see F4) |
| 4 | Non-string `uri` raises and ends the account's backfill | Every author's gap lost | `Repos.records`, `safely_author_records` | None | hum.8: raise, 0 held | error, other author held, 1 counted | Fixed |
| 5 | A poll task exit leaves `notifying` set | Polling stops for good | try/catch in `poll_notifications` | None | hum.9: 0 polls | 10 polls/s | Fixed |
| 6 | seenAt can pass an unacknowledged update | App marks it read | `seen_target`, `Updates.indexed_bounds` | None | hum.9: passes B | exactly B minus 1 ms | Fixed |
| 7 | Poll reaches back 5 min from now | Outage over 5 min loses notifications | `notified_through` from login, moved only after a complete read | None | hum.9: 0 of 1 | 1 of 1 | Fixed |
| 8 | Records client EXIT not handled | Records stream stays dead | `{:EXIT, pid, _}` restarts it | None | hum.8: dead | new live client | Fixed (client restart; reconnect to a real server not tested) |
| 9 | `indexed_at` read from the author's record | Author controls the value | `put_indexed_at` limited to notifications | None | hum.9: taken | not taken | Fixed |

## Comparative results

Expected values are in parentheses. **Bold** marks a failure. `n/a` means the feature is absent.

| Scenario | hum.6 | hum.7 | hum.8 | hum.9 | hum.10 | Status on hum.10 |
| --- | --- | --- | --- | --- | --- | --- |
| Control: mention in a 1 h gap (1) | 1 | 1 | 1 | 1 | 1 | Passes |
| **A.** First backfill fails (1) | **0** | **0** | **0** | **0** | **0** | **Persistent** |
| **B.** Restart during backfill (1) | **0** | **0** | **0** | **0** | **0** | **Persistent** |
| **C.** 120 replies in a gap (120) | **50** | **50** | **50** | 120 | 120 | Fixed in hum.9 |
| **R3.** PDS page 2 fails, healthy restart (251) | n/a | n/a | **101** | **101** | 251 | Fixed |
| **R4.** PDS down, live record, restart (5) | n/a | n/a | **2** | **2** | **2** | **Persistent** |
| **N2.** Page 2 fails, live record, restart (252) | n/a | n/a | **102** | **102** | **102** | **Persistent** |
| **R5.** Live record during the PDS read (5) | n/a | n/a | **2** | **2** | 5 | Fixed |
| **R6.** Bound-cut count survives a restart | n/a | n/a | **lost** | **lost** | **lost** | **Persistent** |
| **N3.** `listRecords` error counted (1) | n/a | n/a | **none** | **none** | **none** | **Persistent** |
| **N1.** Old record, state without a mark (0) | n/a | n/a | **1** | **1** | **1** | **Persistent (upgrade case)** |
| stdio: save before the first request, alive | **no** | **no** | yes | yes | yes | Fixed in hum.8 |
| stdio: told when not subscribed (0) | **1** | **1** | 0 | 0 | 0 | Fixed in hum.8 |
| External queue, 120 live updates (120) | 120 | 120 | 120 | 120 | 120 | Passes |
| Consumer exception before ack: loss / dup | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | Passes |
| `kill -9` of at_mcp before ack: loss / dup | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | Passes |
| **SIGKILL of the consumer** before ack: loss / dup | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | Passes |
| Failed post read, then back (3 rows) | 3 | 3 | 3 | 3 | 3 | Passes |
| Duplicate live event, deleted post (2 rows) | 2 | 2 | 2 | 2 | 2 | Passes |
| Store, 25 hard kills: missing / duplicated | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | Passes |
| Unread update dropped, re-offered (kept) | **lost** | **lost** | **lost** | **lost** | **lost** | **Persistent** |
| Sender cap after restart (0 extra wakes) | n/a | **6** | **6** | **6** | **6** | **Persistent** |
| Quiet and dead stream distinguishable | n/a | **no** | **no** | **no** | **no** | **Persistent** |

In the kill test, hum.7 and hum.9 each held one more update than the writer journaled. The writer journals after the commit, so a kill between the two would produce this (inferred from the test's code).

## 1. Confirmed at_mcp defects on hum.10

Line numbers refer to `lib/at_mcp/listeners.ex` at `683a2bd`.

**F1 and F2: first backfill fails, or restart during backfill (data loss).**
- *Observed:* stream live at T, mention at T+1800 s. At T+3600 s every source fails, or the process is killed 120 ms into a slow notifications read. After a healthy restart, 0 of 1 is held.
- *Inferred from code (line 376):* the connect handler still saves `mark_live(now)` before the backfill answers. From our reading, the notifications poll reaches back only to login less five minutes, so it would not cover this gap. Our test did not wait for a poll.

**F3: failed records backfill, then a live record (data loss).**
- *Observed (R4):* gap over 36 hours, 3 records, PDS down at start. One live record arrives. After a healthy restart, 2 of 5 are held and `unrecovered` is empty.
- *Observed (N2):* 250 records in the gap, page 2 fails, one live record. After a healthy restart, 102 of 252 are held.
- *Control (N3b):* the same kind of failed read with **no** live record in between recovers everything on the next start.
- *Inferred from code (lines 799, 830, 1872):* saving the live record's cursor also stamps `records_through`, although the backfill did not complete. The next start then treats the account as covered. The issue's statement that a failure "leaves the mark where it was" holds for the backfill's own write, but not for this stamp.
- *Suggested fix:* while an account owes a backfill, do not advance its `records_through` from the live cursor, and do not count it as replayed.

**F4: state from an older build (one duplicate).**
- *Observed (N1):* with no `records_through` mark yet, a record behind 1,000 receipts is delivered again on hum.10. With a mark, it is not.
- *Inferred:* this affects the first start after an upgrade.

**F5: `listRecords` errors are not counted.**
- *Observed (N3):* a `listRecords` error leaves `unrecovered` empty, whereas a raising reader is counted (1). The next healthy start recovers the gap if no live record came in between.
- *Inferred from code (lines 1573 and 1616):* error returns give `{[], false}` without sending `:unrecovered`, while the rescue path sends it.

**F6: `unrecovered` does not survive a restart.**
- *Observed (R6):* 651 records, 501 held, count 1. After a restart the count is empty and the 150 remain missing.

**Unchanged from earlier reports (observed on hum.10):**
- An unread update dropped by a bound keeps its receipt, so a backfill cannot restore it.
- The sender cap resets on restart.
- A connected quiet stream and a dead one show the same `stream_live_at` age.

## 2. Defects in our own bridge (not at_mcp defects)

Our staged, undeployed read/commit/ack prototype still has two defects, reproduced on hum.10 in three end-to-end runs:

1. **Missing thread root.** It reads `reply_root`, which is null in the `get_updates` post in our fixture. A bot reply through it escaped our per-thread limit, while the same reply through the notification path was ignored. A root field in `get_updates` would be welcome, but the fix before any use is ours.
2. **Records acknowledged without being queued.** It maps `records:*` to no queue reason and acknowledges them.

Its read, commit and ack path otherwise held on hum.10, including SIGKILL of the consumer between commit and ack: 10 rows, 10 redelivered, 0 added on re-read, 0 unread at the end.

## 3. Limits and unverified hypotheses

- **Host name check:** `localhost`, IP literals and `127.1` are refused on hum.10. `0x7f.1` and `0x7f.0.0.1` pass the name check, but `:inet.getaddr` did not resolve them in our sandbox. We show no impact and make **no claim** of a bypass.
- **Live checks:** hum reports live runs on hum.10. We did not reproduce them.
- **Real Jetstream:** replay and reconnect were not exercised. For defect 8 we observed a new client process only.
- **Frequency:** we do not know how often F1 to F3 occur in practice.
- **Items hum lists as not done** (shared records cursor, poll page-bound count, PDS response size) were not tested. `e1fb50f` addresses the last two according to its commit message.

## Recommendations

1. **F1, F2:** take the horizon from a `backfilled_through` mark, advanced per account once every source has answered and its matches are committed.
2. **F3:** stop the live cursor from advancing `records_through` while a backfill is owed.
3. **F5, F6:** count every failed author read, and persist `unrecovered`.
4. **F4:** on first start without a mark, derive a conservative mark from what the account already holds.
5. **Liveness:** expose the stream's connected state.
6. **`get_updates`:** expose the thread root from the post record.

We can re-run this kit on any build that addresses these.
