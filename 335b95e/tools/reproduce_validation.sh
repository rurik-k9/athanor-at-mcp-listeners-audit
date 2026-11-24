#!/bin/bash
# Validates at_mcp commit 335b95e with the published audit kit, left unmodified.
# 335b95e has no release, so its two changed modules are compiled inside the
# sandbox and overlaid on a copy of the published hum.10 release. A control
# overlay, built the same way from hum.10's own source, checks the method.
# Usage: reproduce_validation.sh EMPTY_WORK_DIR OUTPUT_FILE
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
D=${1:?usage: reproduce_validation.sh EMPTY_WORK_DIR OUTPUT_FILE}; OUT=${2:?output file}
mkdir -p "$D"; D=$(cd "$D" && pwd); : > "$OUT"
KIT_COMMIT=8123ba36ba86e3abe470d611975ce1097b78955b
BASE=683a2bd226ee3bacd00af8d4d025017052040e12
TARGET=335b95e61a8d76f7e201c16c53c6f6b6fa9fb364
SHA=090510cbfa24c96e259c5d1b16d52f3ab3d95de148085b56f3ae8f02fd3d0830
F=at_mcp-0.3.3-hum.10-linux-x86_64.tar.gz
URL=https://knotless.dev/hum.delve.town/at_mcp/releases/download/at_mcp/0.3.3-hum.10/$F
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
keep() { grep -E '^RESULT|^DONE' | cut -c1-260 | tee -a "$OUT"; }
export GIT_TERMINAL_PROMPT=0

[ -d "$D/audit" ] || git -c core.hooksPath=/dev/null clone -q https://github.com/rurik-k9/athanor-at-mcp-listeners-audit.git "$D/audit" || exit 1
git -C "$D/audit" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout -q "$KIT_COMMIT" || exit 1
(cd "$D/audit" && sha256sum -c SHA256SUMS --quiet) || { say "KIT MANIFEST MISMATCH"; exit 1; }
KIT=$D/audit/hum.10/kit
[ -d "$D/at_mcp.git" ] || git -c core.hooksPath=/dev/null clone -q --bare https://knotless.dev/hum.delve.town/at_mcp.git "$D/at_mcp.git" || exit 1
[ -e "$D/$F" ] || { if [ -n "${AT_MCP_TARBALL:-}" ]; then cp "$AT_MCP_TARBALL" "$D/$F"; else curl -sSfL --proto '=https' -o "$D/$F" "$URL"; fi; }
echo "$SHA  $D/$F" | sha256sum -c - >/dev/null || { say "RELEASE CHECKSUM MISMATCH"; exit 1; }
mkdir -p "$D/official"; [ -d "$D/official/at_mcp" ] || tar -xzf "$D/$F" -C "$D/official" --no-same-owner --no-same-permissions
say "kit commit: $KIT_COMMIT"; say "base release: 0.3.3-hum.10 ($BASE) sha256 $SHA"; say "target commit: $TARGET"

overlay() {  # name commit
  local n=$1 c=$2 B
  B="$D/$n"; mkdir -p "$B/src" "$B/work"
  for f in listeners repos; do git -C "$D/at_mcp.git" show "$c:lib/at_mcp/$f.ex" > "$B/src/$f.ex" || exit 1; done
  cp "$HERE/compile_overlay.exs" "$B/work/"
  "$KIT/box.sh" "$D/official/at_mcp" "$B/work" --ro-bind "$B/src" /src --setenv OVERLAY_OUT /work/out --setenv OVERLAY_SRC /src -- \
    timeout 170 /rel/bin/at_mcp eval 'Code.eval_file("/work/compile_overlay.exs")' 2>&1 | grep -E '^COMPILED|^FAILED' | tee -a "$OUT"
  [ -f "$B/work/out/Elixir.AtMcp.Listeners.beam" ] && [ -f "$B/work/out/Elixir.AtMcp.Repos.beam" ] || { say "COMPILE FAILED $n"; exit 1; }
  mkdir -p "$B/rel"; [ -d "$B/rel/at_mcp" ] || cp -a "$D/official/at_mcp" "$B/rel/at_mcp"
  chmod -R u+w "$B/rel/at_mcp"
  cp "$B"/work/out/*.beam "$B"/rel/at_mcp/lib/at_mcp-0.3.3-hum.10/ebin/
  printf '0.3.3-hum.10-%s-overlay\n' "${c:0:7}" > "$B/rel/at_mcp/BUILD"
  say "overlay $n from ${c:0:7}: $(cd "$B/work/out" && sha256sum *.beam | awk '{print substr($1,1,16) " " $2}' | tr '\n' ' ')"
}
overlay control "$BASE"
overlay candidate "$TARGET"

for b in official control candidate; do
  if [ "$b" = official ]; then REL=$D/official/at_mcp; else REL=$D/$b/rel/at_mcp; fi
  W=$D/run-$b; mkdir -p "$W"; cp "$KIT"/*.exs "$KIT"/e2e_stdio.py "$HERE/validation_test.exs" "$W/"
  box() { "$KIT/box.sh" "$REL" "$W" "$@"; }
  say ""; say "=== $b  build $(cat "$REL/BUILD")"
  for run in 1 2; do
    say "--- backfill scenarios, run $run"; rm -rf "$W"/backfill-*
    box -- timeout 80 /rel/bin/at_mcp eval 'Code.eval_file("/work/backfill_test.exs")' 2>&1 | keep
    say "--- features, run $run"; rm -rf "$W"/f-*
    box -- timeout 170 /rel/bin/at_mcp eval 'Code.eval_file("/work/features_test.exs")' 2>&1 | keep
    say "--- review defects, run $run"; rm -rf "$W"/r-*
    box -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/review_test.exs")' 2>&1 | keep
    say "--- validation supplement, run $run"; rm -rf "$W"/v-*
    box -- timeout 170 /rel/bin/at_mcp eval 'Code.eval_file("/work/validation_test.exs")' 2>&1 | keep
    say "--- real at_mcp-stdio, fake services, run $run"; rm -rf "$W/e2e"
    box -- timeout 320 /usr/bin/python3 -I -u /work/e2e_stdio.py 2>&1 | keep
  done
  say "--- store checks"; box -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/store_test.exs")' 2>&1 | keep
  say "--- 25 hard kills during writes"; rm -rf "$W/kill"; mkdir -p "$W/kill"; next=1
  for i in $(seq 1 25); do
    box --setenv KILL_DIR /work/kill --setenv KILL_START "$next" -- timeout -s KILL "$(awk -v i="$i" 'BEGIN{printf "%.2f", 1.6 + (i%5)*0.17}')" \
      /rel/bin/at_mcp eval 'Code.eval_file("/work/kill_writer.exs")' >/dev/null 2>&1 || true
    n=$(wc -l < "$W/kill/journal" 2>/dev/null || echo 0); next=$((n + 100000 * i + 1))
  done
  box --setenv KILL_DIR /work/kill -- timeout 60 /rel/bin/at_mcp eval 'Code.eval_file("/work/kill_check.exs")' 2>&1 | keep
done
(cd "$D/audit" && sha256sum -c SHA256SUMS --quiet && git status --porcelain | wc -l | sed 's/^/kit files changed: /') | tee -a "$OUT"
say ""; say "FINISHED"
