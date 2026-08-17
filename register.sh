#!/usr/bin/env bash
# register.sh — generate register_service_node commands for all installed nodes

set -o errexit
set -o nounset
set -o pipefail

: "${script_basedir:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

register_version='v2.0'

# ── Per-node question helpers ─────────────────────────────────────────────────

# ask_node_type <node_label> → sets globals: _contribution_xeqm  _operator_cut
ask_node_type() {
  local _label="$1"
  _contribution_xeqm=200000
  _operator_cut=0

  if wt_available; then
    local _choice
    wt_menu "${_label}" \
      "How would you like to stake this node?" \
      10 70 2 _choice \
      "solo"   "Solo node — stake the full 200,000 XEQM yourself" \
      "shared" "Shared node — stake ≥ 100,000 XEQM, open to contributors"
    local _rc=$?; [[ ${_rc} -ne 0 ]] && return 1

    if [[ "${_choice}" = "shared" ]]; then
      while true; do
        local _amt
        wt_inputbox "${_label} — Contribution" \
          "How much XEQM will you contribute?\n\nMinimum: 100,000   Maximum: 200,000" \
          10 58 _amt "100000"
        _rc=$?; [[ ${_rc} -ne 0 ]] && return 1
        if [[ "${_amt}" =~ ^[0-9]+$ && "${_amt}" -ge 100000 && "${_amt}" -le 200000 ]]; then
          _contribution_xeqm="${_amt}"; break
        fi
        wt_msgbox "Invalid Amount" "Please enter a number between 100000 and 200000." 8 52
      done

      while true; do
        local _fee
        wt_inputbox "${_label} — Operator Fee" \
          "Percentage of rewards you keep before sharing with contributors.\n\nEnter 0 for no fee.  Maximum is 10." \
          10 62 _fee "0"
        _rc=$?; [[ ${_rc} -ne 0 ]] && return 1
        if [[ "${_fee}" =~ ^[0-9]+$ && "${_fee}" -ge 0 && "${_fee}" -le 10 ]]; then
          _operator_cut="${_fee}"; break
        fi
        wt_msgbox "Invalid Fee" "Please enter a whole number between 0 and 10." 8 50
      done
    fi
  else
    local _node_type_choice
    prompt_menu "How would you like to stake ${_label}?" _node_type_choice 1 \
      "Solo node  — stake the full 200,000 XEQM yourself" \
      "Shared node  — stake ≥ 100,000 XEQM, open to contributors"

    if [[ "${_node_type_choice}" -eq 2 ]]; then
      while true; do
        read -rp $'\n\033[1mHow much XEQM will you contribute?\e[0m (100000–200000) [100000]: ' _contribution_xeqm
        _contribution_xeqm="${_contribution_xeqm:-100000}"
        [[ "${_contribution_xeqm}" =~ ^[0-9]+$ && "${_contribution_xeqm}" -ge 100000 && \
           "${_contribution_xeqm}" -le 200000 ]] && break
        echo -e "  \033[0;33mPlease enter a number between 100000 and 200000.\033[0m"
      done

      while true; do
        read -rp $'\n\033[1mOperator fee\e[0m — your % of rewards before sharing (0–10) [0]: ' _operator_cut
        _operator_cut="${_operator_cut:-0}"
        [[ "${_operator_cut}" =~ ^[0-9]+$ && "${_operator_cut}" -ge 0 && \
           "${_operator_cut}" -le 10 ]] && break
        echo -e "  \033[0;33mPlease enter a number between 0 and 10.\033[0m"
      done
    fi
  fi
  return 0
}

