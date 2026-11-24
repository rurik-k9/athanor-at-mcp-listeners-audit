#!/bin/bash
# Validates at_mcp commit 9499b75 (hum/next) with the published audit kit, left unmodified, plus the
# supplementary checks of the 335b95e and b653ead validations and new ones for 9499b75.
# 9499b75 has no release. The lib/ modules changed since 0.3.3-hum.11 (335b95e) are compiled inside the
# sandbox with the Elixir of the hum.11 release and overlaid on a copy of it. Three new modules are not in
# the release's boot script, so overlays run with RELEASE_MODE=interactive. A control overlay built the
# same way from 335b95e checks the method against the official hum.11.
# Usage: reproduce_validation.sh EMPTY_WORK_DIR OUTPUT_FILE
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
D=${1:?usage: reproduce_validation.sh EMPTY_WORK_DIR OUTPUT_FILE}; OUT=${2:?output file}
mkdir -p "$D"; D=$(cd "$D" && pwd); : > "$OUT"
KIT_COMMIT=8123ba36ba86e3abe470d611975ce1097b78955b
H10=683a2bd226ee3bacd00af8d4d025017052040e12; H10_SHA=090510cbfa24c96e259c5d1b16d52f3ab3d95de148085b56f3ae8f02fd3d0830
H11=335b95e61a8d76f7e201c16c53c6f6b6fa9fb364; H11_SHA=6a8794466ee006c1b37a9b37ba9e4895ef2b13aae837be0a10e4741de98fe7f5
B653=b653eade156339a8bd89b61fb24c71adb0d8eb77
PRE=030e66fdf9f4b8af72f4e10651a3a8084cd30d43
TARGET=9499b7506db27da20df7ac386414aeb1858eafc9
REL=https://knotless.dev/hum.delve.town/at_mcp/releases/download/at_mcp
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
keep() { grep -E '^RESULT|^DONE' | cut -c1-400 | tee -a "$OUT"; }
export GIT_TERMINAL_PROMPT=0

