#!/usr/bin/env bash
# Guided ARC oracle sidecar setup.
#
# Discovers the XEQM service nodes on this host that don't yet have an oracle
# sidecar, lets you tick which ones to run a sidecar for, and does the rest —
# fetch the binary, generate the key, write the config, enrol, start the service
# — with nothing to hand-edit. Everything (gate, chain, mask publisher, admin
# port) is auto-detected. Run:  sudo bash sidecar.sh
set -euo pipefail

script_basedir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${script_basedir}/common.sh"

PLATFORM_URL="${ARC_PLATFORM_URL:-https://api.exiom.network}"     # gate/chain/mask config
DASHBOARD_URL="${ARC_DASHBOARD_URL:-https://missoula.xeqmlabs.com}" # the arc-oracle binary
CONFDIR=/etc/arc-oracle
BIN=/usr/local/bin/arc-oracle
USER=arc-oracle
UNIT=/etc/systemd/system/arc-oracle@.service

while [ $# -gt 0 ]; do
  case "$1" in
    --platform-url)  PLATFORM_URL="$2"; shift 2 ;;
    --dashboard-url) DASHBOARD_URL="$2"; shift 2 ;;
    -h|--help) echo "usage: sidecar.sh [--platform-url URL] [--dashboard-url URL]"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
command -v curl    >/dev/null || { echo "curl required" >&2; exit 1; }
ARCH="$(uname -m)"

jget() { python3 -c 'import sys,json
d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k]
print(d)' "$1"; }

# ── 1. network settings from the platform ──────────────────────────────────────
echo "Fetching network settings from ${PLATFORM_URL} ..."
contracts="$(curl -fsS --max-time 20 "${PLATFORM_URL}/v1/contracts")"       || { echo "cannot reach ${PLATFORM_URL}/v1/contracts" >&2; exit 1; }
publisher="$(curl -fsS --max-time 20 "${PLATFORM_URL}/v1/oracle/publisher")" || { echo "cannot reach the mask publisher" >&2; exit 1; }
GATE="$(printf '%s' "$contracts"  | jget contracts.AttestationGate.address)"
CHAIN="$(printf '%s' "$contracts" | jget chain_id)"
NETNAME="$(printf '%s' "$contracts" | jget network)"
MASK_URL="$(printf '%s' "$publisher" | jget source_url)"
MASK_PUB="$(printf '%s' "$publisher" | jget pinned_pubkey)"

# ── 2. ensure binary + user + unit template ────────────────────────────────────
if [ ! -x "$BIN" ]; then
  echo "Fetching arc-oracle (${ARCH}) from ${DASHBOARD_URL} ..."
  tmp="$(mktemp)"
  curl -fsS --max-time 60 "${DASHBOARD_URL}/bin/${ARCH}/arc-oracle" -o "$tmp" \
    || { echo "no arc-oracle binary for ${ARCH} on ${DASHBOARD_URL}" >&2; rm -f "$tmp"; exit 1; }
  want="$(curl -fsS --max-time 20 "${DASHBOARD_URL}/bin/${ARCH}/arc-oracle.sha256" | tr -d ' \n')"
  got="$(sha256sum "$tmp" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || { echo "checksum mismatch: got $got want $want" >&2; rm -f "$tmp"; exit 1; }
  install -m 0755 "$tmp" "$BIN"; rm -f "$tmp"
  echo "installed $BIN"
fi
id "$USER" >/dev/null 2>&1 || { useradd --system --no-create-home --shell /usr/sbin/nologin "$USER"; echo "created user $USER"; }
install -d -m 0750 -o root -g "$USER" "$CONFDIR"
if [ ! -f "$UNIT" ]; then
  cat > "$UNIT" <<'SVC'
[Unit]
Description=ARC Oracle Sidecar (%i)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=arc-oracle
Group=arc-oracle
ExecStart=/usr/local/bin/arc-oracle --config /etc/arc-oracle/%i.toml
EnvironmentFile=-/etc/arc-oracle/%i.env
Restart=on-failure
RestartSec=10
MemoryMax=256M
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/arc-oracle
SyslogIdentifier=arc-oracle@%i
[Install]
WantedBy=multi-user.target
SVC
  systemctl daemon-reload
  echo "installed arc-oracle@.service"
fi

# ── 3. discover service nodes without a sidecar ────────────────────────────────
existing_ports="$(grep -hoE 'rpc_url[[:space:]]*=[[:space:]]*"http://127\.0\.0\.1:[0-9]+"' "$CONFDIR"/*.toml 2>/dev/null | grep -oE ':[0-9]+"' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)"

declare -a CAND_PORT CAND_NAME CAND_SN
while read -r _pid cmd; do
  [ -z "${cmd:-}" ] && continue
  port="$(printf '%s' "$cmd" | grep -oE 'rpc-admin[= ]127\.0\.0\.1:[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)"
  if [ -z "$port" ]; then
    cf="$(printf '%s' "$cmd" | grep -oE 'config-file[= ][^ ]+' | sed 's/^config-file[= ]//' | head -1 || true)"
    [ -n "$cf" ] && [ -f "$cf" ] && port="$(grep -iE '^[[:space:]]*rpc-admin' "$cf" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)"
  fi
  [ -z "$port" ] && continue
  case " $existing_ports " in *" $port "*) continue ;; esac    # already coupled to a sidecar
  dd="$(printf '%s' "$cmd" | grep -oE 'data-dir[= ][^ ]+' | sed 's/^data-dir[= ]//' | head -1 || true)"
  name="$(basename "${dd:-snode-$port}")"
  sn="$(curl -s --max-time 5 "http://127.0.0.1:$port/json_rpc" -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","id":0,"method":"get_service_keys"}' \
        | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["service_node_pubkey"][:12])
