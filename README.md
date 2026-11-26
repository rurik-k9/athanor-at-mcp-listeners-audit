# at_mcp listeners audit

Independent regression tests of the listeners in [hum's at_mcp fork](https://knotless.dev/hum.delve.town/at_mcp/releases), from `0.3.3-hum.6` to `0.3.3-hum.10`.

**Rurik, Athanor project.** The tests were run on 23 Nov 2026 with Claude Code, under my supervision. They are a community contribution to the reliability of at_mcp. All data is synthetic, every network service is simulated, and no real account was used.

## Findings at a glance

Start with [`hum.10/REPORT.md`](hum.10/REPORT.md). It separates observed results from explanations inferred from the code.

| Scenario (expected) | hum.8 | hum.9 | hum.10 | Status on hum.10 |
| --- | ---: | ---: | ---: | --- |
| A. First backfill fails, healthy restart (1) | 0 | 0 | **0** | **Open** |
| B. Restart during backfill (1) | 0 | 0 | **0** | **Open** |
| C. 120 replies in a gap (120) | 50 | 120 | 120 | Fixed in hum.9 |
| R3. PDS page 2 fails, healthy restart (251) | 101 | 101 | 251 | Fixed |
| R4. PDS down, live record, restart (5) | 2 | 2 | **2** | **Open** |
| R5. Live record during the PDS read (5) | 2 | 2 | 5 | Fixed |
| R6. `unrecovered` count survives a restart | no | no | **no** | **Open** |
| stdio survives a save before the first request | yes | yes | yes | Fixed in hum.8 |

- All nine defects from [hum's review](https://knotless.dev/hum.delve.town/at_mcp/issue/did:plc:7euawtxp2hu7n7oap2lbstjj/3n2yk5n4k6dpi) were reproduced on an earlier build and were gone on hum.10 in these tests.
- Read, commit to an external queue, then acknowledge lost and duplicated nothing, including with SIGKILL of the consumer or of at_mcp.

## Later validations on `hum/next`

- **`335b95e` (23 Nov 2026):** [`335b95e/REPORT.md`](335b95e/REPORT.md). hum's fixes for A, B and R4 hold. It found three further anomalies.
- **`b653ead` (24 Nov 2026):** [`b653ead/REPORT.md`](b653ead/REPORT.md), summarized below.
- **`9499b75` (24 Nov 2026):** [`9499b75/REPORT.md`](9499b75/REPORT.md). U, W5 and the three problems from hum's review are fixed in these tests. H6 changes by design. Two counted losses remain: a late notification inside the 10-minute margin when the receipt floor sits there (N1), and a records backfill cut at 5 pages that reports complete, which is older than these fixes (N2).
- **`61fd227` (25 Nov 2026):** [`61fd227/REPORT.md`](61fd227/REPORT.md). The fixes for hum's second review (F1 to F3) and N2 hold, with no regression. New: the oldest-first read can loop under a strict service (L1). X3 is fixed only where the damaged entry's neighbour predates the margin; M2 stays a counted limit. Includes an experimental patch for M2 and L1.
- **`23fa3e9` (25 Nov 2026, "Trial by Fire"):** [`23fa3e9/REPORT.md`](23fa3e9/REPORT.md). L1 is fixed (by `754a231`) in 7,000 seeded walks under a strict service and 300 through the text cut. Both M2 refinements hold: the room is fixed at the upgrade, and the release is per listener. X3 holds under a two-sided test. No regression was found in the kit. Four minor findings, one with a one-function patch. Assumptions about the real service are listed separately. [`23fa3e9/METHODS.md`](23fa3e9/METHODS.md) records what the campaign taught us about method.
- **`c64be24` (26 Nov 2026, "Trial by Fire", second round):** [`c64be24/REPORT.md`](c64be24/REPORT.md). Tested in hum's order: receipts, pagination ending, recheck under churn, then stress. Four failures, each with a one-file reproducer in [`c64be24/repro/`](c64be24/repro/), and `repro/reproduce.sh` rebuilds everything from an empty directory:
  - **F1**: a damaged `streams.json` stops the whole service. This dates from hum.11; since `3d43966`, a login is enough to trigger it.
  - **F2**: wrongly typed fields in an account file crash it on use. `listeners: []` dates from hum.11; `receipts: null` is a regression from `9499b75`.
  - **F3**: unlisten/listen churn with a failing listing keeps the mark still and the gap uncounted. The logout/login variant is partly simulated.
  - **F4**: a host clock ahead at login blinds the notifications poll, silently. This dates from hum.11, on the poll path.

  What held: records dated ahead, the documented clock-skew threshold, the pagination give-ups, and one recheck chain. hum's ExUnit suite: 1,703 tests, 0 failures. K2 is left inconclusive. **Correction to our 23fa3e9 round:** F1's login trigger and F2's `receipts: null` were already present in `9499b75` to `23fa3e9`, which we reported without regression; we had never damaged a whole file or tested under supervision.

### `b653ead`

It tests hum's fixes for the three anomalies found while validating `335b95e`: a cut notifications backfill, one live mark shared by all accounts, and no in-process retry of a failed records backfill. `b653ead` has no release, so it runs as a source overlay on hum.10, with a control overlay that matches hum.10.

| Check (expected) | hum.10 | 335b95e | b653ead |
| --- | ---: | ---: | ---: |
| 600 mentions, cut backfill, three starts (250, 500, 600) | 250, 250, 250 | 250, 250, 250 | **250, 500, 600** |
| One account absent from a run: its gap held (1) | 0 | 0 | **1** |
| Records backfill fails, PDS returns, no restart (4) | 1 | 1 | **4** |
| Upgrade: already acknowledged notifications delivered again (0) | 0 | 0 | **199 of 200** |

- The three fixes hold in these tests, and we saw no regression in the kit. Three full campaigns gave identical values.
- **New:** a start where an account has no live mark of its own delivers acknowledged notifications older than the receipts window again, as unread. That is always the case on the first start after upgrading from hum.10 or `335b95e`. Nothing is lost.

## Contents

| Path | Content |
| --- | --- |
| `hum.10/REPORT.md` | Regression report, hum.6 to hum.10 |
| `hum.10/kit/` | Current reproduction kit |
| `hum.10/results/` | Raw output of that kit |
| `335b95e/REPORT.md` | Validation of `335b95e` (`hum/next`), with its tools and raw results |
| `9499b75/REPORT.md` | Validation of `9499b75` (`hum/next`), with its tools and raw results |
| `61fd227/REPORT.md` | Validation of `61fd227` (`hum/next`), with its tools, raw results and an experimental patch |
| `c64be24/REPORT.md` | Validation of `c64be24` (`hum/next`): standalone reproducers (`repro/`), bench (`tools/`), raw results, bisections and the ExUnit run (`results/`) |
| `23fa3e9/REPORT.md` | Validation of `23fa3e9` (`hum/next`), with its tools, seeds, raw results, first-pass outputs and a patch; `METHODS.md` |
| `b653ead/REPORT.md` | Validation of `b653ead` (`hum/next`), with its tools and raw results |
| `hum.6-to-hum.9/REPORT.md` | Earlier report, revision 2 |
| `hum.6-to-hum.9/kit/` | The kit that produced the earlier results |
| `hum.6-to-hum.9/results/` | Raw output of that kit, unchanged |
| `LICENSE` | MIT license for our original work |
| `THIRD_PARTY_NOTICES.md` | Attribution to at_mcp and deepfates, and adapted test material |
| `SHA256SUMS` | Checksums of every other file in this repository |

## Reproduce

Requirements: Linux x86_64, `bash`, `curl`, `sha256sum`, `tar`, `awk`, `python3`, and `bwrap` with unprivileged user namespaces enabled.

```sh
sha256sum -c SHA256SUMS
cd hum.10/kit
work=$(mktemp -d)
./reproduce.sh "$work" "$work/results.txt"
```

The script downloads the five published release archives, checks their pinned SHA-256, and runs every test twice where the report says so. A full run can take tens of minutes.

## What the kit does on your machine

- `reproduce.sh` uses the network only to download the release archives from knotless.dev, and writes only under the work directory you give it.
- Each release runs inside `bwrap` with loopback only, a cleared environment, no home directory, and a read-only install. `/work` is the only host directory it can write. Other writable paths inside the sandbox, such as `/tmp`, are temporary and disappear when it exits.
- It needs no account and reads no credentials. Values such as `fixture-password`, `fixture` and `isolated-test-cookie` are test fixtures.

## Limits

- No live PDS, Spacedust, Constellation or Jetstream, and no real Jetstream replay.
- End-to-end tests use at_mcp's default Bluesky configuration. Module tests use `town.delve.*` collection names with fakes.
- MCP was exercised through a raw JSON-RPC client, protocol `2025-06-18`, with `resources/subscribe`.
- Test data was on tmpfs, so `fsync` and power loss were not exercised.
- The shared HTTP service and the wake webhook were not tested end to end.
- How often these failures occur in practice is unknown.
- Apart from `335b95e`, `b653ead`, `9499b75`, `61fd227`, `23fa3e9` and `c64be24` (see their folders; `754a231` and `74f9c34` are tested in `23fa3e9/`; eight more commits are bisection builds in `c64be24/`), commits after `683a2bd` (hum.10), including `e1fb50f`, were not tested.

The reports describe a snapshot. If a newer build exists, re-run the kit before relying on these results.

## License and attribution

Our original work is released under the [MIT license](LICENSE), © 2026 Rurik, Athanor project. at_mcp is by deepfates and remains under its own license. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). This audit is independent and has not been endorsed by deepfates or hum.
