#!/bin/bash
# Validates at_mcp commit 23fa3e9 (hum/next) with the published audit kit, left unmodified, the supplementary checks of
# the 335b95e, b653ead, 9499b75 and 61fd227 validations, and new ones (L1 fuzz, M2 phases). 23fa3e9 has no published release: the lib/ modules changed
# since 0.3.3-hum.11 (335b95e) are compiled in the sandbox with the Elixir of hum.11 and overlaid on a copy of it,
# in RELEASE_MODE=interactive (new modules are not in hum.11's boot script). A control overlay from 335b95e checks the
# method. Builds: previous = 61fd227, l1only = 754a231, m2first = 74f9c34, candidate = 23fa3e9; "proposal" is 61fd227 with our
# experimental patch of the 61fd227 validation (tools/proposal-61fd227.patch), for comparison: not hum's code.
# Usage: reproduce_validation.sh EMPTY_WORK_DIR OUTPUT_FILE
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
D=${1:?usage: reproduce_validation.sh EMPTY_WORK_DIR OUTPUT_FILE}; OUT=${2:?output file}
mkdir -p "$D"; D=$(cd "$D" && pwd); : > "$OUT"
KIT_COMMIT=8123ba36ba86e3abe470d611975ce1097b78955b
H10=683a2bd226ee3bacd00af8d4d025017052040e12; H10_SHA=090510cbfa24c96e259c5d1b16d52f3ab3d95de148085b56f3ae8f02fd3d0830
H11=335b95e61a8d76f7e201c16c53c6f6b6fa9fb364; H11_SHA=6a8794466ee006c1b37a9b37ba9e4895ef2b13aae837be0a10e4741de98fe7f5
PREV=61fd227dd51afa0884e6df2fc6d1534a33cf4711
L1C=754a231998988e26472b904e8309e9bfda3df346
M2C=74f9c342739be12e67ddda39c08dfd8fee8cce50
TARGET=23fa3e93d1968b8baffdf7f6e9b905794cc74b0c
REL=https://knotless.dev/hum.delve.town/at_mcp/releases/download/at_mcp
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
keep() { grep -E '^RESULT|^DONE' | cut -c1-460 | tee -a "$OUT"; }
export GIT_TERMINAL_PROMPT=0

