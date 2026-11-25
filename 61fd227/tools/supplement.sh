#!/bin/bash
# Supplementary checks run after reproduce_validation.sh, on the builds it made:
#   z_walks_test.exs    the oldest-first read walked against a strict and a non-strict service (Z1-Z6);
#   x5_clock_test.exs   X5 with which records come back, then with the local clock past the records' times;
#   y1_timing_test.exs  Y1 with the held count printed before and after the settle sleep (2.5 s and 8 s);
#   x3_place_test.exs   X3 with the damaged entry at the head, between two receipts, or at the tail.
# Usage: tools/supplement.sh WORKDIR_OF_A_CAMPAIGN OUTPUT [BUILDS]
set -u
HERE=$(cd "$(dirname "$0")" && pwd); D=$1; OUT=$2; BUILDS=${3:-"previous prefix candidate proposal"}
KIT=$D/audit/hum.10/kit  # the published kit, cloned by reproduce_validation.sh
: > "$OUT"
for b in $BUILDS; do
  echo "=== $b" | tee -a "$OUT"
  for t in z_walks_test x5_clock_test y1_timing_test x3_place_test; do
    for run in 1 2; do
      W=$(mktemp -d "$D/supp-$b-$t-$run.XXXX"); cp "$HERE/$t.exs" "$W/"
      echo "--- $t, run $run" | tee -a "$OUT"
      "$KIT/box.sh" "$D/$b/rel/at_mcp" "$W" --setenv RELEASE_MODE interactive -- timeout 290 /rel/bin/at_mcp eval "Code.eval_file(\"/work/$t.exs\")" 2>&1 \
        | grep -E '^RESULT|^DONE' | cut -c1-700 | tee -a "$OUT"
    done
  done
done
echo FINISHED | tee -a "$OUT"
