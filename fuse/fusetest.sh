#!/usr/bin/env bash
# Manual smoke test: mount a VFS socket and exercise reads + writes.
# Usage: fuse/fusetest.sh /path/to/vfs.sock /Volumes/mcp <apikey>
set -euo pipefail

SOCK="${1:?usage: fusetest.sh <socket> <mountpoint> <apikey>}"
MOUNT="${2:?usage: fusetest.sh <socket> <mountpoint> <apikey>}"
KEY="${3:?usage: fusetest.sh <socket> <mountpoint> <apikey>}"

BIN="$(dirname "$0")/../bin/mcp-fuse"
[ -x "$BIN" ] || { echo "run: make fuse-build" >&2; exit 1; }

mkdir -p "$MOUNT"
"$BIN" --server "unix:$SOCK" --mount "$MOUNT" --apikey "$KEY" &
FUSE_PID=$!
trap 'kill $FUSE_PID 2>/dev/null; sleep 1; umount "$MOUNT" 2>/dev/null || fusermount -u "$MOUNT" 2>/dev/null || true' EXIT

echo "waiting for mount..."
for i in $(seq 1 50); do [ -d "$MOUNT" ] && mount | grep -q "$MOUNT" && break; sleep 0.2; done

echo "== ls =="
ls -la "$MOUNT"

ROOT_FILE="$MOUNT/smoke-$(date +%s).txt"
echo "== write $ROOT_FILE =="
echo "hello from mcp-fuse $(date)" > "$ROOT_FILE"

echo "== cat back =="
cat "$ROOT_FILE"

echo "== append =="
echo "second line" >> "$ROOT_FILE"
cat "$ROOT_FILE"

echo "== rm =="
rm "$ROOT_FILE"
ls "$MOUNT" | grep smoke && echo "UNLINK FAILED" || echo "unlink ok"

echo "smoke test done (Ctrl-C to unmount)"
wait $FUSE_PID