# ask_wallet <node_label> <default> → sets global: _wallet_address
ask_wallet() {
  local _label="$1" _default="$2"
  _wallet_address=""

  if wt_available; then
    while true; do
      wt_inputbox "${_label} — Wallet Address" \
        "Enter your XEQM wallet address.\n\nMust start with XEQM (~97 characters)." \
        11 74 _wallet_address "${_default}"
      local _rc=$?; [[ ${_rc} -ne 0 ]] && return 1
      _wallet_address="${_wallet_address//[[:space:]]/}"
      if [[ -z "${_wallet_address}" ]]; then
        wt_msgbox "Invalid Address" "Wallet address cannot be empty." 8 48
      elif [[ ! "${_wallet_address}" =~ ^XEQM ]]; then
        wt_msgbox "Invalid Address" "XEQM addresses start with 'XEQM'.\nPlease check and re-enter." 9 56
      elif [[ "${#_wallet_address}" -lt 90 || "${#_wallet_address}" -gt 110 ]]; then
        wt_msgbox "Invalid Address" \
          "Address length looks wrong (${#_wallet_address} chars, expected ~97).\nPlease re-enter." 9 62
      else
        break
      fi
    done
  else
    while true; do
      [[ -n "${_default}" ]] && echo -e "  (press Enter to reuse: ${_default:0:20}...)"
      read -rp $'\n\033[1mYour XEQM wallet address:\e[0m ' _wallet_address
      _wallet_address="${_wallet_address//[[:space:]]/}"
      [[ -z "${_wallet_address}" && -n "${_default}" ]] && _wallet_address="${_default}"
      if [[ -z "${_wallet_address}" ]]; then
        echo -e "  \033[0;33mWallet address cannot be empty.\033[0m"
      elif [[ ! "${_wallet_address}" =~ ^XEQM ]]; then
        echo -e "  \033[0;33mXEQM addresses start with 'XEQM'. Please check and re-enter.\033[0m"
      elif [[ "${#_wallet_address}" -lt 90 || "${#_wallet_address}" -gt 110 ]]; then
        echo -e "  \033[0;33mAddress length looks wrong (${#_wallet_address} chars, expected ~97).\033[0m"
      else
        break
      fi
    done
  fi
  return 0
}

# is_node_registered <rpc_port>  → 0=registered or unlocking, 1=not registered / unknown
is_node_registered() {
  local _rpc_port="$1"
  local _json
  _json="$(curl -s -m 5 "http://127.0.0.1:${_rpc_port}/json_rpc" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"0","method":"get_service_node_status"}' 2>/dev/null)"
  echo "${_json}" | grep -qE '"service_node_state"[^}]*(registered|unlocking)'
}

# ── Main ──────────────────────────────────────────────────────────────────────