[ -d "$D/audit" ] || git -c core.hooksPath=/dev/null clone -q https://github.com/rurik-k9/athanor-at-mcp-listeners-audit.git "$D/audit" || exit 1
git -C "$D/audit" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout -q "$KIT_COMMIT" || exit 1
(cd "$D/audit" && sha256sum -c SHA256SUMS --quiet) || { say "KIT MANIFEST MISMATCH"; exit 1; }
KIT=$D/audit/hum.10/kit
[ -d "$D/at_mcp.git" ] || git -c core.hooksPath=/dev/null clone -q --bare https://knotless.dev/hum.delve.town/at_mcp.git "$D/at_mcp.git" || exit 1
for v in 10:$H10_SHA 11:$H11_SHA; do
  n=${v%%:*}; sha=${v#*:}; F=at_mcp-0.3.3-hum.$n-linux-x86_64.tar.gz
  [ -e "$D/$F" ] || { src=$(eval echo "\${AT_MCP_TARBALL_$n:-}"); if [ -n "$src" ]; then cp "$src" "$D/$F"; else curl -sSfL --proto '=https' -o "$D/$F" "$REL/0.3.3-hum.$n/$F"; fi; }
  echo "$sha  $D/$F" | sha256sum -c - >/dev/null || { say "RELEASE CHECKSUM MISMATCH hum.$n"; exit 1; }
  mkdir -p "$D/official$n"; [ -d "$D/official$n/at_mcp" ] || tar -xzf "$D/$F" -C "$D/official$n" --no-same-owner --no-same-permissions
done
say "kit commit: $KIT_COMMIT"
say "releases: 0.3.3-hum.10 ($H10) sha256 $H10_SHA; 0.3.3-hum.11 ($H11) sha256 $H11_SHA"
say "overlays on hum.11: control $H11, b653ead $B653, pre-review $PRE, target $TARGET"
CHANGED=$(git -C "$D/at_mcp.git" diff --name-only "$H11" "$TARGET" -- lib)
say "lib files changed from hum.11 to the target: $(echo $CHANGED | wc -w)"

overlay() {  # name commit
  local n=$1 c=$2 B f
  B="$D/$n"; rm -rf "$B/src"; mkdir -p "$B/src" "$B/work"
  for f in $CHANGED; do
    if git -C "$D/at_mcp.git" cat-file -e "$c:$f" 2>/dev/null; then
      mkdir -p "$B/src/$(dirname "${f#lib/at_mcp/}")"; git -C "$D/at_mcp.git" show "$c:$f" > "$B/src/${f#lib/at_mcp/}" || exit 1
    fi
  done
  cp "$HERE/compile_overlay.exs" "$B/work/"
  "$KIT/box.sh" "$D/official11/at_mcp" "$B/work" --ro-bind "$B/src" /src --setenv OVERLAY_OUT /work/out --setenv OVERLAY_SRC /src -- \
    timeout 300 /rel/bin/at_mcp eval 'Code.eval_file("/work/compile_overlay.exs")' 2>&1 | grep -E '^COMPILED|^FAILED' | cut -c1-200 | tee -a "$OUT"
  ls "$B"/work/out/*.beam >/dev/null 2>&1 || { say "COMPILE FAILED $n"; exit 1; }
  mkdir -p "$B/rel"; [ -d "$B/rel/at_mcp" ] || cp -a "$D/official11/at_mcp" "$B/rel/at_mcp"
  chmod -R u+w "$B/rel/at_mcp"
  cp "$B"/work/out/*.beam "$B"/rel/at_mcp/lib/at_mcp-0.3.3-hum.11/ebin/
  printf '0.3.3-hum.11-%s-overlay\n' "${c:0:7}" > "$B/rel/at_mcp/BUILD"
  say "overlay $n from ${c:0:7}: $(cd "$B/work/out" && sha256sum *.beam | awk '{print substr($1,1,12) " " $2}' | sed 's/Elixir.AtMcp.//' | tr '\n' ' ')"
}
overlay control "$H11"
overlay b653 "$B653"
overlay prereview "$PRE"
overlay candidate "$TARGET"
rel() { case "$1" in official10|official11) echo "$D/$1/at_mcp" ;; *) echo "$D/$1/rel/at_mcp" ;; esac; }
mode() { case "$1" in official10|official11) ;; *) echo "--setenv RELEASE_MODE interactive" ;; esac; }
boxb() { local b=$1 w=$2; shift 2; "$KIT/box.sh" "$(rel "$b")" "$w" $(mode "$b") "$@"; }

# BUILDS and QUICK (only the 9499b75 checks) exist for development; the published results use the defaults.
for b in ${BUILDS:-official11 control b653 prereview candidate}; do
  W=$D/run-$b; mkdir -p "$W"; cp "$KIT"/*.exs "$KIT"/e2e_stdio.py "$HERE"/*_test.exs "$W/"
  box() { boxb "$b" "$W" "$@"; }
  say ""; say "=== $b  build $(cat "$(rel "$b")/BUILD")"
  [ -n "${QUICK:-}" ] && { box -- timeout 240 /rel/bin/at_mcp eval 'Code.eval_file("/work/x9499_test.exs")' 2>&1 | keep; continue; }
  for run in 1 2; do
    say "--- backfill scenarios, run $run"; rm -rf "$W"/backfill-*
    box -- timeout 80 /rel/bin/at_mcp eval 'Code.eval_file("/work/backfill_test.exs")' 2>&1 | keep
    say "--- features, run $run"; rm -rf "$W"/f-*
    box -- timeout 170 /rel/bin/at_mcp eval 'Code.eval_file("/work/features_test.exs")' 2>&1 | keep
    say "--- review defects, run $run"; rm -rf "$W"/r-*
    box -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/review_test.exs")' 2>&1 | keep
    say "--- validation supplement (335b95e), run $run"; rm -rf "$W"/v-*
    box -- timeout 170 /rel/bin/at_mcp eval 'Code.eval_file("/work/validation_test.exs")' 2>&1 | keep
    say "--- b653ead checks, run $run"; rm -rf "$W"/v-w*
    box -- timeout 170 /rel/bin/at_mcp eval 'Code.eval_file("/work/b653ead_test.exs")' 2>&1 | keep
    say "--- 9499b75 checks, run $run"; rm -rf "$W"/v-x*
    box -- timeout 240 /rel/bin/at_mcp eval 'Code.eval_file("/work/x9499_test.exs")' 2>&1 | keep
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

W=$D/run-phases; mkdir -p "$W"; cp "$HERE"/upgrade_test.exs "$HERE"/phases_test.exs "$W/"
say ""; say "=== upgrade (U, unchanged): state written by one build, then started by another"
for pair in official11:official11 official10:candidate official11:candidate candidate:candidate official11:b653 official11:prereview; do
  from=${pair%%:*}; to=${pair#*:}
  for run in 1 2; do
    say "--- upgrade $from -> $to, run $run"; rm -rf "$W/u-state"
    boxb "$from" "$W" --setenv PHASE 1 -- timeout 120 /rel/bin/at_mcp eval 'Code.eval_file("/work/upgrade_test.exs")' 2>&1 | keep
    boxb "$to" "$W" --setenv PHASE 2 -- timeout 120 /rel/bin/at_mcp eval 'Code.eval_file("/work/upgrade_test.exs")' 2>&1 | keep
  done
done
say ""; say "=== migration: earlier state, account B absent at the first start, then repeated starts"
for spec in official11:candidate:0 official10:candidate:0 official11:candidate:1 official11:prereview:0 official11:prereview:1 official11:b653:0; do
  IFS=: read -r from to live <<< "$spec"
  for run in 1 2; do
    say "--- migrate $from -> $to, live save first=$live, run $run"; rm -rf "$W/p-state"
    boxb "$from" "$W" --setenv TEST migrate --setenv STEP 1 -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/phases_test.exs")' 2>&1 | keep
    for s in 2 3 4; do
      boxb "$to" "$W" --setenv TEST migrate --setenv STEP $s --setenv LIVE "$live" -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/phases_test.exs")' 2>&1 | keep
    done
  done
done
say ""; say "=== U on a state written by the same build, receipts saved after their records' dates"
for to in candidate prereview; do
  for run in 1 2; do
    say "--- selfstate $to, run $run"; rm -rf "$W/p-state"
    for s in 1 2; do boxb "$to" "$W" --setenv TEST selfstate --setenv STEP $s -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/phases_test.exs")' 2>&1 | keep; done
  done
done
say ""; say "=== rollback: earlier build, new build, earlier build again, new build again"
for to in candidate prereview; do
  for run in 1 2; do
    say "--- rollback official11 -> $to -> official11 -> $to, run $run"; rm -rf "$W/p-state"
    i=1; for b in official11 "$to" official11 "$to"; do
      boxb "$b" "$W" --setenv TEST rollback --setenv STEP $i -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/phases_test.exs")' 2>&1 | keep
      i=$((i + 1))
    done
  done
done
(cd "$D/audit" && sha256sum -c SHA256SUMS --quiet && git status --porcelain | wc -l | sed 's/^/kit files changed: /') | tee -a "$OUT"
say ""; say "FINISHED"
