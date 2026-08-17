#!/bin/bash
# xeqm-bootstrap-sync.sh — Generate and publish an XEQM chain bootstrap tarball.
#
# Runs hourly via cron (see /etc/cron.d/xeqm-bootstrap).
# Produces lmdb.tar.gz containing: lmdb/ + sqlite.db + p2pstate.bin
# Published at bootstrap.xeqmlabs.com (nginx, see nginx-bootstrap.conf).
#
# Log: /var/log/xeqm-bootstrap-sync.log
# See infra/bootstrap-server/SETUP.md for full spin-up instructions.

set -euo pipefail

LMDB_PATH='/opt/xeqm/data/lmdb'
DATA_DIR="$(dirname "$LMDB_PATH")"
WEBROOT='/var/www/bootstrap'
MDB_COPY='/usr/local/bin/xeqm-mdb_copy'
INDEX="${WEBROOT}/index.html"
WORK=$(mktemp -d /tmp/bootstrap-sync.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# ── LMDB snapshot (consistent, no daemon stop required) ───────────────────────
COPY_DIR="$WORK/lmdb"
mkdir -p "$COPY_DIR"

if "$MDB_COPY" -c "$LMDB_PATH" "$COPY_DIR" 2>/dev/null; then
    log 'INFO  mdb_copy -c succeeded (consistent snapshot)'
else
    log 'WARN  mdb_copy failed - falling back to cp -a'
    cp -a "$LMDB_PATH/." "$COPY_DIR/"
fi

# ── sqlite.db (service node + ONS state — eliminates post-bootstrap rescan) ───
# VACUUM INTO creates a clean WAL-merged copy readable by any process.
# Requires sqlite3 >= 3.27.0. Install: sudo apt-get install -y sqlite3
if [[ -f "$DATA_DIR/sqlite.db" ]]; then
    log 'INFO  snapshotting sqlite.db via VACUUM INTO...'
    sqlite3 "$DATA_DIR/sqlite.db" "VACUUM INTO '$WORK/sqlite.db';" 2>/dev/null \
        && log 'INFO  sqlite.db snapshot OK' \
        || { log 'WARN  VACUUM INTO failed, falling back to cp'; cp -a "$DATA_DIR/sqlite.db" "$WORK/sqlite.db" || true; }
fi

# ── p2pstate.bin (peer address cache — gives new nodes immediate peers) ───────
[[ -f "$DATA_DIR/p2pstate.bin" ]] && cp -a "$DATA_DIR/p2pstate.bin" "$WORK/p2pstate.bin" \
    && log 'INFO  p2pstate.bin included'

# ── Compress ──────────────────────────────────────────────────────────────────
log 'INFO  compressing...'
TARBALL="$WORK/lmdb.tar.gz"
_tar_args=(lmdb)
[[ -f "$WORK/sqlite.db"    ]] && _tar_args+=(sqlite.db)
[[ -f "$WORK/p2pstate.bin" ]] && _tar_args+=(p2pstate.bin)
tar -czf "$TARBALL" -C "$WORK" "${_tar_args[@]}"
SIZE=$(du -sh "$TARBALL" | cut -f1)
SIZE_BYTES=$(stat -c%s "$TARBALL")
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
log "INFO  tarball size: $SIZE  contents: ${_tar_args[*]}"

# ── Integrity check ───────────────────────────────────────────────────────────
log 'INFO  verifying tarball integrity...'
if ! tar -tzf "$TARBALL" > /dev/null 2>&1; then
    log 'ERROR tarball failed integrity check - aborting publish, existing tarball preserved'
    exit 1
fi
log 'INFO  integrity check passed'

# ── Checksum + manifest ───────────────────────────────────────────────────────
CHECKSUM=$(sha256sum "$TARBALL" | awk '{print $1}')
echo "$CHECKSUM  lmdb.tar.gz" > "$WORK/lmdb.tar.gz.sha256"
log "INFO  sha256: $CHECKSUM"

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
HEIGHT_RPC=$(curl -s http://127.0.0.1:9231/json_rpc \
    -d '{"jsonrpc":"2.0","id":"0","method":"get_block_count"}' \
    -H 'Content-Type: application/json' 2>/dev/null | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"]["count"]-1)' 2>/dev/null || echo 0)

cat > "$WORK/manifest.json" << MANIFEST
{"generated_at":"$NOW","height":$HEIGHT_RPC,"size_bytes":$SIZE_BYTES,"sha256":"$CHECKSUM"}
MANIFEST

# ── Update index.html stats ───────────────────────────────────────────────────
if [[ -f "$INDEX" ]]; then
    python3 - << PYEOF
import re
with open('$INDEX', 'r') as f:
    html = f.read()
html = re.sub(r'(<span id="bs-height">)[^<]*(</span>)', r'\g<1>$HEIGHT_RPC\2', html)
html = re.sub(r'(<span id="bs-size">)[^<]*(</span>)',   r'\g<1>$SIZE_MB\2',    html)
html = re.sub(r'(<span id="bs-ts">)[^<]*(</span>)',     r'\g<1>$NOW\2',        html)
html = re.sub(r'(<span id="bs-sha256">)[^<]*(</span>)', r'\g<1>$CHECKSUM\2',   html)
with open('$INDEX', 'w') as f:
    f.write(html)
PYEOF
    log "INFO  updated index.html: height=$HEIGHT_RPC size=${SIZE_MB}MB"
fi

# ── Atomic publish ────────────────────────────────────────────────────────────
# All files swap together so a concurrent download never sees a half-updated set.
mv "$TARBALL"                   "$WEBROOT/lmdb.tar.gz.tmp"
mv "$WORK/lmdb.tar.gz.sha256"   "$WEBROOT/lmdb.tar.gz.sha256.tmp"
mv "$WORK/manifest.json"        "$WEBROOT/manifest.json.tmp"
mv "$WEBROOT/lmdb.tar.gz.tmp"        "$WEBROOT/lmdb.tar.gz"
mv "$WEBROOT/lmdb.tar.gz.sha256.tmp" "$WEBROOT/lmdb.tar.gz.sha256"
mv "$WEBROOT/manifest.json.tmp"      "$WEBROOT/manifest.json"

log "INFO  published height=$HEIGHT_RPC size=$SIZE sha256=${CHECKSUM:0:16}..."
