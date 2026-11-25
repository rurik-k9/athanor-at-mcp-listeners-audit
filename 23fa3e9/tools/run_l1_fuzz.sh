#!/bin/bash
# Runs tools/l1_fuzz.exs on the builds of a campaign work dir made by reproduce_validation.sh. Usage: run_l1_fuzz.sh WORKDIR OUT [SEEDS] [BUILDS]
set -u
HERE=$(cd "$(dirname "$0")" && pwd); D=$1; OUT=$2; SEEDS=${3:-400}; BUILDS=${4:-"previous l1only candidate proposal"}
KIT=$D/audit/hum.10/kit; : > "$OUT"
for b in $BUILDS; do
  W=$(mktemp -d "$D/fuzz-$b.XXXX"); cp "$HERE/l1_fuzz.exs" "$W/"
  echo "=== $b, $SEEDS seeds per family" | tee -a "$OUT"
  "$KIT/box.sh" "$D/$b/rel/at_mcp" "$W" --setenv RELEASE_MODE interactive --setenv FUZZ_SEEDS "$SEEDS" --setenv FUZZ_OUT /work/failures.jsonl -- \
    timeout 3000 /rel/bin/at_mcp eval 'Code.eval_file("/work/l1_fuzz.exs")' 2>&1 | grep -E '^RESULT|^DONE' | cut -c1-900 | tee -a "$OUT"
  cp "$W/failures.jsonl" "${OUT%.txt}-$b-failures.jsonl" 2>/dev/null
done
echo FINISHED | tee -a "$OUT"
