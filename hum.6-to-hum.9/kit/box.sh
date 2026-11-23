#!/bin/bash
# box.sh REL_DIR WORK_DIR [bwrap options...] -- command...
# Runs one at_mcp release with no external network, no /home, no credentials,
# a read-only install and a synthetic, empty account file.
R=$(cd "$1" && pwd); W=$(cd "$2" && pwd); shift 2; O=()
while [ "$1" != "--" ]; do O+=("$1"); shift; done; shift
exec bwrap --ro-bind /usr /usr --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/bin /bin \
  --ro-bind /etc/ld.so.cache /etc/ld.so.cache --proc /proc --dev /dev --tmpfs /tmp \
  --ro-bind "$R" /rel --bind "$W" /work --chdir /work \
  --unshare-all --die-with-parent --new-session --clearenv \
  --setenv HOME /tmp --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8 \
  --setenv RELEASE_COOKIE isolated-test-cookie --setenv RELEASE_TMP /tmp \
  --setenv AT_MCP_NETWORK delve --setenv AT_MCP_STATE_DIR /work/service-state \
  --setenv AT_MCP_ACCOUNTS_FILE /work/no-accounts.json --setenv AT_MCP_LISTENERS 1 "${O[@]}" "$@"
