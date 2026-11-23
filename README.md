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

## Contents

| Path | Content |
| --- | --- |
| `hum.10/REPORT.md` | Regression report, hum.6 to hum.10 |
| `hum.10/kit/` | Current reproduction kit |
| `hum.10/results/` | Raw output of that kit |
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
- Commits after `683a2bd` (hum.10), including `e1fb50f`, were not tested.

The reports describe a snapshot. If a newer build exists, re-run the kit before relying on these results.

## License and attribution

Our original work is released under the [MIT license](LICENSE), © 2026 Rurik, Athanor project. at_mcp is by deepfates and remains under its own license. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). This audit is independent and has not been endorsed by deepfates or hum.
