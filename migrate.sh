#!/usr/bin/env bash
# Migrate an ARC-oracle sidecar install to the EXIOM Oracle name, in place.
# Reversible: the old install is left running-capable until you run --cleanup.
#
#   sudo bash migrate.sh            # migrate every arc-oracle@<node> on this host
#   sudo bash migrate.sh --cleanup  # after verifying, remove the old arc-oracle install
set -euo pipefail

OLD_DIR=/etc/arc-oracle;            NEW_DIR=/etc/exiom-oracle
OLD_BIN=/usr/local/bin/arc-oracle;  NEW_BIN=/usr/local/bin/exiom-oracle
OLD_USER=arc-oracle;                NEW_USER=exiom-oracle
OLD_UNIT=/etc/systemd/system/arc-oracle@.service
NEW_UNIT=/etc/systemd/system/exiom-oracle@.service

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

instances() { systemctl list-units --all --plain --no-legend 'arc-oracle@*.service' 2>/dev/null \
  | awk '{print $1}' | sed 's/^arc-oracle@//; s/\.service$//'; }

if [ "${1:-}" = "--cleanup" ]; then
  for node in $(instances); do systemctl disable --now "arc-oracle@${node}" 2>/dev/null || true; done
  rm -f "$OLD_UNIT"; systemctl daemon-reload
  rm -rf "$OLD_DIR"; rm -f "$OLD_BIN"
  id "$OLD_USER" >/dev/null 2>&1 && userdel "$OLD_USER" 2>/dev/null || true
  echo "removed the old arc-oracle install"
  exit 0
fi

[ -d "$OLD_DIR" ] || { echo "no $OLD_DIR here — nothing to migrate" >&2; exit 0; }

# New binary: reuse the existing bits under the new name (identical binary).
[ -x "$NEW_BIN" ] || install -m 0755 "$OLD_BIN" "$NEW_BIN"
id "$NEW_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$NEW_USER"
install -d -m 0750 -o root -g "$NEW_USER" "$NEW_DIR"

cat > "$NEW_UNIT" <<'SVC'
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
systemctl daemon-reload

for node in $(instances); do
  echo "migrating ${node} ..."
  systemctl stop "arc-oracle@${node}" || true
  # Copy config, sealed key, and env. Preserve modes (cp -a); the .env keeps its
  # 0600 root:root (holds the passphrase); the key + toml get group-read for the
  # service user below.
  for ext in toml key.enc env; do
    [ -f "$OLD_DIR/${node}.${ext}" ] && cp -a "$OLD_DIR/${node}.${ext}" "$NEW_DIR/${node}.${ext}"
  done
  # Fix any absolute /etc/arc-oracle references baked into the config.
  [ -f "$NEW_DIR/${node}.toml" ] && sed -i "s#${OLD_DIR}#${NEW_DIR}#g" "$NEW_DIR/${node}.toml"
  for ext in toml key.enc; do
    [ -f "$NEW_DIR/${node}.${ext}" ] && { chown root:"$NEW_USER" "$NEW_DIR/${node}.${ext}"; chmod 0640 "$NEW_DIR/${node}.${ext}"; }
  done
  systemctl enable --now "exiom-oracle@${node}"
  sleep 3
  if systemctl is-active --quiet "exiom-oracle@${node}"; then
    echo "  exiom-oracle@${node} active"
  else
    echo "  FAILED to start exiom-oracle@${node} — old arc-oracle@${node} left intact; aborting" >&2
    exit 1
  fi
done

echo
echo "Migrated. Verify each node is enrolled and polling:"
echo "  journalctl -u 'exiom-oracle@*' -n 20 --no-pager"
echo "Once confirmed, remove the old install:  sudo bash migrate.sh --cleanup"
