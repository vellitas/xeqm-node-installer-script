#!/usr/bin/env bash
# server-migrate.sh — migrate a service node from another server to this one
#
# Run this on the DESTINATION server AFTER installing a fresh node with install.sh.
# Connects to the source server via SSH, pulls the node keys (and optionally the
# blockchain data), replaces the local node's keys, and restarts it.

set -o errexit
set -o nounset
set -o pipefail

: "${script_basedir:=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")}"

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

server_migrate_version='v1.0'

# Detect layout of a local node by inspecting its systemd unit file.
# Sets: _dst_layout ("canonical"|"installer"), _dst_data_dir
resolve_local_node() {
  local node_name="$1"
  local unit_file="/etc/systemd/system/xeqmnode_${node_name}.service"
  if grep -q '^User=xeqm$' "${unit_file}" 2>/dev/null; then
    _dst_layout="canonical"
    _dst_data_dir="/var/lib/xeqm/${node_name}"
  else
    _dst_layout="installer"
    _dst_data_dir="/home/${node_name}/.xeqmlabs"
  fi
}

# Get pubkey of a local node via admin RPC (works for both layouts).
get_local_pubkey() {
  local node_name="$1"
  local unit_file="/etc/systemd/system/xeqmnode_${node_name}.service"
  local rpc_port
  rpc_port="$(grep -oP '(?<=--rpc-admin=127\.0\.0\.1:)\d+' "${unit_file}" 2>/dev/null || true)"
  if [[ -z "${rpc_port}" ]]; then echo ""; return; fi
  curl -s -m 3 "http://127.0.0.1:${rpc_port}/json_rpc" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"0","method":"get_service_node_status"}' 2>/dev/null \
    | grep -o '"service_node_pubkey":"[^"]*"' | cut -d'"' -f4 || true
}