register_run() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Service Node Registration" "${register_version}"

  # ── Discover nodes from systemd units ─────────────────────────────────────
  echo -e "\n\033[1mDiscovering service nodes...\033[0m"

  # snode_name → rpc_port (works for both canonical and installer layout)
  declare -A snode_rpc_map=()

  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    # macOS: discover nodes from LaunchAgent plists
    while IFS= read -r plist; do
      [[ -z "${plist}" ]] && continue
      local plist_base snode_name rpc_port
      plist_base="$(basename "${plist}" .plist)"
      snode_name="${plist_base##*.}"   # com.xeqmlabs.snode1 → snode1
      rpc_port="$(grep -o -- '--rpc-admin=[^ <]*' "${plist}" | grep -o '[0-9]*$' || true)"
      [[ -z "${rpc_port}" ]] && continue
      snode_rpc_map["${snode_name}"]="${rpc_port}"
    done < <(find "${XEQM_SVC_DIR}" -maxdepth 1 -name "${XEQM_SVC_LABEL_PREFIX}.snode*.plist" 2>/dev/null | sort)
  else
    while read -r unit_name; do
      [[ -z "${unit_name}" ]] && continue
      local snode_name="${unit_name%.service}"
      snode_name="${snode_name#xeqmnode_}"
      local exec_raw rpc_port
      exec_raw="$(systemctl show "${unit_name}" -p ExecStart 2>/dev/null)"
      rpc_port="$(echo "${exec_raw}" | grep -o -- '--rpc-admin=[^ ;]*' | grep -o '[0-9]*$' || true)"
      [[ -z "${rpc_port}" ]] && continue
      snode_rpc_map["${snode_name}"]="${rpc_port}"
    done < <(systemctl list-units 'xeqmnode_*.service' --no-pager --no-legend 2>/dev/null \
      | awk '{print $1}' | natsort)
  fi

  if [[ "${#snode_rpc_map[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo active XEQM service node units found on this server.\033[0m\n"
    exit 0
  fi

  mapfile -t all_snodes < <(printf '%s\n' "${!snode_rpc_map[@]}" | natsort)
  echo -e "  Found ${#all_snodes[@]} node(s): ${all_snodes[*]}"

  # Filter to unregistered nodes
  echo -e "  Checking registration status..."
  local -a unregistered_snodes=()
  for _sn in "${all_snodes[@]}"; do
    local _rpc="${snode_rpc_map[${_sn}]}"
    local _json
    _json="$(curl -s -m 5 "http://127.0.0.1:${_rpc}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_service_node_status"}' 2>/dev/null || true)"
    if echo "${_json}" | grep -qE '"service_node_state"[^}]*"unlocking"'; then
      echo -e "    \033[0;33m[unlocking]\033[0m ${_sn} — 14-day stake unlock in progress, skipping"
    elif echo "${_json}" | grep -qE '"service_node_state"[^}]*"registered"'; then
      echo -e "    \033[0;32m[registered]\033[0m ${_sn} — already on network, skipping"
    else
      unregistered_snodes+=("${_sn}")
    fi
  done

  if [[ "${#unregistered_snodes[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;32mAll nodes are already registered on the network.\033[0m\n"
    exit 0
  fi
  all_snodes=("${unregistered_snodes[@]}")
  echo -e "  \033[1m${#all_snodes[@]}\033[0m unregistered node(s) ready to register\n"

  # ── Step 1: Select which nodes to register ─────────────────────────────────
  local -a selected_snodes=()

  if wt_available; then
    local -a checklist_args=()
    local _cn
    for _cn in "${all_snodes[@]}"; do
      local _crpc="${snode_rpc_map[${_cn}]}"
      checklist_args+=( "${_cn}" "RPC :${_crpc}" "ON" )
    done

    local selected_raw=""
    selected_raw="$(whiptail --title "Select Nodes to Register" \
      --ok-button "Continue" \
      --cancel-button "Cancel" \
      --checklist "Space to deselect. All nodes are selected by default." \
      $(( ${#all_snodes[@]} + 9 )) 60 "${#all_snodes[@]}" \
      "${checklist_args[@]}" 3>&1 1>&2 2>&3)" || { echo -e "\nCancelled."; exit 0; }

    if [[ -z "${selected_raw}" ]]; then
      wt_msgbox "Nothing Selected" "No nodes were selected — nothing to register." 8 54
      exit 0
    fi

    local _item _raw_arr
    read -ra _raw_arr <<< "${selected_raw}"
    for _item in "${_raw_arr[@]}"; do
      _item="${_item//\"/}"
      [[ -n "${_item}" ]] && selected_snodes+=("${_item}")
    done
  else
    echo -e "\n\033[1mFound ${#all_snodes[@]} node(s): ${all_snodes[*]}\033[0m"
    local _sel_mode
    prompt_menu "Which nodes would you like to register?" _sel_mode 1 \
      "All ${#all_snodes[@]} node(s)" \
      "Select specific nodes"
    if [[ "${_sel_mode}" -eq 1 ]]; then
      selected_snodes=("${all_snodes[@]}")
    else
      read -rp $'\n\033[1mEnter node names (comma-separated):\e[0m ' _sel_input
      local _raw_sel
      IFS=',' read -ra _raw_sel <<< "${_sel_input}"
      local _st
      for _st in "${_raw_sel[@]}"; do selected_snodes+=("${_st// /}"); done
    fi
  fi

  if [[ "${#selected_snodes[@]}" -eq 0 ]]; then
    echo -e "\nNothing selected — cancelled.\n"
    exit 0
  fi

  echo -e "  Registering ${#selected_snodes[@]} node(s): ${selected_snodes[*]}\n"

  # ── Step 2: Same settings for all? ─────────────────────────────────────────
  local -a node_names=()
  local -a node_rpc_ports=()
  local -a node_wallets=()
  local -a node_contribution_atomics=()
  local -a node_operator_cuts=()

  local _use_same=0
  if [[ "${#selected_snodes[@]}" -gt 1 ]]; then
    if wt_available; then
      if wt_yesno "Registration Settings" \
        "Use the same wallet address and staking type for all ${#selected_snodes[@]} selected nodes?\n\nYes = enter settings once for all\nNo  = configure each node individually" \
        12 64 "Same for all" "Configure each"; then
        _use_same=1
      fi
    else
      local _same_choice
      prompt_menu "Registration settings:" _same_choice 1 \
        "Same wallet + staking type for all ${#selected_snodes[@]} nodes" \
        "Configure each node individually"
      [[ "${_same_choice}" -eq 1 ]] && _use_same=1
    fi
  fi

  local _contribution_xeqm _operator_cut _wallet_address

  if [[ "${_use_same}" -eq 1 ]]; then
    ask_node_type "All ${#selected_snodes[@]} Nodes" || { echo -e "\nCancelled."; exit 0; }
    local _shared_contribution="${_contribution_xeqm}" _shared_cut="${_operator_cut}"
    ask_wallet "All ${#selected_snodes[@]} Nodes" "" || { echo -e "\nCancelled."; exit 0; }
    local _shared_wallet="${_wallet_address}"

    local _sn
    for _sn in "${selected_snodes[@]}"; do
      node_names+=( "${_sn}" )
      node_rpc_ports+=( "${snode_rpc_map[${_sn}]}" )
      node_wallets+=( "${_shared_wallet}" )
      node_contribution_atomics+=( "$(( _shared_contribution * 1000000000 ))" )
      node_operator_cuts+=( "$(( _shared_cut * 100 ))" )
    done
  else
    local last_wallet=""
    local _sn
    for _sn in "${selected_snodes[@]}"; do
      local rpc_port="${snode_rpc_map[${_sn}]}"
      local label="Node — ${_sn}"

      tput rev 2>/dev/null || true; printf "\n\033[1m  %s (RPC :%s)  \033[0m\n" "${_sn}" "${rpc_port}"; tput sgr0 2>/dev/null || true

      ask_node_type "${label}" || { echo -e "\nCancelled."; exit 0; }
      ask_wallet "${label}" "${last_wallet}" || { echo -e "\nCancelled."; exit 0; }
      last_wallet="${_wallet_address}"

      node_names+=( "${_sn}" )
      node_rpc_ports+=( "${rpc_port}" )
      node_wallets+=( "${_wallet_address}" )
      node_contribution_atomics+=( "$(( _contribution_xeqm * 1000000000 ))" )
      node_operator_cuts+=( "$(( _operator_cut * 100 ))" )
    done
  fi

  # ── Fetch registration commands ───────────────────────────────────────────
  echo -e "\n\033[1mFetching registration commands from daemons...\033[0m\n"

  local -a reg_cmds=()
  local all_ok=1

  for i in "${!node_names[@]}"; do
    local rpc_port="${node_rpc_ports[${i}]}"
    local snode_name="${node_names[${i}]}"

    local staking_req
    staking_req="$(curl -s -m 5 "http://127.0.0.1:${rpc_port}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_staking_requirement"}' \
      2>/dev/null | grep -o '"staking_requirement":[0-9]*' | cut -d: -f2 || true)"
    : "${staking_req:=200000000000000}"

    local reg_cmd
    reg_cmd="$(curl -s -m 5 "http://127.0.0.1:${rpc_port}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_service_node_registration_cmd\",\
\"params\":{\"operator_cut\":\"${node_operator_cuts[${i}]}\",\
\"contributor_addresses\":[\"${node_wallets[${i}]}\"],\
\"contributor_amounts\":[${node_contribution_atomics[${i}]}],\
\"staking_requirement\":${staking_req}}}" \
      2>/dev/null | grep -o '"registration_cmd":"[^"]*"' | cut -d'"' -f4 || true)"

    if [[ -z "${reg_cmd}" ]]; then
      reg_cmds+=( "" )
      all_ok=0
      echo -e "  \033[0;31m[FAIL]\033[0m ${snode_name}: daemon on port ${rpc_port} did not return a command"
    else
      reg_cmds+=( "${reg_cmd}" )
      echo -e "  \033[0;32m[ OK ]\033[0m ${snode_name}"
    fi
  done

  # ── Print output ──────────────────────────────────────────────────────────
  local output_file="${script_basedir}/registration_commands.txt"

  echo ""
  tput rev 2>/dev/null || true; printf "\033[1m  REGISTRATION COMMANDS  \033[0m\n"; tput sgr0 2>/dev/null || true
  echo -e "\n  Run each command in your XEQM wallet CLI with the wallet address"
  echo -e "  shown below to register the node.\n"

  local output_lines=""
  for i in "${!node_names[@]}"; do
    local line2
    if [[ -n "${reg_cmds[${i}]}" ]]; then
      line2="${reg_cmds[${i}]}"
    else
      line2="# ERROR: could not fetch registration command for ${node_names[${i}]}"
    fi
    output_lines+="# ${node_names[${i}]}\n"
    output_lines+="# Wallet: ${node_wallets[${i}]}\n"
    output_lines+="${line2}\n\n"
    printf "\n  \033[1m%s\033[0m\n" "${node_names[${i}]}"
    printf "  Wallet:  %s\n" "${node_wallets[${i}]}"
    printf "  Command: %s\n" "${line2}"
  done

  {
    printf "# XEQM Service Node Registration Commands\n"
    printf "# Generated: %s\n\n" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    printf "%b" "${output_lines}"
  } > "${output_file}"

  echo -e "  \033[1mSaved to:\033[0m ${output_file}\n"

  if [[ "${all_ok}" -eq 0 ]]; then
    echo -e "  \033[0;33mOne or more commands could not be fetched.\033[0m"
    echo -e "  Check that the affected daemon is running and fully synced, then re-run.\n"
  fi

  [[ "${XEQM_FROM_MENU:-0}" == "1" ]] && { echo ""; read -rp $'  Press Enter to return to the menu...' _; }
}

register_finally() {
  result=$?
  echo ""
  exit ${result}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap register_finally EXIT ERR INT
  register_run "$@"
fi
