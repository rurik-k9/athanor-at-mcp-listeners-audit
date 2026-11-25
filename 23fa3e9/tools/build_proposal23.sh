#!/bin/bash
# Builds the overlay "proposal23": 23fa3e9 with tools/proposal-23fa3e9.patch, in a work dir made by reproduce_validation.sh
# (same method: changed lib/ files compiled in the sandbox with hum.11's Elixir and overlaid on a copy of hum.11).
# Usage: build_proposal23.sh WORKDIR
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=$1; KIT=$D/audit/hum.10/kit
H11=335b95e61a8d76f7e201c16c53c6f6b6fa9fb364; C=23fa3e93d1968b8baffdf7f6e9b905794cc74b0c; B=$D/proposal23
rm -rf "$B"; mkdir -p "$B/src" "$B/work"
for f in $(git -C "$D/at_mcp.git" diff --name-only "$H11" "$C" -- lib); do
  mkdir -p "$B/src/$(dirname "${f#lib/at_mcp/}")"; git -C "$D/at_mcp.git" show "$C:$f" > "$B/src/${f#lib/at_mcp/}"
done
patch -p3 -s -d "$B/src" -i "$HERE/proposal-23fa3e9.patch"
cp "$HERE/compile_overlay.exs" "$B/work/"
"$KIT/box.sh" "$D/official11/at_mcp" "$B/work" --ro-bind "$B/src" /src --setenv OVERLAY_OUT /work/out --setenv OVERLAY_SRC /src -- \
  timeout 300 /rel/bin/at_mcp eval 'Code.eval_file("/work/compile_overlay.exs")' 2>&1 | grep -E '^COMPILED|^FAILED' | cut -c1-200
mkdir -p "$B/rel"; cp -a "$D/official11/at_mcp" "$B/rel/at_mcp"; chmod -R u+w "$B/rel/at_mcp"
cp "$B"/work/out/*.beam "$B"/rel/at_mcp/lib/at_mcp-0.3.3-hum.11/ebin/
echo "0.3.3-hum.11-23fa3e9-proposal23-overlay" > "$B/rel/at_mcp/BUILD"
echo "proposal23: $(sha256sum "$B/work/out/Elixir.AtMcp.Updates.beam" | cut -c1-12) Updates.beam"
