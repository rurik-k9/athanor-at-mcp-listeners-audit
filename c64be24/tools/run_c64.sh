#!/bin/bash
# Runs test scripts (prelude.exs + TEST.exs, evaluated as one file) on the overlays made by build_c64.sh.
# Usage: run_c64.sh WORKDIR OUTPUT "BUILDS" "TESTS" [ENV=VALUE ...]     e.g. run_c64.sh $W out.txt "previous target" "a1_damaged_state"
set -u
HERE=$(cd "$(dirname "$0")" && pwd); D=$1; OUT=$2; BUILDS=$3; TESTS=$4; shift 4
KIT=$D/audit/hum.10/kit; ENVS=(); for e in "$@"; do ENVS+=(--setenv "${e%%=*}" "${e#*=}"); done
for t in $TESTS; do for b in $BUILDS; do
  W=$(mktemp -d "$D/run-$b-$t.XXXX"); cat "$HERE/prelude.exs" "$HERE/$t.exs" > "$W/t.exs"
  echo "=== $t on $b ($(cat "$D/$b/rel/at_mcp/BUILD")) $*" | tee -a "$OUT"
  "$KIT/box.sh" "$D/$b/rel/at_mcp" "$W" --setenv RELEASE_MODE interactive "${ENVS[@]}" -- timeout 1800 /rel/bin/at_mcp eval 'Code.eval_file("/work/t.exs")' > "$W/raw.txt" 2>&1
  grep -E '^RESULT|^DONE' "$W/raw.txt" | cut -c1-1500 | tee -a "$OUT"
  grep -q '^DONE' "$W/raw.txt" || { echo "NO DONE: last lines:"; tail -15 "$W/raw.txt"; } | tee -a "$OUT"
done; done
