#!/usr/bin/env bash
# decommission.sh — start or check node decommission (self-unregistration, 14-day lock, rewards continue)

set -o errexit
set -o nounset
set -o pipefail

: "${script_basedir:=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")}"

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

decommission_version='v1.0'
readonly decommission_version

readonly _SECS_PER_BLOCK=120   # mainnet ~2-min blocks
readonly _BLOCKS_PER_DAY=720

# ── Helpers ───────────────────────────────────────────────────────────────────

# query_sn_chain <rpc_port> <pubkey>  →  stdout: raw JSON from get_service_nodes
query_sn_chain() {
  local _port="$1" _pk="$2"
  curl -s -m 5 "http://127.0.0.1:${_port}/json_rpc" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_service_nodes\",\
\"params\":{\"service_node_pubkeys\":[\"${_pk}\"]}}" 2>/dev/null || true
}

# estimate_unlock_date <unlock_height> <current_height>  →  stdout: date string
estimate_unlock_date() {
  local _uh="$1" _ch="$2"
  if [[ "${_uh}" -le "${_ch}" ]]; then
    echo "imminent (unlock height already reached)"
    return
  fi
  local _secs=$(( (_uh - _ch) * _SECS_PER_BLOCK ))
  date -d "+${_secs} seconds" '+%Y-%m-%d %H:%M UTC' 2>/dev/null \
    || echo "~$(( (_uh - _ch) / _BLOCKS_PER_DAY )) days from now"
}

# ── Main ──────────────────────────────────────────────────────────────────────

