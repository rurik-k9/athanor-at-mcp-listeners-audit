#!/bin/bash
# Supplementary checks run after reproduce_validation.sh, on the builds it made (each twice):
#   l1_fuzz.exs with FUZZ_CASES  deterministic cases W1-W7 (service variants, time cursors, the held-back cap);
#   l1_text_test.exs             oldest-first walks through AtMcp.MCP.Tools.page/5, text cut and json fallback;
#   z_walks_test.exs, x5_clock_test.exs, y1_timing_test.exs, x3_place_test.exs (as in the 61fd227 validation);
#   x3_limit_test.exs            X3 as a two-sided known-limit test.
# Usage: tools/supplement23.sh WORKDIR OUTPUT [BUILDS] [TESTS]
set -u
HERE=$(cd "$(dirname "$0")" && pwd); D=$1; OUT=$2; BUILDS=${3:-"previous l1only m2first candidate proposal"}
TESTS=${4:-"cases l1_text_test z_walks_test x5_clock_test y1_timing_test x3_place_test x3_limit_test"}
KIT=$D/audit/hum.10/kit; : > "$OUT"
for b in $BUILDS; do
  echo "=== $b" | tee -a "$OUT"
  for t in $TESTS; do
    for run in 1 2; do
      W=$(mktemp -d "$D/supp-$b-$t-$run.XXXX"); env=()
      if [ "$t" = cases ]; then cp "$HERE/l1_fuzz.exs" "$W/"; f=l1_fuzz; env=(--setenv FUZZ_CASES 1); else cp "$HERE/$t.exs" "$W/"; f=$t; fi
      [ "$t" = l1_text_test ] && env=(--setenv TEXT_SEEDS 300)
      echo "--- $t, run $run" | tee -a "$OUT"
      "$KIT/box.sh" "$D/$b/rel/at_mcp" "$W" --setenv RELEASE_MODE interactive "${env[@]}" -- timeout 1200 /rel/bin/at_mcp eval "Code.eval_file(\"/work/$f.exs\")" 2>&1 \
        | grep -E '^RESULT|^DONE' | cut -c1-700 | tee -a "$OUT"
    done
  done
done
echo FINISHED | tee -a "$OUT"