[ -d "$D/audit" ] || git -c core.hooksPath=/dev/null clone -q https://github.com/rurik-k9/athanor-at-mcp-listeners-audit.git "$D/audit" || exit 1
git -C "$D/audit" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout -q "$KIT_COMMIT" || exit 1
(cd "$D/audit" && sha256sum -c SHA256SUMS --quiet) || { say "KIT MANIFEST MISMATCH"; exit 1; }
KIT=$D/audit/hum.10/kit
[ -d "$D/at_mcp.git" ] || git -c core.hooksPath=/dev/null clone -q --bare https://knotless.dev/hum.delve.town/at_mcp.git "$D/at_mcp.git" || exit 1
for c in $PREV $L1C $M2C $TARGET; do git -C "$D/at_mcp.git" cat-file -e "$c^{commit}" || { say "COMMIT MISSING $c"; exit 1; }; done
for v in 10:$H10_SHA 11:$H11_SHA; do
  n=${v%%:*}; sha=${v#*:}; F=at_mcp-0.3.3-hum.$n-linux-x86_64.tar.gz
  [ -e "$D/$F" ] || { src=$(eval echo "\${AT_MCP_TARBALL_$n:-}"); if [ -n "$src" ]; then cp "$src" "$D/$F"; else curl -sSfL --proto '=https' -o "$D/$F" "$REL/0.3.3-hum.$n/$F"; fi; }
  echo "$sha  $D/$F" | sha256sum -c - >/dev/null || { say "RELEASE CHECKSUM MISMATCH hum.$n"; exit 1; }
  mkdir -p "$D/official$n"; [ -d "$D/official$n/at_mcp" ] || tar -xzf "$D/$F" -C "$D/official$n" --no-same-owner --no-same-permissions
done
say "kit commit: $KIT_COMMIT"
say "releases: 0.3.3-hum.10 ($H10) sha256 $H10_SHA; 0.3.3-hum.11 ($H11) sha256 $H11_SHA"
say "overlays on hum.11: control $H11, previous $PREV, l1only $L1C, m2first $M2C, target $TARGET, proposal = previous + proposal-61fd227.patch $(sha256sum "$HERE/proposal-61fd227.patch" | cut -c1-16)"
CHANGED=$(git -C "$D/at_mcp.git" diff --name-only "$H11" "$TARGET" -- lib)
say "lib files changed from hum.11 to the target: $(echo $CHANGED | wc -w)"

overlay() {  # name commit [patch]
  local n=$1 c=$2 p=${3:-} B f
  B="$D/$n"; rm -rf "$B/src" "$B/work/out"; mkdir -p "$B/src" "$B/work"
  for f in $CHANGED; do
    if git -C "$D/at_mcp.git" cat-file -e "$c:$f" 2>/dev/null; then
      mkdir -p "$B/src/$(dirname "${f#lib/at_mcp/}")"; git -C "$D/at_mcp.git" show "$c:$f" > "$B/src/${f#lib/at_mcp/}" || exit 1
    fi
  done
  if [ -n "$p" ]; then patch -p3 -s -d "$B/src" -i "$p" || { say "PATCH FAILED $n"; exit 1; }; fi
  cp "$HERE/compile_overlay.exs" "$B/work/"
  "$KIT/box.sh" "$D/official11/at_mcp" "$B/work" --ro-bind "$B/src" /src --setenv OVERLAY_OUT /work/out --setenv OVERLAY_SRC /src -- \
    timeout 300 /rel/bin/at_mcp eval 'Code.eval_file("/work/compile_overlay.exs")' 2>&1 | grep -E '^COMPILED|^FAILED' | cut -c1-200 | tee -a "$OUT"
  ls "$B"/work/out/*.beam >/dev/null 2>&1 || { say "COMPILE FAILED $n"; exit 1; }
  rm -rf "$B/rel"; mkdir -p "$B/rel"; cp -a "$D/official11/at_mcp" "$B/rel/at_mcp"; chmod -R u+w "$B/rel/at_mcp"
  cp "$B"/work/out/*.beam "$B"/rel/at_mcp/lib/at_mcp-0.3.3-hum.11/ebin/
  printf '0.3.3-hum.11-%s%s-overlay\n' "${c:0:7}" "${p:+-proposal}" > "$B/rel/at_mcp/BUILD"
  say "overlay $n from ${c:0:7}${p:+ + patch}: $(cd "$B/work/out" && sha256sum *.beam | awk '{print substr($1,1,12) " " $2}' | sed 's/Elixir.AtMcp.//' | tr '\n' ' ')"
}
overlay control "$H11"
overlay previous "$PREV"
overlay l1only "$L1C"
overlay m2first "$M2C"
overlay candidate "$TARGET"
overlay proposal "$PREV" "$HERE/proposal-61fd227.patch"
[ -n "${BUILD_ONLY:-}" ] && { say "BUILT"; exit 0; }
rel() { case "$1" in official10|official11) echo "$D/$1/at_mcp" ;; *) echo "$D/$1/rel/at_mcp" ;; esac; }
mode() { case "$1" in official10|official11) ;; *) echo "--setenv RELEASE_MODE interactive" ;; esac; }
boxb() { local b=$1 w=$2; shift 2; "$KIT/box.sh" "$(rel "$b")" "$w" $(mode "$b") "$@"; }

for b in ${BUILDS:-official11 control previous l1only m2first candidate proposal}; do
  W=$D/run-$b; mkdir -p "$W"; cp "$KIT"/*.exs "$KIT"/e2e_stdio.py "$HERE"/*_test.exs "$HERE"/e2e_h6x.py "$W/"
  box() { boxb "$b" "$W" "$@"; }
  say ""; say "=== $b  build $(cat "$(rel "$b")/BUILD")"
  for run in 1 2; do
    if [ -z "${QUICK:-}" ]; then
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
    fi
    say "--- 61fd227 checks, run $run"; rm -rf "$W"/v-y*
    box -- timeout 300 /rel/bin/at_mcp eval 'Code.eval_file("/work/x61fd_test.exs")' 2>&1 | keep
    if [ -z "${QUICK:-}" ]; then
      say "--- real at_mcp-stdio, fake services, run $run"; rm -rf "$W/e2e"
      box -- timeout 320 /usr/bin/python3 -I -u /work/e2e_stdio.py 2>&1 | keep
    fi
    say "--- seenAt at its edges (real at_mcp-stdio), run $run"; rm -rf "$W/e2e"
    box -- timeout 320 /usr/bin/python3 -I -u /work/e2e_h6x.py 2>&1 | keep
  done
  [ -n "${QUICK:-}" ] && continue
  say "--- store checks"; box -- timeout 150 /rel/bin/at_mcp eval 'Code.eval_file("/work/store_test.exs")' 2>&1 | keep
  say "--- 25 hard kills during writes"; rm -rf "$W/kill"; mkdir -p "$W/kill"; next=1
  for i in $(seq 1 25); do
    box --setenv KILL_DIR /work/kill --setenv KILL_START "$next" -- timeout -s KILL "$(awk -v i="$i" 'BEGIN{printf "%.2f", 1.6 + (i%5)*0.17}')" \
      /rel/bin/at_mcp eval 'Code.eval_file("/work/kill_writer.exs")' >/dev/null 2>&1 || true
    n=$(wc -l < "$W/kill/journal" 2>/dev/null || echo 0); next=$((n + 100000 * i + 1))
  done
  box --setenv KILL_DIR /work/kill -- timeout 60 /rel/bin/at_mcp eval 'Code.eval_file("/work/kill_check.exs")' 2>&1 | keep
done

W=$D/run-phases; mkdir -p "$W"; cp "$HERE"/upgrade_test.exs "$HERE"/phases_test.exs "$HERE"/phases61_test.exs "$W/"
ph() { local b=$1; shift; boxb "$b" "$W" "$@" -- timeout 200 /rel/bin/at_mcp eval "Code.eval_file(\"/work/$PHFILE\")" 2>&1 | keep; }
say ""; say "=== upgrade (U, unchanged)"
for pair in official11:official11 official10:candidate official11:candidate candidate:candidate official11:proposal official10:proposal proposal:proposal; do
  from=${pair%%:*}; to=${pair#*:}
  for run in 1 2; do
    say "--- upgrade $from -> $to, run $run"; rm -rf "$W/u-state"; PHFILE=upgrade_test.exs
    ph "$from" --setenv PHASE 1; ph "$to" --setenv PHASE 2
  done
done
say ""; say "=== migration (M, unchanged): B absent at the first start, then repeated starts"
for spec in official11:previous:1 official11:m2first:1 official11:candidate:0 official10:candidate:0 official11:candidate:1 official11:proposal:1; do
  IFS=: read -r from to live <<< "$spec"
  for run in 1 2; do
    say "--- migrate $from -> $to, live save first=$live, run $run"; rm -rf "$W/p-state"; PHFILE=phases_test.exs
    ph "$from" --setenv TEST migrate --setenv STEP 1
    for s in 2 3 4; do ph "$to" --setenv TEST migrate --setenv STEP $s --setenv LIVE "$live"; done
  done
done
say ""; say "=== self-state (S, unchanged)"
for to in previous candidate; do
  for run in 1 2; do
    say "--- selfstate $to, run $run"; rm -rf "$W/p-state"; PHFILE=phases_test.exs
    for s in 1 2; do ph "$to" --setenv TEST selfstate --setenv STEP $s; done
  done
done
say ""; say "=== rollback (R, unchanged): earlier build, new, earlier again, new again"
for to in previous m2first candidate proposal; do
  for run in 1 2; do
    say "--- rollback official11 -> $to -> official11 -> $to, run $run"; rm -rf "$W/p-state"; PHFILE=phases_test.exs
    i=1; for b in official11 "$to" official11 "$to"; do ph "$b" --setenv TEST rollback --setenv STEP $i; i=$((i + 1)); done
  done
done
say ""; say "=== M2 sweep: late mentions across the margin, first start after an upgrade from hum.11"
for spec in previous:0 previous:1 m2first:0 m2first:1 candidate:0 candidate:1 proposal:0 proposal:1; do
  IFS=: read -r to live <<< "$spec"
  for run in 1 2; do
    say "--- m2 official11 -> $to, live save first=$live, run $run"; rm -rf "$W/q-state"; PHFILE=phases61_test.exs
    ph official11 --setenv TEST m2 --setenv STEP 1
    for s in 2 3; do ph "$to" --setenv TEST m2 --setenv STEP $s --setenv LIVE "$live"; done
  done
done
say ""; say "=== review duplicates F1 and F2: new build, then hum.11 (rollback), then the new build again"
for t in f1 f2; do
  for to in previous m2first candidate proposal; do
    for run in 1 2; do
      say "--- $t: $to -> official11 -> $to, run $run"; rm -rf "$W/q-state"; PHFILE=phases61_test.exs
      ph "$to" --setenv TEST $t --setenv STEP 1; ph official11 --setenv TEST $t --setenv STEP 2; ph "$to" --setenv TEST $t --setenv STEP 3
    done
  done
done
(cd "$D/audit" && sha256sum -c SHA256SUMS --quiet && git status --porcelain | wc -l | sed 's/^/kit files changed: /') | tee -a "$OUT"
say ""; say "FINISHED"