decommission_run() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Service Node Decommission" "${decommission_version}"

  # ── Discover nodes ─────────────────────────────────────────────────────────
  declare -A snode_rpc_map=()
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    while IFS= read -r plist; do
      local _pbase _sname _rpc_port
      _pbase="$(basename "${plist}" .plist)"
      _sname="${_pbase##*.}"   # com.xeqmlabs.snode1 → snode1
      _rpc_port="$(grep -o -- '--rpc-admin=[^ <]*' "${plist}" | grep -o '[0-9]*$' || true)"
      [[ -n "${_rpc_port}" ]] && snode_rpc_map["${_sname}"]="${_rpc_port}"
    done < <(find "${XEQM_SVC_DIR}" -maxdepth 1 -name "${XEQM_SVC_LABEL_PREFIX}.snode*.plist" 2>/dev/null | sort)
  else
    local -a all_units=()
    mapfile -t all_units < <(systemctl list-units 'xeqmnode_*.service' \
      --no-pager --no-legend 2>/dev/null | awk '{print $1}' | natsort)
    for _unit in "${all_units[@]}"; do
      local _sname="${_unit%.service}"
      _sname="${_sname#xeqmnode_}"
      local _exec_raw _rpc_port
      _exec_raw="$(systemctl show "${_unit}" -p ExecStart 2>/dev/null || true)"
      _rpc_port="$(printf '%s' "${_exec_raw}" | grep -o -- '--rpc-admin=[^ ;]*' | grep -o '[0-9]*$' || true)"
      [[ -n "${_rpc_port}" ]] && snode_rpc_map["${_sname}"]="${_rpc_port}"
    done
  fi

  local -a all_snodes=()
  mapfile -t all_snodes < <(printf '%s\n' "${!snode_rpc_map[@]}" | natsort)

  if [[ "${#all_snodes[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo active XEQM service node daemons found on this server.\033[0m\n"
    exit 0
  fi

  # ── Get current chain height (from first responsive daemon) ────────────────
  local current_height=0
  for _sn in "${all_snodes[@]}"; do
    local _rpc="${snode_rpc_map[${_sn}]}"
    local _info _ht
    _info="$(curl -s -m 3 "http://127.0.0.1:${_rpc}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' 2>/dev/null || true)"
    _ht="$(printf '%s' "${_info}" | grep -o '"height":[0-9]*' | head -1 | cut -d: -f2 || true)"
    if [[ -n "${_ht}" && "${_ht}" -gt 0 ]]; then
      current_height="${_ht}"
      break
    fi
  done

  # ── Classify nodes ─────────────────────────────────────────────────────────
  local _total="${#all_snodes[@]}" _idx=0
  local -a active_names=() active_keys=() active_ports=()
  local -a unlocking_names=() unlocking_keys=() unlocking_hts=() unlocking_dates=()

  echo ""
  for _sn in "${all_snodes[@]}"; do
    _idx=$(( _idx + 1 ))
    printf "\r  \033[1mChecking [ %d / %d ]\033[0m %-20s" "${_idx}" "${_total}" "${_sn}"

    local _rpc="${snode_rpc_map[${_sn}]}"

    # Get the node's public key via RPC
    local _pk=""
    _pk="$(curl -s -m 3 "http://127.0.0.1:${_rpc}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_service_node_status"}' 2>/dev/null \
      | grep -o '"service_node_pubkey":"[^"]*"' | cut -d'"' -f4 || true)"
    if [[ -z "${_pk}" ]]; then continue; fi

    # Query chain for this pubkey
    local _json
    _json="$(query_sn_chain "${_rpc}" "${_pk}")"

    # Skip if not registered on chain
    if ! printf '%s' "${_json}" | grep -q '"service_node_pubkey"'; then continue; fi

    local _unlock_ht
    _unlock_ht="$(printf '%s' "${_json}" | grep -o '"requested_unlock_height":[0-9]*' | head -1 | cut -d: -f2 || true)"
    _unlock_ht="${_unlock_ht:-0}"

    if [[ "${_unlock_ht}" -gt 0 ]]; then
      local _udate
      _udate="$(estimate_unlock_date "${_unlock_ht}" "${current_height}")"
      unlocking_names+=( "${_sn}" )
      unlocking_keys+=( "${_pk}" )
      unlocking_hts+=( "${_unlock_ht}" )
      unlocking_dates+=( "${_udate}" )
    else
      active_names+=( "${_sn}" )
      active_keys+=( "${_pk}" )
      active_ports+=( "${_rpc}" )
    fi
  done
  printf "\r%-70s\r" ""

  # ── Show nodes currently unlocking ─────────────────────────────────────────
  if [[ "${#unlocking_names[@]}" -gt 0 ]]; then
    echo ""
    tput rev 2>/dev/null || true; printf "\033[1m  NODES IN UNLOCK PERIOD (14-day decommission)  \033[0m\n"; tput sgr0 2>/dev/null || true
    echo ""
    printf "  %-15s  %-10s  %s\n" "Node" "Unlock Ht" "Estimated Unlock Date"
    printf "  %-15s  %-10s  %s\n" \
      "$(printf '%*s' 15 '' | tr ' ' '-')" \
      "$(printf '%*s' 10 '' | tr ' ' '-')" \
      "$(printf '%*s' 30 '' | tr ' ' '-')"
    for i in "${!unlocking_names[@]}"; do
      printf "  %-15s  %-10s  %s\n" \
        "${unlocking_names[$i]}" "${unlocking_hts[$i]}" "${unlocking_dates[$i]}"
    done
    echo ""
    echo -e "  Rewards continue until the unlock height is reached, then stake is released."
  fi

  # ── No active nodes ─────────────────────────────────────────────────────────
  if [[ "${#active_names[@]}" -eq 0 ]]; then
    if [[ "${#unlocking_names[@]}" -gt 0 ]]; then
      echo -e "\n  No additional active nodes to decommission.\n"
    else
      echo -e "\n\033[0;33mNo registered service nodes found on this server.\033[0m\n"
      echo -e "  Run register.sh if your nodes have not been registered yet.\n"
    fi
    exit 0
  fi

  # ── Select node to decommission ────────────────────────────────────────────
  local target_user="" target_pubkey=""

  if wt_available; then
    local -a _wt_args=()
    for i in "${!active_names[@]}"; do
      _wt_args+=( "${active_names[$i]}" "${active_keys[$i]:0:28}..." )
    done
    wt_menu "Decommission — Select Node" \
      "Select a commissioned node to begin self-unregistration.\n14-day lock. Rewards continue until unlock height." \
      $(( ${#active_names[@]} + 11 )) 74 "${#active_names[@]}" target_user \
      "${_wt_args[@]}" || { echo -e "\nCancelled."; exit 0; }
    for i in "${!active_names[@]}"; do
      if [[ "${active_names[$i]}" = "${target_user}" ]]; then target_pubkey="${active_keys[$i]}"; break; fi
    done
  else
    echo ""
    local _choice_idx
    prompt_menu "Which node to decommission?" _choice_idx 1 \
      "${active_names[@]}"
    target_user="${active_names[$(( _choice_idx - 1 ))]}"
    target_pubkey="${active_keys[$(( _choice_idx - 1 ))]}"
  fi

  # ── Confirm ────────────────────────────────────────────────────────────────
  local _est_unlock_date=""
  local _est_unlock_ht=0
  if [[ "${current_height}" -gt 0 ]]; then
    _est_unlock_ht=$(( current_height + _BLOCKS_PER_DAY * 14 ))
    _est_unlock_date="$(estimate_unlock_date "${_est_unlock_ht}" "${current_height}")"
  fi

  if wt_available; then
    local _confirm_body="Node:    ${target_user}\nPubkey:  ${target_pubkey:0:28}..."
    [[ -n "${_est_unlock_date}" ]] && _confirm_body+="\n\nEstimated unlock: ${_est_unlock_date}"
    _confirm_body+="\n\nThis will lock your stake for ~14 days.\nRewards continue until the unlock height.\nThis CANNOT be undone once submitted."
    wt_yesno "Confirm Decommission" "${_confirm_body}" 16 70 "Decommission" "Cancel" \
      || { echo -e "\nCancelled."; exit 0; }
  else
    echo ""
    echo -e "  \033[1mNode:\033[0m   ${target_user}"
    echo -e "  \033[1mPubkey:\033[0m ${target_pubkey:0:32}..."
    [[ -n "${_est_unlock_date}" ]] && echo -e "  \033[1mEst. unlock:\033[0m ${_est_unlock_date}"
    echo -e "\n  \033[0;33mWARNING: Stake locked ~14 days. Rewards continue. Cannot be undone.\033[0m"
    local _yn
    read -rp $'\n\033[1mConfirm decommission?\e[0m [y/N]: ' _yn
    [[ "${_yn,,}" != "y" ]] && { echo -e "\nCancelled."; exit 0; }
  fi

  # ── Print wallet command ───────────────────────────────────────────────────
  echo ""
  tput rev 2>/dev/null || true; printf "\033[1m  DECOMMISSION COMMAND  \033[0m\n"; tput sgr0 2>/dev/null || true
  echo ""
  echo -e "  Run this command in your XEQM wallet CLI:"
  echo ""
  printf "  \033[1;36mrequest_stake_unlock %s\033[0m\n" "${target_pubkey}"
  echo ""
  if [[ -n "${_est_unlock_date}" ]]; then
    echo -e "  Estimated unlock: \033[1m${_est_unlock_date}\033[0m  (block ~${_est_unlock_ht})"
  fi
  echo -e "  Rewards continue until the unlock height is reached.\n"

  # Save to file
  local _out="${script_basedir}/decommission_command.txt"
  {
    printf "# XEQM Service Node Decommission Command\n"
    printf "# Node:      %s\n" "${target_user}"
    printf "# Pubkey:    %s\n" "${target_pubkey}"
    [[ -n "${_est_unlock_date}" ]] && printf "# Est unlock: %s (block ~%s)\n" "${_est_unlock_date}" "${_est_unlock_ht}"
    printf "# Generated: %s\n\n" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    printf "request_stake_unlock %s\n" "${target_pubkey}"
  } > "${_out}"
  echo -e "  \033[1mSaved to:\033[0m ${_out}\n"
  [[ "${XEQM_FROM_MENU:-0}" = "1" ]] && read -rp $'  Press Enter to return to the menu...' _
}

decommission_usage() {
  cat <<USAGEMSG

bash $0

  Shows commissioned nodes on this server and lets you start a 14-day
  self-unregistration (rewards continue until unlock height).
  Also shows the status of any nodes already in the unlock period.

USAGEMSG
}

decommission_finally() {
  result=$?
  echo ""
  exit ${result}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap decommission_finally EXIT ERR INT
  decommission_run "$@"
fi
