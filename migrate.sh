#!/usr/bin/env bash
# Migrate a MAINNET arc-oracle sidecar install to the EXIOM Oracle name, in place.
# Handles both forms:
#   - single-instance  : arc-oracle.service      + /etc/arc-oracle/config.toml
#   - templated        : arc-oracle@<node>.service + /etc/arc-oracle/<node>.toml
# Only migrates configs on chain 4663 (mainnet); testnet/other sidecars are left
# untouched. Reversible: the old install stays until you run --cleanup.
#
#   sudo bash migrate.sh            # migrate mainnet sidecars on this host
#   sudo bash migrate.sh --cleanup  # after verifying, remove the old arc-oracle install
set -euo pipefail

OLD_DIR=/etc/arc-oracle;            NEW_DIR=/etc/exiom-oracle
OLD_BIN=/usr/local/bin/arc-oracle;  NEW_BIN=/usr/local/bin/exiom-oracle
OLD_USER=arc-oracle;                NEW_USER=exiom-oracle
MAINNET_CHAIN=4663

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

templated() { systemctl list-units --all --plain --no-legend 'arc-oracle@*.service' 2>/dev/null \
  | awk '{print $1}' | sed 's/^arc-oracle@//; s/\.service$//'; }

if [ "${1:-}" = "--cleanup" ]; then
  systemctl disable --now arc-oracle.service 2>/dev/null || true
  for n in $(templated); do systemctl disable --now "arc-oracle@${n}" 2>/dev/null || true; done
  rm -f /etc/systemd/system/arc-oracle.service /etc/systemd/system/arc-oracle@.service
  systemctl daemon-reload
  rm -rf "$OLD_DIR"; rm -f "$OLD_BIN"
  id "$OLD_USER" >/dev/null 2>&1 && userdel "$OLD_USER" 2>/dev/null || true
  echo "removed the old arc-oracle install"; exit 0
fi

[ -d "$OLD_DIR" ] || { echo "no $OLD_DIR here — nothing to migrate" >&2; exit 0; }

is_mainnet() { [ "$(grep -oE 'chain_id[[:space:]]*=[[:space:]]*[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1)" = "$MAINNET_CHAIN" ]; }

ensure_common() {
  [ -x "$NEW_BIN" ] || install -m 0755 "$OLD_BIN" "$NEW_BIN"
  id "$NEW_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$NEW_USER"
  install -d -m 0750 -o root -g "$NEW_USER" "$NEW_DIR"
}
move_cfg() {  # $1 = config basename
  local b="$1"
  for ext in toml key.enc env; do [ -f "$OLD_DIR/$b.$ext" ] && cp -a "$OLD_DIR/$b.$ext" "$NEW_DIR/$b.$ext"; done
  [ -f "$NEW_DIR/$b.toml" ] && sed -i "s#$OLD_DIR#$NEW_DIR#g" "$NEW_DIR/$b.toml"
  for ext in toml key.enc; do [ -f "$NEW_DIR/$b.$ext" ] && { chown root:"$NEW_USER" "$NEW_DIR/$b.$ext"; chmod 0640 "$NEW_DIR/$b.$ext"; }; done
}

migrated=0

# ── single-instance ────────────────────────────────────────────────────────────
if systemctl cat arc-oracle.service >/dev/null 2>&1 && [ -f "$OLD_DIR/config.toml" ]; then
  if is_mainnet "$OLD_DIR/config.toml"; then
    ensure_common
    echo "migrating arc-oracle.service (config.toml) ..."
    systemctl stop arc-oracle.service || true
    move_cfg config
    [ -f "$OLD_DIR/arc-oracle.env" ] && { cp -a "$OLD_DIR/arc-oracle.env" "$NEW_DIR/exiom-oracle.env"; }
    # Preserve the host's hardened unit; just rewrite the identifiers/paths.
    systemctl cat arc-oracle.service | grep -vE '^# /' \
      | sed -e 's#/usr/local/bin/arc-oracle#/usr/local/bin/exiom-oracle#g' \
            -e 's#/etc/arc-oracle/arc-oracle.env#/etc/exiom-oracle/exiom-oracle.env#g' \
            -e 's#/etc/arc-oracle#/etc/exiom-oracle#g' \
            -e 's/^User=arc-oracle/User=exiom-oracle/' \
            -e 's/^Group=arc-oracle/Group=exiom-oracle/' \
            -e 's/SyslogIdentifier=arc-oracle/SyslogIdentifier=exiom-oracle/' \
            -e 's/Description=ARC Oracle Sidecar/Description=EXIOM Oracle Sidecar/' \
      > /etc/systemd/system/exiom-oracle.service
    systemctl daemon-reload
    systemctl enable --now exiom-oracle.service
    sleep 3
    systemctl is-active --quiet exiom-oracle.service && { echo "  exiom-oracle.service active"; migrated=1; } \
      || { echo "  FAILED — arc-oracle.service left intact; aborting" >&2; exit 1; }
  else
    echo "skipping arc-oracle.service — not mainnet (chain != $MAINNET_CHAIN)"
  fi
fi

# ── templated ───────────────────────────────────────────────────────────────────
NEED_TEMPLATE=1
for node in $(templated); do
  cfg="$OLD_DIR/$node.toml"; [ -f "$cfg" ] || continue
  if ! is_mainnet "$cfg"; then echo "skipping arc-oracle@$node — not mainnet"; continue; fi
  ensure_common
  if [ "$NEED_TEMPLATE" = 1 ]; then
    cat > /etc/systemd/system/exiom-oracle@.service <<'SVC'
[Unit]
Description=EXIOM Oracle Sidecar (%i)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=exiom-oracle
Group=exiom-oracle
ExecStart=/usr/local/bin/exiom-oracle --config /etc/exiom-oracle/%i.toml
EnvironmentFile=-/etc/exiom-oracle/%i.env
Restart=on-failure
RestartSec=10
MemoryMax=256M
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/exiom-oracle
SyslogIdentifier=exiom-oracle@%i
[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload; NEED_TEMPLATE=0
  fi
  echo "migrating arc-oracle@$node ..."
  systemctl stop "arc-oracle@$node" || true
  move_cfg "$node"
  systemctl enable --now "exiom-oracle@$node"
  sleep 3
  systemctl is-active --quiet "exiom-oracle@$node" && { echo "  exiom-oracle@$node active"; migrated=1; } \
    || { echo "  FAILED exiom-oracle@$node — arc-oracle@$node left intact; aborting" >&2; exit 1; }
done

[ "$migrated" = 1 ] || { echo "no mainnet arc-oracle sidecar found to migrate" >&2; exit 0; }
echo
echo "Migrated. Verify:  journalctl -u 'exiom-oracle*' -n 20 --no-pager"
echo "After confirming it is enrolled and signing, remove the old install:"
echo "  sudo bash migrate.sh --cleanup"
