#!/bin/bash
# M2 phases of tools/phases23_test.exs: hum.11 writes the earlier state, then each build runs the later steps.
# Usage: run_phases23.sh WORKDIR OUT [BUILDS]
set -u
HERE=$(cd "$(dirname "$0")" && pwd); D=$1; OUT=$2; BUILDS=${3:-"previous m2first candidate proposal proposal23"}
KIT=$D/audit/hum.10/kit; : > "$OUT"
rel() { case "$1" in official10|official11) echo "$D/$1/at_mcp" ;; *) echo "$D/$1/rel/at_mcp" ;; esac; }
mode() { case "$1" in official10|official11) ;; *) echo "--setenv RELEASE_MODE interactive" ;; esac; }
W=$D/run-phases23; mkdir -p "$W"; cp "$HERE/phases23_test.exs" "$W/"
ph() { local b=$1; shift; "$KIT/box.sh" "$(rel "$b")" "$W" $(mode "$b") "$@" -- timeout 300 /rel/bin/at_mcp eval 'Code.eval_file("/work/phases23_test.exs")' 2>&1 | grep -E '^RESULT|^DONE' | cut -c1-700 | tee -a "$OUT"; }
seq_() { local t=$1 b=$2 n=$3 k=${4:-0}; rm -rf "$W/q-state"; ph official11 --setenv TEST "$t" --setenv STEP 1; for s in $(seq 2 "$n"); do ph "$b" --setenv TEST "$t" --setenv STEP "$s" --setenv K "$k"; done; }
for b in $BUILDS; do
  for run in 1 2; do
    for k in 0 999 1000 1001 1045 1100 2100; do echo "--- sat $b K=$k run $run" | tee -a "$OUT"; seq_ sat "$b" 4 "$k"; done
    echo "--- restart $b run $run" | tee -a "$OUT"; seq_ restart "$b" 6
    echo "--- cutrel $b run $run" | tee -a "$OUT"; seq_ cutrel "$b" 5
    for k in 0 500; do echo "--- records $b K=$k run $run" | tee -a "$OUT"; seq_ records "$b" 3 "$k"; done
    echo "--- pause $b run $run" | tee -a "$OUT"; seq_ pause "$b" 3
    echo "--- unlisten $b run $run" | tee -a "$OUT"; seq_ unlisten "$b" 2
    echo "--- bounds $b run $run" | tee -a "$OUT"; seq_ bounds "$b" 2
  done
done
echo FINISHED | tee -a "$OUT"