except Exception: print("unknown")' 2>/dev/null || echo unknown)"
  CAND_PORT+=("$port"); CAND_NAME+=("$name"); CAND_SN+=("$sn")
done < <(pgrep -af 'xeqm-d' | grep -- '--service-node' || true)

if [ "${#CAND_PORT[@]}" -eq 0 ]; then
  echo "No service nodes without a sidecar were found on this host."
  echo "(If you expected some, check they are running with --service-node.)"
  exit 0
fi

# ── 4. selection ───────────────────────────────────────────────────────────────
selected=""
if wt_available; then
  args=()
  for i in "${!CAND_PORT[@]}"; do
    args+=("${CAND_PORT[$i]}" "${CAND_NAME[$i]}  (sn ${CAND_SN[$i]}…)" "ON")
  done
  chosen=""
  wt_checklist "ARC Oracle Sidecars" \
    "Service nodes on this host without a sidecar.\nTick the ones to run an oracle sidecar for — all will use ${NETNAME} (chain ${CHAIN})." \
    20 76 10 chosen "${args[@]}" || { echo "cancelled"; exit 0; }
  selected="$(printf '%s' "$chosen" | tr -d '"')"
else
  echo; echo "Service nodes without a sidecar:"
  for i in "${!CAND_PORT[@]}"; do printf "  %d) %-14s port %s  sn %s…\n" "$((i+1))" "${CAND_NAME[$i]}" "${CAND_PORT[$i]}" "${CAND_SN[$i]}"; done
  printf 'Enter numbers to set up (space-separated), or "all": '; read -r pick
  if [ "$pick" = "all" ]; then selected="${CAND_PORT[*]}"
  else for n in $pick; do idx=$((n-1)); [ -n "${CAND_PORT[$idx]:-}" ] && selected="$selected ${CAND_PORT[$idx]}"; done; fi
fi
[ -z "$(printf '%s' "$selected" | tr -d ' ')" ] && { echo "nothing selected"; exit 0; }

# ── 5. confirm ─────────────────────────────────────────────────────────────────
summary="Network:  ${NETNAME} (chain ${CHAIN})\nGate:     ${GATE}\nMask:     ${MASK_URL}\nPlatform: ${PLATFORM_URL}\n\nSet up an oracle sidecar for the selected node(s)?"
if wt_available; then
  wt_yesno "Confirm settings" "$summary" 16 78 || { echo "cancelled"; exit 0; }
else
  printf '%b\n' "$summary"; printf 'Proceed? [y/N] '; read -r yn; case "$yn" in [Yy]*) ;; *) exit 0 ;; esac
fi

# ── 6. set up each selected node ───────────────────────────────────────────────
name_for_port() { local p="$1" i; for i in "${!CAND_PORT[@]}"; do [ "${CAND_PORT[$i]}" = "$p" ] && { echo "${CAND_NAME[$i]}"; return; }; done; echo "snode-$p"; }

echo
for port in $selected; do
  name="$(name_for_port "$port")"
  cfg="$CONFDIR/$name.toml"; key="$CONFDIR/$name.key.enc"; env="$CONFDIR/$name.env"
  echo "• ${name} (admin port ${port})"
  pass="$(head -c 30 /dev/urandom | base64 | tr -d '\n')"
  printf 'ARC_ORACLE_PASSPHRASE=%s\n' "$pass" > "$env"; chmod 600 "$env"; chown root:root "$env"
  if [ ! -f "$key" ]; then
    ARC_ORACLE_PASSPHRASE="$pass" "$BIN" --init --config "$cfg" >/dev/null 2>&1 || true
  fi
  cat > "$cfg" <<CFG
[identity]
key_file = "$key"

[daemon]
rpc_url = "http://127.0.0.1:$port"

[platform]
api_url = "$PLATFORM_URL"

[chain]
gate_address = "$GATE"
chain_id = $CHAIN

[duty]
poll_interval = 60
mask_quorum = 1

[[mask_source]]
name = "publisher"
url = "$MASK_URL"
pubkey = "$MASK_PUB"
CFG
  chown root:"$USER" "$cfg" "$key" 2>/dev/null || true
  chmod 640 "$cfg" "$key" 2>/dev/null || true
  if ARC_ORACLE_PASSPHRASE="$pass" "$BIN" --enroll --config "$cfg" >"/tmp/arc-enroll-$name.log" 2>&1; then
    chown root:"$USER" "$cfg"; chmod 640 "$cfg"
    systemctl enable --now "arc-oracle@$name" >/dev/null 2>&1
    echo "    ✓ enrolled and started (arc-oracle@$name)"
  else
    echo "    ✗ enrollment failed — see /tmp/arc-enroll-$name.log"
    echo "      (the node must be registered, funded, and NTP-synced)"
  fi
done

# ── 7. summary ─────────────────────────────────────────────────────────────────
echo
echo "Done. Enrolled sidecars are registered with the platform; an admin adds you"
echo "to the gate (a one-time Ledger/Safe step) — until then a sidecar polls and"
echo "waits, which is normal."
echo
echo "IMPORTANT — back up your key(s). Each ${CONFDIR}/<node>.key.enc plus the"
echo "passphrase in the matching <node>.env IS your committee identity; losing it"
echo "means re-enrolling a new one. Copy them somewhere safe and offline."
