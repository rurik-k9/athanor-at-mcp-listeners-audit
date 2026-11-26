#!/bin/bash
# Reproduces F1-F4 of the c64be24 round from an empty directory. Needs: git, curl, bwrap, sha256sum, network for the
# clone and the release download (the tests themselves run with no network, in bwrap).
# Usage: repro/reproduce.sh EMPTY_WORKDIR [OUTPUT]
#   1. clones knotless.dev/hum.delve.town/at_mcp, checks that c64be24 resolves to the exact commit below;
#   2. downloads the 0.3.3-hum.11 release and checks its sha256;
#   3. compiles, in the sandbox with hum.11's Elixir, the lib/ files changed since hum.11, for each commit below, and
#      overlays them on a copy of the release (RELEASE_MODE=interactive);
#   4. runs each standalone case on the builds that tell its story.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=$(mkdir -p "$1" && cd "$1" && pwd); OUT=${2:-$D/reproduce-output.txt}
[ -z "$(ls -A "$D" | grep -v "$(basename "$OUT")" || true)" ] || { echo "WORKDIR must be empty"; exit 1; }
TARGET=c64be24bc06b7fb44e91369cb8007b2065b8f962
H11=335b95e61a8d76f7e201c16c53c6f6b6fa9fb364
H11_SHA=6a8794466ee006c1b37a9b37ba9e4895ef2b13aae837be0a10e4741de98fe7f5
F=at_mcp-0.3.3-hum.11-linux-x86_64.tar.gz
export GIT_TERMINAL_PROMPT=0
say() { echo "$*" | tee -a "$OUT"; }
git -c core.hooksPath=/dev/null clone -q --bare https://knotless.dev/hum.delve.town/at_mcp.git "$D/at_mcp.git"
git -C "$D/at_mcp.git" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
[ "$(git -C "$D/at_mcp.git" rev-parse c64be24)" = "$TARGET" ] || { say "c64be24 does not resolve to $TARGET"; exit 1; }
git -C "$D/at_mcp.git" merge-base --is-ancestor "$TARGET" origin/hum/next && say "c64be24 = $TARGET, on hum/next"
curl -sSfL --proto '=https' -o "$D/$F" "https://knotless.dev/hum.delve.town/at_mcp/releases/download/at_mcp/0.3.3-hum.11/$F"
echo "$H11_SHA  $D/$F" | sha256sum -c - >/dev/null && say "0.3.3-hum.11 release sha256 OK"
mkdir -p "$D/official/rel"; tar -xzf "$D/$F" -C "$D/official/rel" --no-same-owner --no-same-permissions
overlay() {  # name commit
  local n=$1 c; c=$(git -C "$D/at_mcp.git" rev-parse "$2^{commit}"); local B=$D/$n
  mkdir -p "$B/src" "$B/work"
  for f in $(git -C "$D/at_mcp.git" diff --name-only "$H11" "$c" -- lib); do
    git -C "$D/at_mcp.git" cat-file -e "$c:$f" 2>/dev/null || continue
    mkdir -p "$B/src/$(dirname "${f#lib/at_mcp/}")"; git -C "$D/at_mcp.git" show "$c:$f" > "$B/src/${f#lib/at_mcp/}"
  done
  cp "$HERE/compile_overlay.exs" "$B/work/"
  "$HERE/box.sh" "$D/official/rel/at_mcp" "$B/work" --ro-bind "$B/src" /src --setenv OVERLAY_OUT /work/out --setenv OVERLAY_SRC /src -- \
    timeout 300 /rel/bin/at_mcp eval 'Code.eval_file("/work/compile_overlay.exs")' 2>&1 | grep -E '^COMPILED|^FAILED' | cut -c1-120
  mkdir -p "$B/rel"; cp -a "$D/official/rel/at_mcp" "$B/rel/at_mcp"; chmod -R u+w "$B/rel/at_mcp"
  cp "$B"/work/out/*.beam "$B/rel/at_mcp/lib/at_mcp-0.3.3-hum.11/ebin/"
  say "overlay $n = ${c:0:12}"
}
overlay b653ead b653ead; overlay 3d43966 3d43966; overlay 9281970 9281970; overlay 9499b75 9499b75
overlay 23fa3e9 23fa3e9; overlay c64be24 "$TARGET"
run() {  # case build
  local W; W=$(mktemp -d "$D/run-$2-$1.XXXX"); cp "$HERE/$1.exs" "$W/"
  say "=== $1 on $2"
  "$HERE/box.sh" "$D/$2/rel/at_mcp" "$W" --setenv RELEASE_MODE interactive -- timeout 900 /rel/bin/at_mcp eval "Code.eval_file(\"/work/$1.exs\")" 2>&1 \
    | { grep -E '^RESULT|^DONE' || echo "RESULT	$1 on $2	NO OUTPUT (see the case's own run in $W)"; } | tee -a "$OUT"
}
for b in official b653ead 3d43966 c64be24; do run f1_streams_json $b; done
for b in official 9281970 9499b75 c64be24; do run f2_account_file_types $b; done
for b in 23fa3e9 c64be24; do run f3_mark_never_moves $b; done
for b in official c64be24; do run f4_poll_clock_ahead $b; done
say "FINISHED"
