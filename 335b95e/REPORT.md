# at_mcp 335b95e: independent validation

Rurik, Athanor project. Run on 23 Nov 2026 with Claude Code, under my supervision. Sent to hum on 23 Nov; published here on 24 Nov, unchanged apart from this header and the note below.

> **Update, 24 Nov 2026.** hum addressed the three remaining anomalies below in `b653ead`. Our validation of that commit is in [`../b653ead/REPORT.md`](../b653ead/REPORT.md).

**Observed** means a value printed by a test. **Inferred** means our reading of the code. Every observed value below was identical in two runs.

## Conclusion

**The targeted fixes are validated in the tested scenarios.** A, B, R4, its large case and the `listRecords` count all pass on `335b95e`, and they fail on hum.10. No regression appeared in the 98 checks. This is not a validation of a release, because `335b95e` has none, and it does not cover live services.

## What was tested

| Item | Value |
| --- | --- |
| Commit tested | `335b95e61a8d76f7e201c16c53c6f6b6fa9fb364` (`hum/next`) |
| Base release | 0.3.3-hum.10, `683a2bd226ee3bacd00af8d4d025017052040e12` |
| Release SHA-256 | `090510cbfa24c96e259c5d1b16d52f3ab3d95de148085b56f3ae8f02fd3d0830` |
| Published kit | `rurik-k9/athanor-at-mcp-listeners-audit` at `8123ba36ba86e3abe470d611975ce1097b78955b`, manifest valid, 0 files changed |
| `listeners.ex` at `335b95e` | SHA-256 prefix `03dd6afb5af9b7ce` |

**Adaptation, because the commit has no release.** Between hum.10 and `335b95e`, the only changed files under `lib/` are `listeners.ex` and `repos.ex`, with no change to dependencies or configuration. Both were compiled in the sandbox with the Elixir inside the hum.10 release, then overlaid on a copy of that release.

**Control of the method.** The same procedure applied to hum.10's own source matched the official hum.10 on all 98 checks, apart from the raw counts of the timing-dependent kill test, which had no missing or duplicated update. Two compilations of the same source differed only in Elixir's `ExCk` type-check metadata chunk.

The kit's scenarios were not modified. `tools/validation_test.exs` adds supplementary checks (V1 to V10).

## hum.10 compared with 335b95e

| Scenario (expected) | hum.10 | 335b95e | Status |
| --- | ---: | ---: | --- |
| **A.** First backfill fails, healthy restart (1) | **0** | 1 | **Fixed** |
| **B.** Restart during backfill (1) | **0** | 1 | **Fixed** |
| **R4.** PDS down, live record, restart (5) | **2** | 5 | **Fixed** |
| **R4 large.** Page 2 fails, live record, restart (252) | **102** | 252 | **Fixed** |
| R4 repeated: two failed starts, two live records (253) | **103** | 253 | **Fixed** |
| `listRecords` error counted as `unrecovered` (1) | **none** | 1 | **Fixed** |
| PDS not found counted, then recovered (1, 5 held) | **none, 2** | 1, 5 | **Fixed** |
| Notifications page 2 fails, healthy restart (120) | **50** | 120 | **Fixed** |
| Live mark after failed backfill / after success (0 / 3700) | **3600** / 3700 | 0 / 3700 | **Fixed** |
| One account keeps failing, other healthy, then recovers (1) | **0** | 1 | **Fixed** |
| R3. PDS page 2 fails, healthy restart (251) | 251 | 251 | No regression |
| R5. Live record during the PDS read (5) | 5 | 5 | No regression |
| C. 120 replies in a gap (120) | 120 | 120 | No regression |
| Nine review fixes | pass | pass | No regression |
| Deduplication, in the store and end to end | pass | pass | No regression |
| Commit before ack, consumer exception | no loss, no dup | same | No regression |
| `kill -9` of at_mcp before ack | no loss, no dup | same | No regression |
| SIGKILL of the consumer before ack | no loss, no dup | same | No regression |
| Store, 25 hard kills: missing / duplicated | 0 / 0 | 0 / 0 | No regression |

In the results file, labels B and C of the backfill test are scenarios A and B above, and N2 is the large R4 case.

## Remaining anomalies

None is a regression: each behaves the same on hum.10.

**Found in this campaign**
1. **Notifications backfill cut without a count (V4).** *Observed:* 300 mentions in a gap, 250 held, `unrecovered` empty, live mark moved, and a restart recovers nothing more. *Inferred:* the backfill treats `:cut` as success, while the poll path counts it.
2. **One global live mark across accounts (V5).** *Observed:* account B is absent from a run while account A succeeds. The mark moves and B's mention in the gap is lost. This requires several accounts on one service.
3. **No in-process retry of a failed records backfill (V10).** *Observed:* after the PDS returns, the 5-minute recheck path does not recover the gap. The next start does (V7).

**Already reported**
- `unrecovered` does not survive a restart (R6).
- An old record can be delivered again when no coverage mark exists yet (N1).
- An unread update dropped by a bound cannot be restored.
- The per-sender wake cap resets on restart.
- A quiet stream and a dead stream look the same.

## Limits

- `335b95e` was tested as a source overlay, not as a built release.
- All services were simulated: no live PDS, Spacedust, Constellation or Jetstream, and no real Jetstream replay.
- No real account and no DelveTown account. The end-to-end test uses at_mcp's default Bluesky configuration.
- MCP: raw JSON-RPC, protocol `2025-06-18`. Official clients and `2026-07-28` subscriptions were not tested.
- Data on tmpfs: no `fsync` or power-loss test.
- The shared HTTP service and the wake webhook were not tested end to end.
- hum's own test suite was not run: the sandbox has no Mix toolchain.

## Reproduce

```sh
work=$(mktemp -d)
tools/reproduce_validation.sh "$work" "$work/results.txt"
```

Requires Linux x86_64, `git`, `curl`, `sha256sum`, `tar`, `awk`, `python3` and `bwrap`. Raw output: `results/results-335b95e-2026-11-23.txt`. Checksums: `SHA256SUMS`.
