#!/usr/bin/env bash
# to_canonical.sh — Migrate installer-layout service nodes to canonical layout

set -euo pipefail

script_basedir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_basedir

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

to_canonical_version='v1.0'

declare -A system_info
migrate_all=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|-a) migrate_all=1 ;;
      --help|-h) usage; exit 0 ;;
      *) echo -e "\033[0;31merror:\033[0m Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
  done
}

usage() {
  echo "Usage: $0 [--all]"
  echo "  --all, -a   Migrate all discovered installer-layout nodes without prompting"
}

main() {
  parse_args "$@"
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Layout Migration (Installer → Canonical)" "${to_canonical_version}"

  discover_system system_info

  local -a installer_nodes=()
  discover_installer_nodes installer_nodes

  if [[ "${#installer_nodes[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo installer-layout service nodes found — nothing to migrate.\033[0m\n"
    echo -e "  Installer-layout nodes have a per-user OS account (e.g. snode1, snode2)"
    echo -e "  and a unit file with User=snodeN (not User=xeqm).\n"
    exit 0
  fi

  echo -e "\n\033[1mFound ${#installer_nodes[@]} installer-layout node(s):\033[0m\n"
  for user in "${installer_nodes[@]}"; do
    show_node_info "${user}"
  done

  local -a target_users=()
  if [[ "${migrate_all}" -eq 1 ]]; then
    target_users=("${installer_nodes[@]}")
    echo -e "\n  --all flag set: migrating all ${#target_users[@]} nodes.\n"
  else
    select_nodes_to_migrate target_users "${installer_nodes[@]}"
  fi

  if [[ "${#target_users[@]}" -eq 0 ]]; then
    echo -e "\nNothing selected — aborted.\n"
    exit 0
  fi

  local dry_run=0
  if [[ "${migrate_all}" -eq 0 ]]; then
    if wt_available; then
      if wt_yesno "Dry Run?" \
        "Run in dry-run mode first to preview what will happen?\n\n(No changes will be made in dry-run mode.)" \
        10 62 "Dry Run" "Migrate Now"; then
        dry_run=1
      fi
    else
      local _yn
      read -rp $'\n\033[1mDry run first? (shows what will happen, no changes)\e[0m [y/N]: ' _yn
      [[ "${_yn,,}" = "y" ]] && dry_run=1
    fi
  fi

  # Installer-layout users are already named snodeN, so they migrate in-place:
  # snode1 (User=snode1, ~/bin/xeqm-d) -> snode1 (User=xeqm, /opt/xeqm/bin/xeqm-d)
  # No slot renaming needed.

  if [[ "${dry_run}" -eq 1 ]]; then
    echo -e "\n\033[1;33m=== DRY RUN — no changes will be made ===\033[0m\n"
    local _mdb_tool="/opt/xeqm/bin/xeqm-mdb_copy"
    for user in "${target_users[@]}"; do
      local data_dir="/var/lib/xeqm/${user}"
      echo -e "  [${user}] -> ${user} (in-place)"
      if [[ -x "${_mdb_tool}" ]]; then
        echo -e "    xeqm-mdb_copy -c /home/${user}/.xeqmlabs/lmdb ${data_dir}/lmdb  (live, daemon up)"
        echo -e "    stop xeqmnode_${user}.service"
        echo -e "    cp non-lmdb state (sqlite.db, ons.db, keys) -> ${data_dir}/"
      else
        echo -e "    stop xeqmnode_${user}.service"
        echo -e "    cp -a /home/${user}/.xeqmlabs/. ${data_dir}/  (lmdb + sqlite + keys)"
      fi
      echo -e "    chown -R xeqm:xeqm ${data_dir}/"
      echo -e "    overwrite /etc/systemd/system/xeqmnode_${user}.service (canonical)"
      echo -e "    start xeqmnode_${user}.service"
      echo ""
    done
    echo -e "\033[1;33m=== END DRY RUN ===\033[0m\n"

    local _proceed
    read -rp $'\033[1mProceed with actual migration?\e[0m [y/N]: ' _proceed
    [[ "${_proceed,,}" != "y" ]] && { echo -e "\nAborted.\n"; exit 0; }
  fi

  ensure_xeqm_user
  config[binary_source]='download'
  install_binary_to_opt
  ensure_xeqm_mdb_copy

  local -a migrated_users=()

  for user in "${target_users[@]}"; do
    # Target slot = same name as installer-layout user (snode1 -> snode1)
    local target_snode="${user}"
    echo -e "\n\033[1m──────────────────────────────────────────\033[0m"
    tput rev 2>/dev/null || true; echo -e "\033[1m  Migrating ${user} (in-place)  \033[0m"; tput sgr0 2>/dev/null || true

    migrate_one_node "${user}" "${target_snode}" && migrated_users+=("${user}:${target_snode}") || {
      echo -e "\n  \033[0;31m[FAIL]\033[0m Migration of ${user} failed — skipping."
    }
  done

  post_migration_report "${migrated_users[@]+"${migrated_users[@]}"}"
}

install_dependencies() {
  local missing=()
  command -v ss      >/dev/null 2>&1 || missing+=(iproute2)
  command -v natsort >/dev/null 2>&1 || missing+=(python3-natsort)
  command -v gawk    >/dev/null 2>&1 || missing+=(gawk)
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo -e "\n\033[1mInstalling required dependencies: ${missing[*]}\033[0m"
    sudo apt -y install "${missing[@]}"
  fi
}

discover_installer_nodes() {
  local -n _din_result="$1"
  _din_result=()
  local u
  while IFS= read -r u; do
    [[ -z "${u}" ]] && continue
    # Confirm it has an installer-layout unit (User=snodeN, not User=xeqm)
    local unit_file="/etc/systemd/system/xeqmnode_${u}.service"
    if [[ -f "${unit_file}" ]] && ! grep -q '^User=xeqm$' "${unit_file}" 2>/dev/null; then
      _din_result+=("${u}")
    fi
  done < <(getent passwd | awk -F: '$6 ~ /^\/home\/snode/ { print $1 }' | sort)
}

show_node_info() {
  local user="$1"
  local unit_file="/etc/systemd/system/xeqmnode_${user}.service"
  local data_home="/home/${user}/.xeqmlabs"

  # Extract ports from unit ExecStart
  local p2p rpc qnet
  p2p="$(grep -oP '(?<=--p2p-bind-port=)\d+' "${unit_file}" 2>/dev/null || echo '?')"
  rpc="$(grep -oP '(?<=--rpc-admin=127\.0\.0\.1:)\d+' "${unit_file}" 2>/dev/null || echo '?')"
  qnet="$(grep -oP '(?<=--quorumnet-port=)\d+' "${unit_file}" 2>/dev/null || echo '?')"

  local height="?" funded="?"
  if [[ "${rpc}" != "?" ]]; then
    local info
    info="$(curl -s --connect-timeout 3 "http://127.0.0.1:${rpc}/get_info" 2>/dev/null || true)"
    height="$(echo "${info}" | grep -o '"height":[0-9]*' | head -1 | cut -d: -f2 || echo '?')"
    local sn_info
    sn_info="$(curl -s --connect-timeout 3 "http://127.0.0.1:${rpc}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_service_node_status"}' 2>/dev/null || true)"
    if echo "${sn_info}" | grep -q '"funded":true' 2>/dev/null; then
      funded="yes"
    else
      funded="no"
    fi
  fi

  local data_size="?"
  [[ -d "${data_home}" ]] && data_size="$(sudo du -sh "${data_home}" 2>/dev/null | cut -f1 || echo '?')"

  printf "  \033[1m%-14s\033[0m p2p=%-6s rpc=%-6s qnet=%-6s height=%-8s funded=%-4s data=%s\n" \
    "${user}" "${p2p}" "${rpc}" "${qnet}" "${height}" "${funded}" "${data_size}"
}

select_nodes_to_migrate() {
  local -n _snm_result="$1"
  shift
  local -a nodes=("$@")

  if wt_available; then
    local -a checklist_args=()
    for u in "${nodes[@]}"; do
      local _state="stopped"
      systemctl is-active --quiet "xeqmnode_${u}.service" 2>/dev/null && _state="running"
      checklist_args+=( "${u}" "(${_state})" "ON" )
    done

    local selected_raw=""
    selected_raw="$(whiptail --title "Select Nodes to Migrate" \
      --ok-button "Migrate Selected" \
      --cancel-button "Cancel" \
      --checklist "Space to toggle — all selected by default:" \
      $(( ${#nodes[@]} + 9 )) 58 "${#nodes[@]}" \
      "${checklist_args[@]}" 3>&1 1>&2 2>&3)" || { echo -e "\nAborted."; exit 0; }

    if [[ -z "${selected_raw}" ]]; then
      wt_msgbox "Nothing Selected" "No nodes were selected — nothing will be migrated." 8 52
      exit 0
    fi

    local _item
    read -ra _raw_arr <<< "${selected_raw}"
    for _item in "${_raw_arr[@]}"; do
      _item="${_item//\"/}"
      [[ -n "${_item}" ]] && _snm_result+=("${_item}")
    done
  else
    local _mode
    prompt_menu "Which nodes would you like to migrate?" _mode 1 \
      "All nodes (${nodes[*]})" \
      "Select specific nodes"
    if [[ "${_mode}" -eq 1 ]]; then
      _snm_result=("${nodes[@]}")
    else
      read -rp $'\n\033[1mEnter node usernames (comma-separated):\e[0m ' _input
      IFS=',' read -ra _sel <<< "${_input}"
      for _s in "${_sel[@]}"; do
        _snm_result+=("${_s// /}")
      done
    fi
  fi
}

migrate_one_node() {
  local user="$1"
  local target_snode="$2"
  local old_unit="/etc/systemd/system/xeqmnode_${user}.service"
  local new_unit_name="xeqmnode_${target_snode}"
  local data_dir="/var/lib/xeqm/${target_snode}"
  local src_data="/home/${user}/.xeqmlabs"

  # Extract ports
  local p2p rpc qnet public_ip
  p2p="$(grep -oP '(?<=--p2p-bind-port=)\d+' "${old_unit}" 2>/dev/null || true)"
  rpc="$(grep -oP '(?<=--rpc-admin=127\.0\.0\.1:)\d+' "${old_unit}" 2>/dev/null || true)"
  qnet="$(grep -oP '(?<=--quorumnet-port=)\d+' "${old_unit}" 2>/dev/null || true)"
  public_ip="$(grep -oP '(?<=--service-node-public-ip=)[0-9.]+' "${old_unit}" 2>/dev/null || true)"

  if [[ -z "${p2p}" || -z "${rpc}" || -z "${qnet}" ]]; then
    echo -e "  \033[0;31merror:\033[0m Could not extract ports from ${old_unit}"
    return 1
  fi
  if [[ -z "${public_ip}" ]]; then
    public_ip="$(detect_public_ip)"
  fi
  if [[ -z "${public_ip}" ]]; then
    echo -e "  \033[0;31merror:\033[0m Could not detect public IP — set --service-node-public-ip=<ip> in the old unit and re-run"
    return 1
  fi

  [[ -z "${qnet}" ]] && qnet=$(( p2p + 2 ))

  local xeqm_mdb_copy="/opt/xeqm/bin/xeqm-mdb_copy"

  echo -e "  Creating ${data_dir}..."
  sudo mkdir -p "${data_dir}"
  sudo chmod 0700 "${data_dir}"

  if [[ -d "${src_data}/lmdb" ]]; then
    if [[ -x "${xeqm_mdb_copy}" ]]; then
      # Live LMDB copy: xeqm-mdb_copy is compiled against the same bundled LMDB as xeqm-d,
      # so there is no version mismatch. The daemon keeps running and serving uptime proofs
      # while the copy runs. This is the zero-downtime path.
      echo -e "  Copying LMDB live with xeqm-mdb_copy -c (daemon stays up)..."
      sudo mkdir -p "${data_dir}/lmdb"
      sudo "${xeqm_mdb_copy}" -c "${src_data}/lmdb" "${data_dir}/lmdb"
      sudo chown -R xeqm:xeqm "${data_dir}/lmdb"
      echo -e "  LMDB copy complete — stopping daemon to snapshot SQLite databases..."
      sudo systemctl stop "xeqmnode_${user}.service" 2>/dev/null || true
      # Copy SQLite / ons.db and all other state files (except lmdb, already copied).
      sudo find "${src_data}" -maxdepth 1 ! -name 'lmdb' ! -path "${src_data}" \
        -exec sudo cp -a {} "${data_dir}/" \;
    else
      # Fallback: xeqm-mdb_copy not installed (older install or compile path).
      # Stop first so both LMDB and SQLite are captured in a consistent closed state.
      echo -e "  \033[0;33mxeqm-mdb_copy not found — stopping daemon for clean copy (~15-30s offline)\033[0m"
      sudo systemctl stop "xeqmnode_${user}.service" 2>/dev/null || true
      sudo cp -a "${src_data}/." "${data_dir}/"
    fi
  else
    echo -e "  \033[0;33mWarning: ${src_data} not found — node will sync from network\033[0m"
    sudo systemctl stop "xeqmnode_${user}.service" 2>/dev/null || true
  fi

  sudo chown -R xeqm:xeqm "${data_dir}"

  echo -e "  Writing canonical unit (in-place)..."
  write_canonical_unit "${target_snode}" "${p2p}" "${rpc}" "${qnet}" "${public_ip}" ""

  sudo systemctl daemon-reload
  echo -e "  Starting ${new_unit_name}..."
  sudo systemctl start "${new_unit_name}"

  # Poll for height > 1. height=1 means the daemon started fresh (blockchain not loaded).
  # We need height > 1 to confirm the copied blockchain opened successfully.
  echo -e "  Waiting for daemon to load blockchain (height > 1)..."
  local deadline=$(( $(date +%s) + 120 ))
  local height=0
  while [[ $(date +%s) -lt ${deadline} ]]; do
    local info
    info="$(curl -s --connect-timeout 3 "http://127.0.0.1:${rpc}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' 2>/dev/null || true)"
    height="$(echo "${info}" | grep -o '"height":[0-9]*' | head -1 | cut -d: -f2 || echo 0)"
    [[ "${height:-0}" -gt 1 ]] && break
    sleep 4
  done

  if [[ "${height:-0}" -gt 1 ]]; then
    echo -e "  \033[1;32m[PASS]\033[0m ${user} -> ${target_snode} running at height ${height}"
    return 0
  elif [[ "${height:-0}" -eq 1 ]]; then
    echo -e "  \033[0;31m[FAIL]\033[0m ${target_snode} at height=1 — blockchain copy did not load; node is syncing from scratch"
    return 1
  else
    echo -e "  \033[0;31m[FAIL]\033[0m ${target_snode} height=0 after 120s — check journalctl -u ${new_unit_name}"
    return 1
  fi
}

post_migration_report() {
  local -a migrated=("$@")

  echo -e "\n\033[1m══════════════════════════════════════════════════════\033[0m"
  echo -e "\033[1m  Migration Complete\033[0m"
  echo -e "\033[1m══════════════════════════════════════════════════════\033[0m\n"

  if [[ "${#migrated[@]}" -eq 0 ]]; then
    echo -e "  No nodes were successfully migrated.\n"
    return 0
  fi

  echo -e "\033[1m  Migrated nodes:\033[0m\n"
  for entry in "${migrated[@]}"; do
    local user="${entry%%:*}"
    local snode="${entry##*:}"
    echo -e "    ${user} -> ${snode}"
  done

  echo -e "\n\033[1m  Cleanup (run manually when ready):\033[0m\n"
  echo -e "  Remove old installer-layout user accounts:"
  for entry in "${migrated[@]}"; do
    local user="${entry%%:*}"
    echo -e "    sudo userdel -r ${user}"
  done

  echo -e "\n  Remove installer scripts from old home directories:"
  for entry in "${migrated[@]}"; do
    local user="${entry%%:*}"
    echo -e "    sudo rm -rf /home/${user}/xeqm-installer"
  done

  echo -e "\n  Then run doctor.sh to confirm all nodes are healthy:"
  echo -e "    sudo bash doctor.sh\n"
}

finally() {
  result=$?
  echo ""
  exit ${result}
}
trap finally EXIT ERR INT

main "$@"