server_migrate_run() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Server Migration" "${server_migrate_version}"

  # ── Discover local installed nodes via systemctl ───────────────────────────────
  local -a all_units=()
  mapfile -t all_units < <(systemctl list-units 'xeqmnode_*.service' \
    --no-pager --no-legend 2>/dev/null | awk '{print $1}' | natsort)

  local -a sorted_users=()
  for _u in "${all_units[@]}"; do
    local _sname="${_u%.service}"
    _sname="${_sname#xeqmnode_}"
    sorted_users+=("${_sname}")
  done

  if [[ "${#sorted_users[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo installed XEQM service nodes found on this server.\033[0m"
    echo -e "Run install.sh first to set up the destination node, then re-run this script.\n"
    exit 1
  fi

  # Show local node table
  echo ""
  printf "  %-14s  %-12s  %-16s  %s\n" "Local Node" "Layout" "Current Key" "Status"
  printf "  %s  %s  %s  %s\n" \
    "$(printf '%0.s─' {1..14})" "$(printf '%0.s─' {1..12})" \
    "$(printf '%0.s─' {1..16})" "$(printf '%0.s─' {1..8})"
  for u in "${sorted_users[@]}"; do
    local _pk _svc _dst_layout _dst_data_dir
    _pk="$(get_local_pubkey "${u}" | cut -c1-14 || true)"
    [[ -z "${_pk}" ]] && _pk="(unavailable)"
    resolve_local_node "${u}" 2>/dev/null || true
    sudo systemctl is-active --quiet "xeqmnode_${u}.service" 2>/dev/null \
      && _svc="running" || _svc="stopped"
    printf "  %-14s  %-12s  %-16s  %s\n" "${u}" "${_dst_layout:-?}" "${_pk}" "${_svc}"
  done
  echo ""

  # ── Select destination node slot ───────────────────────────────────────────────
  local dst_user=""
  if wt_available; then
    local -a wt_node_args=()
    for u in "${sorted_users[@]}"; do
      local _pk
      _pk="$(get_local_pubkey "${u}" | cut -c1-14 || true)"
      [[ -z "${_pk}" ]] && _pk="no key"
      wt_node_args+=( "${u}" "${u}  (key: ${_pk})" )
    done
    local _wt_rc
    wt_menu "Destination Node" \
      "Which local node slot will receive the migrated node?" \
      $(( ${#sorted_users[@]} + 8 )) 72 "${#sorted_users[@]}" dst_user \
      "${wt_node_args[@]}"
    _wt_rc=$?
    if [[ "${_wt_rc}" -ne 0 ]]; then echo -e "\nCancelled."; exit 0; fi
  else
    local -a node_items=()
    for u in "${sorted_users[@]}"; do
      local _pk
      _pk="$(get_local_pubkey "${u}" | cut -c1-14 || true)"
      [[ -z "${_pk}" ]] && _pk="no key"
      node_items+=( "${u}  (key: ${_pk})" )
    done
    local _node_idx
    prompt_menu "Which local node will receive the migrated node?" _node_idx 1 \
      "${node_items[@]}"
    dst_user="${sorted_users[$(( _node_idx - 1 ))]}"
  fi

  # ── Source server connection ────────────────────────────────────────────────────
  local src_host="" src_ssh_user="${USER}" src_ssh_port="22"

  if wt_available; then
    wt_inputbox "Source Server" \
      "Hostname or IP address of the server to migrate FROM\n(the failing/old server)." \
      10 62 src_host ""
    [[ $? -ne 0 || -z "${src_host}" ]] && { echo -e "\nCancelled."; exit 0; }

    wt_inputbox "SSH Username" \
      "SSH login user on the source server.\nMust have passwordless sudo." \
      9 60 src_ssh_user "${USER}"
    [[ $? -ne 0 ]] && { echo -e "\nCancelled."; exit 0; }

    wt_inputbox "SSH Port" "SSH port on the source server." \
      8 48 src_ssh_port "22"
    [[ $? -ne 0 ]] && { echo -e "\nCancelled."; exit 0; }
  else
    read -rp $'\n\033[1mSource server hostname/IP:\e[0m ' src_host
    [[ -z "${src_host}" ]] && { echo "Cancelled."; exit 0; }
    read -rp $'\033[1mSSH user\e[0m ['${USER}']: ' src_ssh_user
    src_ssh_user="${src_ssh_user:-${USER}}"
    read -rp $'\033[1mSSH port\e[0m [22]: ' src_ssh_port
    src_ssh_port="${src_ssh_port:-22}"
  fi

  # ── Test SSH connectivity ───────────────────────────────────────────────────────
  echo -e "\n\033[1mTesting SSH connection to ${src_ssh_user}@${src_host}:${src_ssh_port}...\033[0m"
  echo -e "  (New host keys are automatically accepted and saved to ~/.ssh/known_hosts)"
  local ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p ${src_ssh_port}"
  # shellcheck disable=SC2086
  if ! ssh ${ssh_opts} "${src_ssh_user}@${src_host}" "true" 2>/dev/null; then
    echo -e "\n\033[0;31m[FAIL]\033[0m Cannot connect to ${src_ssh_user}@${src_host}:${src_ssh_port}"
    echo -e "  Ensure SSH key authentication is configured for this server and try again.\n"
    exit 1
  fi
  echo -e "  \033[0;32m[ OK ]\033[0m SSH connected"

  # ── Discover source nodes (handles both canonical and installer layouts) ──────────
  echo -e "\n\033[1mDiscovering service nodes on ${src_host}...\033[0m"
  local src_node_user="" src_layout=""
  local -a src_nodes=()

  # Try canonical layout first (systemctl units named xeqmnode_*.service)
  local -a _canonical_units=()
  # shellcheck disable=SC2086
  while IFS= read -r _u; do [[ -n "${_u}" ]] && _canonical_units+=("${_u}"); done \
    < <(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
        "systemctl list-units 'xeqmnode_*.service' --no-pager --no-legend 2>/dev/null \
         | awk '{print \$1}' | sed 's/^xeqmnode_//;s/\.service\$//' | sort" 2>/dev/null)

  if [[ "${#_canonical_units[@]}" -gt 0 ]]; then
    src_layout="canonical"
    src_nodes=("${_canonical_units[@]}")
  else
    # Fall back to installer layout (snode* OS users)
    src_layout="installer"
    # shellcheck disable=SC2086
    while IFS= read -r _sn; do [[ -n "${_sn}" ]] && src_nodes+=("${_sn}"); done \
      < <(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
          "getent passwd | awk -F: '\$6 ~ /^\/home\/snode/ { print \$1 }' | sort" 2>/dev/null)
  fi

  if [[ "${#src_nodes[@]}" -eq 0 ]]; then
    echo -e "  \033[0;31m[FAIL]\033[0m No XEQM service nodes found on ${src_host}."
    echo -e "  Tried: canonical (xeqmnode_*.service) and installer-layout (snode* users).\n"
    exit 1
  fi
  echo -e "  Found ${#src_nodes[@]} node(s) [${src_layout}]: ${src_nodes[*]}"

  declare -A _src_pubkey_cache=()
  if wt_available; then
    local -a _src_wt_args=()
    for _sn in "${src_nodes[@]}"; do
      local _spk="unavailable"
      local _full_pk=""
      if [[ "${src_layout}" = "canonical" ]]; then
        # shellcheck disable=SC2086
        local _src_rpc
        _src_rpc="$(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
          "grep -oP '(?<=--rpc-admin=127\.0\.0\.1:)\d+' \
           /etc/systemd/system/xeqmnode_${_sn}.service 2>/dev/null || true" 2>/dev/null)"
        if [[ -n "${_src_rpc}" ]]; then
          # shellcheck disable=SC2086
          _full_pk="$(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
            "curl -s -m 3 http://127.0.0.1:${_src_rpc}/json_rpc -X POST \
             -H 'Content-Type: application/json' \
             -d '{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_service_node_status\"}' 2>/dev/null \
             | grep -o '\"service_node_pubkey\":\"[^\"]*\"' | cut -d'\"' -f4 || true" \
            2>/dev/null || true)"
        fi
      else
        # shellcheck disable=SC2086
        _full_pk="$(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
          "sudo -H -u ${_sn} bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_key 2>/dev/null'" \
          2>/dev/null | grep 'Public Key:' | grep -oP '(?<=: )+.*' || true)"
      fi
      _src_pubkey_cache["${_sn}"]="${_full_pk:-}"
      [[ -n "${_full_pk}" ]] && _spk="${_full_pk:0:14}"
      _src_wt_args+=( "${_sn}" "${_sn}  (key: ${_spk})" )
    done
    local _src_wt_rc
    wt_menu "Source Node" \
      "Which node on ${src_host} would you like to migrate?" \
      $(( ${#src_nodes[@]} + 8 )) 72 "${#src_nodes[@]}" src_node_user \
      "${_src_wt_args[@]}"
    _src_wt_rc=$?
    if [[ "${_src_wt_rc}" -ne 0 ]]; then echo -e "\nCancelled."; exit 0; fi
  else
    if [[ "${#src_nodes[@]}" -eq 1 ]]; then
      src_node_user="${src_nodes[0]}"
      echo -e "  Auto-selected: ${src_node_user}"
    else
      local _sn_idx
      prompt_menu "Which source node to migrate?" _sn_idx 1 "${src_nodes[@]}"
      src_node_user="${src_nodes[$(( _sn_idx - 1 ))]}"
    fi
  fi

  # ── Reuse pubkey cached during menu discovery (or fetch for text-mode path) ──
  local src_pubkey="${_src_pubkey_cache[${src_node_user}]:-}"

  if [[ -z "${src_pubkey}" ]]; then
    echo -e "\n\033[1mFetching public key for ${src_node_user}@${src_host}...\033[0m"
    if [[ "${src_layout}" = "canonical" ]]; then
      local _fb_rpc=""
      # shellcheck disable=SC2086
      _fb_rpc="$(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
        "grep -oP '(?<=--rpc-admin=127\.0\.0\.1:)\d+' \
         /etc/systemd/system/xeqmnode_${src_node_user}.service 2>/dev/null || true" 2>/dev/null)"
      if [[ -n "${_fb_rpc}" ]]; then
        # shellcheck disable=SC2086
        src_pubkey="$(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
          "curl -s -m 3 http://127.0.0.1:${_fb_rpc}/json_rpc -X POST \
           -H 'Content-Type: application/json' \
           -d '{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_service_node_status\"}' 2>/dev/null \
           | grep -o '\"service_node_pubkey\":\"[^\"]*\"' | cut -d'\"' -f4 || true" \
          2>/dev/null || true)"
      fi
    else
      # shellcheck disable=SC2086
      src_pubkey="$(ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
        "sudo -H -u ${src_node_user} bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_key 2>/dev/null'" \
        2>/dev/null | grep 'Public Key:' | grep -oP '(?<=: )+.*' || true)"
    fi
  fi

  if [[ -z "${src_pubkey}" ]]; then
    echo -e "  \033[0;33m[WARN]\033[0m Could not read pubkey (source daemon may be down)"
    echo -e "  Pubkey verification will be skipped after migration."
  else
    echo -e "  \033[0;32m[ OK ]\033[0m Source pubkey: \033[1m${src_pubkey:0:24}...\033[0m"
  fi

  # ── Ask about blockchain copy ───────────────────────────────────────────────────
  local copy_chain=0
  if wt_available; then
    wt_yesno "Copy Blockchain?" \
      "Copy blockchain data from the source node?\n\nYes  — faster startup, no re-sync (~15 min transfer)\nNo   — node re-syncs from network (may take hours)\n\nChoose No if the source blockchain might be corrupt." \
      13 62 "Copy blockchain" "Re-sync from network"
    [[ $? -eq 0 ]] && copy_chain=1
  else
    read -rp $'\n\033[1mAlso copy blockchain data from source?\e[0m (saves sync time) [y/N]: ' _cb
    [[ "${_cb,,}" = "y" || "${_cb,,}" = "yes" ]] && copy_chain=1
  fi

  # ── Confirm ─────────────────────────────────────────────────────────────────────
  local chain_note="re-sync from network"
  [[ "${copy_chain}" -eq 1 ]] && chain_note="copy from source"

  local confirm_body
  confirm_body="Migration plan:\n\n"
  confirm_body+="  Source:  ${src_ssh_user}@${src_host}  /home/${src_node_user}/\n"
  confirm_body+="  Dest:    ${dst_user} on this server\n"
  confirm_body+="  Keys:    key_ed25519 + key_bls (if present)\n"
  confirm_body+="  Chain:   ${chain_note}\n"
  [[ -n "${src_pubkey}" ]] && confirm_body+="  Pubkey:  ${src_pubkey:0:24}...\n"
  confirm_body+="\nThe local node will be stopped during migration.\n"
  confirm_body+="Existing local keys will be backed up automatically."

  if wt_available; then
    wt_yesno "Confirm Migration" "${confirm_body}" 18 68 "Migrate" "Cancel"
    [[ $? -ne 0 ]] && { echo -e "\nCancelled."; exit 0; }
  else
    echo ""
    printf '%b\n' "${confirm_body}" | sed 's/^/  /'
    read -rp $'\n\033[1mProceed with migration?\e[0m [y/N]: ' _yn
    [[ "${_yn,,}" != "y" && "${_yn,,}" != "yes" ]] && { echo "Cancelled."; exit 0; }
  fi

  # ── Execute migration ───────────────────────────────────────────────────────────
  echo ""
  tput rev 2>/dev/null || true; printf "\033[1m  MIGRATING  \033[0m\n"; tput sgr0 2>/dev/null || true
  echo ""

  # Determine destination layout and paths
  local _dst_layout _dst_data_dir
  resolve_local_node "${dst_user}"
  local dst_data_dir="${_dst_data_dir}"
  local dst_owner
  if [[ "${_dst_layout}" = "canonical" ]]; then dst_owner="xeqm:xeqm"; else dst_owner="${dst_user}:${dst_user}"; fi

  # Determine source key paths based on layout
  local src_data_dir
  if [[ "${src_layout}" = "canonical" ]]; then
    src_data_dir="/var/lib/xeqm/${src_node_user}"
  else
    src_data_dir="/home/${src_node_user}/.xeqmlabs"
  fi

  local backup_dir="${dst_data_dir}/keys-backup-$(date +%Y%m%d%H%M%S)"
  local tmp_ed="/tmp/xeqm-mig-ed25519-$$"
  local tmp_bls="/tmp/xeqm-mig-bls-$$"

  # Stop destination node
  echo -e "  Stopping local node ${dst_user}..."
  if [[ "${_dst_layout}" = "canonical" ]]; then
    sudo systemctl stop "xeqmnode_${dst_user}" 2>/dev/null || true
  else
    sudo -H -u "${dst_user}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop' 2>/dev/null || true
  fi
  sleep 2

  # Back up existing keys
  sudo mkdir -p "${dst_data_dir}"
  if [[ -f "${dst_data_dir}/key_ed25519" ]]; then
    sudo mkdir -p "${backup_dir}"
    sudo cp "${dst_data_dir}/key_ed25519" "${backup_dir}/" 2>/dev/null || true
    if [[ -f "${dst_data_dir}/key_bls" ]]; then
      sudo cp "${dst_data_dir}/key_bls" "${backup_dir}/" 2>/dev/null || true
    fi
    echo -e "  Existing keys backed up to: ${backup_dir}"
  fi

  # Pull ed25519 key
  echo -e "  Pulling key_ed25519 from source..."
  # shellcheck disable=SC2086
  ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
    "sudo cat ${src_data_dir}/key_ed25519" > "${tmp_ed}"

  if [[ ! -s "${tmp_ed}" ]]; then
    rm -f "${tmp_ed}" "${tmp_bls}"
    echo -e "\n\033[0;31m[FAIL]\033[0m key_ed25519 not found or empty on source."
    echo -e "  Check: ${src_data_dir}/key_ed25519 on ${src_host}\n"
    exit 1
  fi
  sudo cp "${tmp_ed}" "${dst_data_dir}/key_ed25519"
  sudo chown "${dst_owner}" "${dst_data_dir}/key_ed25519"
  sudo chmod 600 "${dst_data_dir}/key_ed25519"
  echo -e "  \033[0;32m[ OK ]\033[0m key_ed25519 installed"

  # Pull BLS key (optional)
  # shellcheck disable=SC2086
  if ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
    "sudo test -f ${src_data_dir}/key_bls" 2>/dev/null; then
    echo -e "  Pulling key_bls from source..."
    # shellcheck disable=SC2086
    ssh ${ssh_opts} "${src_ssh_user}@${src_host}" \
      "sudo cat ${src_data_dir}/key_bls" > "${tmp_bls}"
    if [[ -s "${tmp_bls}" ]]; then
      sudo cp "${tmp_bls}" "${dst_data_dir}/key_bls"
      sudo chown "${dst_owner}" "${dst_data_dir}/key_bls"
      sudo chmod 600 "${dst_data_dir}/key_bls"
      echo -e "  \033[0;32m[ OK ]\033[0m key_bls installed"
    fi
  fi
  rm -f "${tmp_ed}" "${tmp_bls}"

  # Optionally copy blockchain via rsync
  if [[ "${copy_chain}" -eq 1 ]]; then
    echo -e "  Copying blockchain from source (may take several minutes)..."
    sudo mkdir -p "${dst_data_dir}/lmdb"
    local rsync_ssh="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p ${src_ssh_port}"
    if sudo rsync -a --info=progress2 \
      --rsync-path="sudo rsync" \
      -e "${rsync_ssh}" \
      "${src_ssh_user}@${src_host}:${src_data_dir}/lmdb/" \
      "${dst_data_dir}/lmdb/" 2>/dev/null; then
      sudo chown -R "${dst_owner}" "${dst_data_dir}/lmdb"
      echo -e "  \033[0;32m[ OK ]\033[0m Blockchain data copied"
    else
      echo -e "  \033[0;33m[WARN]\033[0m Blockchain copy failed — node will re-sync from network"
    fi
  fi

  # Start destination node
  echo -e "  Starting local node ${dst_user}..."
  if [[ "${_dst_layout}" = "canonical" ]]; then
    sudo systemctl start "xeqmnode_${dst_user}"
  else
    sudo -H -u "${dst_user}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'
  fi

  # Verify pubkey (retry for up to 30s while daemon initialises)
  echo -e "  Waiting for daemon to report pubkey..."
  local new_pubkey="" attempts=0
  while [[ -z "${new_pubkey}" && "${attempts}" -lt 6 ]]; do
    sleep 5
    new_pubkey="$(get_local_pubkey "${dst_user}")"
    attempts=$(( attempts + 1 ))
  done

  echo ""
  if [[ -n "${src_pubkey}" && "${new_pubkey}" = "${src_pubkey}" ]]; then
    echo -e "  \033[0;32m[PASS]\033[0m Pubkey verified: ${new_pubkey:0:24}..."
  elif [[ -n "${new_pubkey}" && -z "${src_pubkey}" ]]; then
    echo -e "  \033[0;32m[ OK ]\033[0m Local pubkey: ${new_pubkey:0:24}..."
    echo -e "         (source was unreachable — compare manually to confirm match)"
  elif [[ -z "${new_pubkey}" ]]; then
    echo -e "  \033[0;33m[WAIT]\033[0m Daemon not yet responding — verify once it's fully started:"
    echo -e "        \033[0;36msudo bash ${script_basedir}/transfer.sh --list\033[0m"
  else
    echo -e "  \033[0;31m[FAIL]\033[0m Pubkey mismatch!"
    echo -e "        Expected: ${src_pubkey}"
    echo -e "        Got:      ${new_pubkey}"
    echo -e "        Check ${dst_data_dir}/key_ed25519 — restored backup is at ${backup_dir}"
  fi

  # ── Post-migration instructions ─────────────────────────────────────────────────
  local src_stop_cmd
  if [[ "${src_layout}" = "canonical" ]]; then
    src_stop_cmd="sudo systemctl stop xeqmnode_${src_node_user}"
  else
    src_stop_cmd="sudo -H -u ${src_node_user} bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop'"
  fi

  echo ""
  printf '\033[1m%s\033[0m\n' "Next steps:"
  echo -e "  1. Confirm uptime proofs appear in the operator dashboard"
  echo -e "  2. Stop the source node on ${src_host} to avoid running duplicate keys:"
  printf '     \033[0;36m%s\033[0m\n' \
    "ssh -p ${src_ssh_port} ${src_ssh_user}@${src_host} \"${src_stop_cmd}\""
  echo -e "  3. Running two nodes with the same key simultaneously is not supported"
  echo ""
  [[ "${XEQM_FROM_MENU:-0}" = "1" ]] && read -rp $'  Press Enter to return to the menu...' _
}

server_migrate_finally() {
  result=$?
  echo ""
  exit ${result}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap server_migrate_finally EXIT ERR INT
  server_migrate_run "$@"
fi
