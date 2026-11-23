#!/bin/bash
# Reproduces every at_mcp result of this report on 0.3.3-hum.6, hum.7, hum.8 and
# hum.9 (Linux x86_64). Needs curl, sha256sum, tar, bwrap, python3. Each release runs
# with no external network, no /home, a read-only install and synthetic data.
# Usage: ./reproduce.sh EMPTY_WORK_DIR [OUTPUT_FILE]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
D=${1:?usage: reproduce.sh EMPTY_WORK_DIR [OUTPUT_FILE]}; mkdir -p "$D"; D=$(cd "$D" && pwd)
OUT=${2:-$D/results.txt}; : > "$OUT"
B=https://knotless.dev/hum.delve.town/at_mcp/releases/download/at_mcp
declare -A SHA=(
  [6]=481a62002bc86e698ed4fa27cc18a2adc9924d41d23a16001eb024ba2b956ef1
  [7]=c6650d8c02548b211200c3eaf17a4d8589ef7058291e5e666a6d010eb73bccdd
  [8]=b706a232c297a0b2ab6efe460909940607af0d94338c96663b6972248c7be662
  [9]=ad33f08c8cec38ab18c3d06934fbd14fa3cbc541e388ebf7c083e0117e6756ca
)
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
keep() { grep -E '^RESULT|^DONE' | cut -c1-240 | tee -a "$OUT"; }

for v in 6 7 8 9; do
  V=0.3.3-hum.$v; F=at_mcp-$V-linux-x86_64.tar.gz; R=$D/$V; mkdir -p "$R/x" "$R/work"
  if [ -n "${AT_MCP_TARBALLS:-}" ] && [ -e "$AT_MCP_TARBALLS/$V/$F" ]; then cp "$AT_MCP_TARBALLS/$V/$F" "$R/$F"; fi
  [ -e "$R/$F" ] || curl -sSfL --proto '=https' -o "$R/$F" "$B/$V/$F"
  echo "${SHA[$v]}  $R/$F" | sha256sum -c - >/dev/null || { say "CHECKSUM MISMATCH $V"; exit 1; }
  tar -xzf "$R/$F" -C "$R/x" --no-same-owner --no-same-permissions
  say ""; say "=== $V  build $(cat "$R/x/at_mcp/BUILD")  sha256 ${SHA[$v]}"
  cp "$HERE"/*.exs "$HERE"/e2e_stdio.py "$R/work/"
  box() { "$HERE/box.sh" "$R/x/at_mcp" "$R/work" "$@"; }

  for run in 1 2; do
    say "--- backfill scenarios, run $run"
    rm -rf "$R"/work/backfill-*
    box -- timeout 80 /rel/bin/at_mcp eval 'Code.eval_file("/work/backfill_test.exs")' 2>&1 | keep
  done
  say "--- store checks"
  box -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/store_test.exs")' 2>&1 | keep
  say "--- 25 hard kills during writes"
  rm -rf "$R/work/kill"; mkdir -p "$R/work/kill"; next=1
  for i in $(seq 1 25); do
    box --setenv KILL_DIR /work/kill --setenv KILL_START "$next" -- timeout -s KILL "$(awk -v i="$i" 'BEGIN{printf "%.2f", 1.6 + (i%5)*0.17}')" \
      /rel/bin/at_mcp eval 'Code.eval_file("/work/kill_writer.exs")' >/dev/null 2>&1 || true
    n=$(wc -l < "$R/work/kill/journal" 2>/dev/null || echo 0); next=$((n + 100000 * i + 1))
  done
  box --setenv KILL_DIR /work/kill -- timeout 60 /rel/bin/at_mcp eval 'Code.eval_file("/work/kill_check.exs")' 2>&1 | keep
  if [ "$v" != 6 ]; then
    for run in 1 2; do
      say "--- listener features, run $run"
      rm -rf "$R"/work/f-*
      box -- timeout 170 /rel/bin/at_mcp eval 'Code.eval_file("/work/features_test.exs")' 2>&1 | keep
    done
  fi
  for run in 1 2; do
    say "--- real at_mcp-stdio with a fake PDS and streams, external queue, run $run"
    rm -rf "$R/work/e2e"
    box -- timeout 200 /usr/bin/python3 -I -u /work/e2e_stdio.py 2>&1 | keep
  done
done
say ""; say "FINISHED"
