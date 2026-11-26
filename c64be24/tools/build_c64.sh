#!/bin/bash
# D-019 Trial by Fire, round c64be24: builds the overlays used by this campaign in WORKDIR.
#   control  = 335b95e (hum.11's own source, recompiled: must behave as the hum.11 release)
#   previous = 23fa3e9 (our last validated revision)
#   target   = c64be24 (hum/next, the revision under test)
# Method as in the earlier rounds: lib/ files changed since hum.11 are compiled in the network-less sandbox with
# hum.11's Elixir and overlaid on a copy of the hum.11 release, run in RELEASE_MODE=interactive.
# Usage: build_c64.sh WORKDIR [NAME=COMMIT ...]   (WORKDIR holds at_mcp.git, audit/ at the kit commit, and the hum.11
# tarball). With NAME=COMMIT pairs, only those overlays are built (used to bisect a finding).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); D=$(cd "$1" && pwd); KIT=$D/audit/hum.10/kit
H11=335b95e61a8d76f7e201c16c53c6f6b6fa9fb364
PREV=23fa3e93d1968b8baffdf7f6e9b905794cc74b0c
TARGET=c64be24bc06b7fb44e91369cb8007b2065b8f962
H11_SHA=6a8794466ee006c1b37a9b37ba9e4895ef2b13aae837be0a10e4741de98fe7f5
F=at_mcp-0.3.3-hum.11-linux-x86_64.tar.gz
echo "$H11_SHA  $D/$F" | sha256sum -c - >/dev/null || { echo "RELEASE CHECKSUM MISMATCH"; exit 1; }
for c in $H11 $PREV $TARGET; do git -C "$D/at_mcp.git" cat-file -e "$c^{commit}" || { echo "COMMIT MISSING $c"; exit 1; }; done
[ "$(git -C "$D/at_mcp.git" rev-parse c64be24)" = "$TARGET" ] || { echo "c64be24 does not resolve to $TARGET"; exit 1; }
mkdir -p "$D/official11"; [ -d "$D/official11/at_mcp" ] || tar -xzf "$D/$F" -C "$D/official11" --no-same-owner --no-same-permissions
overlay() {  # name commit
  local n=$1 c=$2 B=$D/$1
  rm -rf "$B"; mkdir -p "$B/src" "$B/work"
  for f in $(git -C "$D/at_mcp.git" diff --name-only "$H11" "$TARGET" -- lib) $(git -C "$D/at_mcp.git" diff --name-only "$H11" "$c" -- lib); do
    git -C "$D/at_mcp.git" cat-file -e "$c:$f" 2>/dev/null || continue
    mkdir -p "$B/src/$(dirname "${f#lib/at_mcp/}")"; git -C "$D/at_mcp.git" show "$c:$f" > "$B/src/${f#lib/at_mcp/}"
  done
  cp "$HERE/compile_overlay.exs" "$B/work/"
  "$KIT/box.sh" "$D/official11/at_mcp" "$B/work" --ro-bind "$B/src" /src --setenv OVERLAY_OUT /work/out --setenv OVERLAY_SRC /src -- \
    timeout 300 /rel/bin/at_mcp eval 'Code.eval_file("/work/compile_overlay.exs")' 2>&1 | grep -E '^COMPILED|^FAILED' | cut -c1-200
  mkdir -p "$B/rel"; cp -a "$D/official11/at_mcp" "$B/rel/at_mcp"; chmod -R u+w "$B/rel/at_mcp"
  cp "$B"/work/out/*.beam "$B"/rel/at_mcp/lib/at_mcp-0.3.3-hum.11/ebin/
  printf '0.3.3-hum.11-%s-overlay\n' "${c:0:7}" > "$B/rel/at_mcp/BUILD"
  echo "overlay $n from ${c:0:7}: $(ls "$B/src" -R | grep -c '\.ex$') source files; $(cd "$B/work/out" && sha256sum *.beam | awk '{print substr($1,1,12) " " $2}' | sed 's/Elixir.AtMcp.//' | tr '\n' ' ')"
}
shift
if [ $# -gt 0 ]; then
  for nc in "$@"; do c=$(git -C "$D/at_mcp.git" rev-parse "${nc#*=}^{commit}"); overlay "${nc%%=*}" "$c"; done
else
  overlay control $H11
  overlay previous $PREV
  overlay target $TARGET
fi
