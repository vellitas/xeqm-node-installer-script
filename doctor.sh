#!/usr/bin/env bash
# by Mister R

set -o errexit
set -o nounset
set -o pipefail

: "${script_basedir:=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")}"

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

eqnode_doctor_version='v1.5'
readonly eqnode_doctor_version

typeset -A doctor_config
doctor_config=(
  [fix_mode]='interactive'
)

typeset -A command_options_set
command_options_set=(
  [help]=0
  [auto_fix]=0
)


doctor_run() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Service Node Doctor" "${eqnode_doctor_version}"
  process_command_line_args "$@"

  analyze_and_fix
}

process_command_line_args() {
  parse_command_line_args "$@"
  validate_parsed_command_line_args
  set_config_and_execute_info_commands
}

parse_command_line_args() {
  args="$(getopt -a -n installer -o "hf" --long help,auto-fix -- "$@")"
  eval set -- "${args}"

  while :
  do
    case "$1" in
      -h | --help)                  command_options_set[help]=1 ; shift ;;
      -f | --auto-fix)              command_options_set[auto_fix]=1; shift ;;
      --)                           shift ; break ;;
      *)                            echo "Unexpected option: $1" ;
                                    doctor_usage
                                    exit 0 ;;
    esac
  done
}

validate_parsed_command_line_args() {
  local friendly_option_groupings group_option_count command_options_set_string unique_count valid_option_combi_found
  valid_option_combi_found=0

  friendly_option_groupings=(
    "<no_options_set>"
    "auto_fix"
    "help"
  )
  command_options_set_string="$(generate_set_options_string)"
  [[ "${command_options_set_string}" = '' ]] && command_options_set_string='<no_options_set>'

  for option_string in "${friendly_option_groupings[@]}"
  do
    group_option_count="$(echo "${option_string}" | grep -Eo '[^ ]+' | wc -l)"
    unique_count="$(echo "${option_string} ${command_options_set_string}" | grep -Eo '[^ ]+' | natsort | uniq | wc -l)"

    [[ "${unique_count}" -le "${group_option_count}" ]] && valid_option_combi_found=1 && break
  done

  if [[ "${valid_option_combi_found}" -eq 0 && "${command_options_set_string}" != '<no_options_set>' ]]; then
    echo -e "\033[0;33merror: Invalid parameter combination\033[0m\n"
    doctor_usage
    exit 1
  fi
}

set_config_and_execute_info_commands() {
  [[ "${command_options_set[help]}" -eq 1 ]] && doctor_usage && exit 0
  [[ "${command_options_set[auto_fix]}" -eq 1 ]] && auto_fix_mode_option_handler

  # necessary return 0
  return 0
}

generate_set_options_string() {
  local result=''
  for option in "${!command_options_set[@]}"
  do
    [[ "${command_options_set[$option]}" -eq 1 ]] && result+="${option} "
  done
  echo "${result}"
}

auto_fix_mode_option_handler() {
  doctor_config[fix_mode]='auto'
}

_parse_etime() {
  local et="${1:-}"
  [[ -z "${et}" ]] && echo "—" && return
  local days=0 hours=0 mins=0
  if   [[ "${et}" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    days="${BASH_REMATCH[1]}"; hours="${BASH_REMATCH[2]}"; mins="${BASH_REMATCH[3]}"
  elif [[ "${et}" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    hours="${BASH_REMATCH[1]}"; mins="${BASH_REMATCH[2]}"
  elif [[ "${et}" =~ ^([0-9]+):([0-9]+)$ ]]; then
    mins="${BASH_REMATCH[1]}"
  fi
  if   [[ "${days}"  -gt 0 ]]; then printf "%dd %dh" "${days}"  "${hours}"
  elif [[ "${hours}" -gt 0 ]]; then printf "%dh %dm" "${hours}" "${mins}"
  else printf "%dm" "${mins}"; fi
}

_fmt_ram() {
  local mb="${1:-0}"
  if   [[ "${mb}" -ge 1024 ]]; then awk "BEGIN{printf \"%.1fG\", ${mb}/1024}"
  elif [[ "${mb}" -gt 0    ]]; then echo "${mb}M"
  else echo "—"; fi
}

analyze_and_fix() {
  # ── Discover all xeqmnode_*.service units (running or stopped) ───────────
  # Using --all so stopped/failed nodes appear in the table instead of being invisible.
  local -a all_unit_names=()
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    # macOS: discover from plist files in ~/Library/LaunchAgents/
    local _plist_dir="${XEQM_SVC_DIR}"
    while IFS= read -r _pf; do
      local _label; _label="$(basename "${_pf}" .plist)"
      local _snode="${_label#${XEQM_SVC_LABEL_PREFIX}.}"
      all_unit_names+=("xeqmnode_${_snode}.service")
    done < <(find "${_plist_dir}" -maxdepth 1 -name "${XEQM_SVC_LABEL_PREFIX}.snode*.plist" 2>/dev/null | sort)
  else
    mapfile -t all_unit_names < <(
      systemctl list-units 'xeqmnode_*.service' --all --no-pager --no-legend 2>/dev/null \
      | awk '{print $1}' | natsort
    )
  fi

  if [[ "${#all_unit_names[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo XEQM service node units found on this server.\033[0m"
    exit 0
  fi

  # ── Build unified node list ────────────────────────────────────────────────
  # Layout is determined from the unit file:
  #   Canonical: User=xeqm, data in /var/lib/xeqm/snodeN, ports in ExecStart
  #   Installer: User=<snode_name>, data in /home/<user>/.xeqmlabs, ports in install.conf
  local -a node_names=() node_svcs=() node_users=() node_data_dirs=()
  local -a node_rpc_ports=() node_p2p_ports=() node_qnet_ports=() node_layouts=()

  for unit_name in "${all_unit_names[@]}"; do
    [[ -z "${unit_name}" ]] && continue
    local snode_name="${unit_name%.service}"
    snode_name="${snode_name#xeqmnode_}"

    local username layout data_dir rpc_port p2p_port qnet_port
    rpc_port=""; p2p_port=""; qnet_port=""; data_dir=""

    if [[ "${OS_TYPE}" == "Darwin" ]]; then
      # ── macOS plist layout ────────────────────────────────────────────────
      layout="canonical"
      username="${USER}"
      local plist_file="${XEQM_SVC_DIR}/${XEQM_SVC_LABEL_PREFIX}.${snode_name}.plist"
      local plist_args=""
      plist_args="$(grep -A1 '<string>--' "${plist_file}" 2>/dev/null | grep '<string>' | sed 's|.*<string>||;s|</string>||' | tr '\n' ' ' || true)"
      data_dir=$(printf '%s' "${plist_args}" | grep -o -- '--data-dir=[^ ]*' | cut -d= -f2 || true)
      rpc_port=$(printf '%s' "${plist_args}" | grep -o -- '--rpc-admin=[^ ]*' | grep -o '[0-9]*$' || true)
      p2p_port=$(printf '%s' "${plist_args}" | grep -o -- '--p2p-bind-port=[^ ]*' | cut -d= -f2 || true)
      qnet_port=$(printf '%s' "${plist_args}" | grep -o -- '--quorumnet-port=[^ ]*' | cut -d= -f2 || true)
      [[ -z "${qnet_port}" && -n "${p2p_port}" ]] && qnet_port=$(( p2p_port + 2 ))
      [[ -z "${data_dir}" ]] && data_dir="${XEQM_STATE_BASE}/${snode_name}"
    else
      local unit_file="/etc/systemd/system/${unit_name}"
      if grep -q '^User=xeqm$' "${unit_file}" 2>/dev/null; then
        # ── Canonical layout ────────────────────────────────────────────────
        layout="canonical"
        username="xeqm"
        local exec_raw
        exec_raw=$(systemctl show "${unit_name}" -p ExecStart 2>/dev/null)
        data_dir=$(echo "${exec_raw}" | grep -o -- '--data-dir=[^ ;]*' | cut -d= -f2 || true)
        rpc_port=$(echo "${exec_raw}" | grep -o -- '--rpc-admin=[^ ;]*' | grep -o '[0-9]*$' || true)
        p2p_port=$(echo "${exec_raw}" | grep -o -- '--p2p-bind-port=[^ ;]*' | cut -d= -f2 || true)
        qnet_port=$(echo "${exec_raw}" | grep -o -- '--quorumnet-port=[^ ;]*' | cut -d= -f2 || true)
        [[ -z "${qnet_port}" && -n "${p2p_port}" ]] && qnet_port=$(( p2p_port + 2 ))
        [[ -z "${data_dir}" ]] && data_dir="/var/lib/xeqm/${snode_name}"
      else
        # ── Installer layout ────────────────────────────────────────────────
        layout="installer"
        username="${snode_name}"
        data_dir="/home/${username}/.xeqmlabs"
        local inst_conf="/home/${username}/xeqm-installer/install.conf"
        p2p_port=$(grep '^p2p_bind_port='  "${inst_conf}" 2>/dev/null | cut -d= -f2 || true)
        qnet_port=$(grep '^quorumnet_port=' "${inst_conf}" 2>/dev/null | cut -d= -f2 || true)
        rpc_port=$(grep  '^rpc_bind_port='  "${inst_conf}" 2>/dev/null | cut -d= -f2 || true)
        [[ -z "${qnet_port}" && -n "${p2p_port}" ]] && qnet_port=$(( p2p_port + 2 ))
      fi
    fi

    node_names+=( "${snode_name}" )
    node_svcs+=( "${unit_name}" )
    node_users+=( "${username}" )
    node_data_dirs+=( "${data_dir}" )
    node_rpc_ports+=( "${rpc_port}" )
    node_p2p_ports+=( "${p2p_port}" )
    node_qnet_ports+=( "${qnet_port}" )
    node_layouts+=( "${layout}" )
  done

  if [[ "${#node_names[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo XEQM service node units found.\033[0m"
    exit 0
  fi

  # ── Global checks ─────────────────────────────────────────────────────────
  local ntp_ok=1
  if [[ -x "$(command -v timedatectl)" ]]; then
    [[ $(sudo timedatectl | grep -o -e 'synchronized: yes' -e 'service: active' | wc -l) -ne 2 ]] && ntp_ok=0
  fi

  # Disk: walk up from first node's data dir to find a mountpoint that exists
  local _disk_check_path="${node_data_dirs[0]:-/}"
  while [[ ! -d "${_disk_check_path}" && "${_disk_check_path}" != "/" ]]; do
    _disk_check_path="$(dirname "${_disk_check_path}")"
  done
  local free_gb
  free_gb=$(( $(df "${_disk_check_path}" | awk 'END{ print $4 }') / 1024 / 1024 ))
  local global_disk_warn=0
  [[ "${free_gb}" -lt 20 ]] && global_disk_warn=1

  # ── Network tip ───────────────────────────────────────────────────────────
  local current_block=0
  for _rpc_p in "${node_rpc_ports[@]}"; do
    [[ -z "${_rpc_p}" ]] && continue
    local _info _tgt _ht
    _info=$(curl -s -m 3 "http://127.0.0.1:${_rpc_p}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' 2>/dev/null) || true
    _tgt=$(echo "${_info}" | grep -o '"target_height":[0-9]*' | cut -d: -f2 || true)
    _ht=$(echo "${_info}"  | grep -o '"height":[0-9]*'        | cut -d: -f2 || true)
    if [[ "${_tgt:-0}" -gt "${_ht:-0}" ]]; then
      current_block="${_tgt}"
    elif [[ -n "${_ht}" && "${_ht}" =~ ^[0-9]+$ && "${_ht}" -gt 0 ]]; then
      current_block="${_ht}"
    fi
    [[ "${current_block}" -gt 0 ]] && break
  done

  local current_block_with_margin
  if [[ "${current_block}" -gt 2 ]]; then
    current_block_with_margin=$(( current_block - 2 ))
  else
    current_block_with_margin=0
  fi
  local -a healthy_blockchains=() stuck_blockchains=() nodata_blockchains=()

  # ── Collect per-node data ─────────────────────────────────────────────────
  local -a d_name=() d_svc=() d_chain_state=() d_chain_col=()
  local -a d_key=() d_fw_state=() d_disk_ok=() d_disk_gb=() d_lmdb_gb=()
  local -a d_issues=() d_reg=() d_peers=() d_uptime=() d_ram_mb=()

  local _total_nodes="${#node_names[@]}" _node_idx=0
  for i in "${!node_names[@]}"; do
    _node_idx=$(( _node_idx + 1 ))
    local _nname="${node_names[$i]}"
    local _nsvc="${node_svcs[$i]}"
    local _nuser="${node_users[$i]}"
    local _ndata="${node_data_dirs[$i]}"
    local _nrpc="${node_rpc_ports[$i]}"
    local _np2p="${node_p2p_ports[$i]}"
    local _nqnet="${node_qnet_ports[$i]}"
    local _nlayout="${node_layouts[$i]}"

    printf "\r  \033[1mChecking [ %d / %d ]\033[0m %-20s" "${_node_idx}" "${_total_nodes}" "${_nname}"

    # ─ Service ─
    local svc_state="fail"
    svc_is_active "${_nname}" 2>/dev/null && svc_state="ok"

    # ─ Uptime + RAM (via MainPID) ─
    local _mainpid=0 uptime_str="—" ram_mb=0
    _mainpid="$(svc_mainpid "${_nname}" 2>/dev/null | tr -d ' ' || echo 0)"
    if [[ "${_mainpid:-0}" -gt 0 ]]; then
      local _etime=""
      _etime=$(ps -o etime= -p "${_mainpid}" 2>/dev/null | tr -d ' ' || true)
      [[ -n "${_etime}" ]] && uptime_str="$(_parse_etime "${_etime}")"
      if [[ "${OS_TYPE}" == "Darwin" ]]; then
        ram_mb=$(ps -o rss= -p "${_mainpid}" 2>/dev/null | awk '{print int($1/1024)}' || echo 0)
      else
        ram_mb=$(awk '/VmRSS/{print int($2/1024)}' "/proc/${_mainpid}/status" 2>/dev/null || echo 0)
      fi
    fi

    # ─ Firewall ─
    local fw_state="skip" fw_issue_text=""
    if [[ -n "${_np2p}" && -n "${_nqnet}" ]]; then
      local oci_reject=0
      if sudo iptables -L INPUT -n 2>/dev/null | grep -qE "^REJECT.*all.*0\.0\.0\.0/0"; then
        oci_reject=1
        fw_issue_text+="OCI raw iptables REJECT — all inbound traffic blocked\n"
        fw_issue_text+="→ sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited\n"
      fi
      if [[ -x "$(command -v ufw)" ]] && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        local ufw_out="" fw_pass=1
        ufw_out=$(sudo ufw status 2>/dev/null)
        if ! echo "${ufw_out}" | grep -qE "^${_np2p}[/ ].*ALLOW"; then
          fw_pass=0
          fw_issue_text+="UFW: p2p ${_np2p}/tcp not open\n"
          fw_issue_text+="→ sudo ufw allow ${_np2p}/tcp\n"
        fi
        local _qnet_open=0
        if echo "${ufw_out}" | grep -qE "^${_nqnet}[[:space:]].*ALLOW"; then
          _qnet_open=1  # combined rule (no /tcp or /udp suffix) — covers both protocols
        elif echo "${ufw_out}" | grep -qE "^${_nqnet}/tcp.*ALLOW" && \
             echo "${ufw_out}" | grep -qE "^${_nqnet}/udp.*ALLOW"; then
          _qnet_open=1  # both explicit rules present
        fi
        if [[ "${_qnet_open}" -eq 0 ]]; then
          fw_pass=0
          fw_issue_text+="UFW: quorumnet ${_nqnet} (tcp+udp) not open\n"
          fw_issue_text+="→ sudo ufw allow ${_nqnet}\n"
        fi
        [[ "${fw_pass}" -eq 1 && "${oci_reject}" -eq 0 ]] && fw_state="ok" || fw_state="fail"
      else
        local p2p_listen=0
        if [[ "${OS_TYPE}" == "Darwin" ]]; then
          lsof -nP -iTCP:"${_np2p}" 2>/dev/null | grep -q LISTEN && p2p_listen=1 || true
        else
          ss -tlnp 2>/dev/null | grep -qE ":${_np2p}\b" && p2p_listen=1 || true
        fi
        if [[ "${oci_reject}" -eq 1 ]]; then
          fw_state="fail"
        elif [[ "${p2p_listen}" -eq 0 ]]; then
          # Port not open yet — check if daemon is in its initial blockchain scan
          local _scanning=0
          if [[ "${svc_state}" = "ok" && "${_mainpid:-0}" -gt 0 ]]; then
            if [[ "${OS_TYPE}" == "Darwin" ]]; then
              tail -n 100 "${XEQM_STATE_BASE}/${_nname}/xeqm-d.log" 2>/dev/null \
                | grep -q "scanning height" && _scanning=1 || true
            else
              journalctl -u "${_nsvc}" --since "3 minutes ago" --no-pager -q 2>/dev/null \
                | grep -q "scanning height" && _scanning=1 || true
            fi
          fi
          if [[ "${_scanning}" -eq 1 ]]; then
            fw_state="starting"
          else
            fw_state="fail"
            fw_issue_text+="p2p ${_np2p}/tcp not listening — check daemon config\n"
            if [[ "${OS_TYPE}" == "Darwin" ]]; then
              fw_issue_text+="→ tail -n 30 ${XEQM_STATE_BASE}/${_nname}/xeqm-d.log\n"
            else
              fw_issue_text+="→ sudo journalctl -u ${_nsvc} -n 30\n"
            fi
          fi
        else
          fw_state="ext"
        fi
      fi
    fi

    # ─ Disk ─
    local _data_df_path="${_ndata}"
    while [[ ! -d "${_data_df_path}" && "${_data_df_path}" != "/" ]]; do
      _data_df_path="$(dirname "${_data_df_path}")"
    done
    local user_disk_gb=0
    user_disk_gb=$(( $(df "${_data_df_path}" | awk 'END{ print $4 }') / 1024 / 1024 ))
    local lmdb_db_path="${_ndata}/lmdb/data.mdb"
    local lmdb_gb=0
    [[ -f "${lmdb_db_path}" ]] && \
      lmdb_gb=$(( $(_stat_size "${lmdb_db_path}") / 1024 / 1024 / 1024 ))
    local disk_node_ok=1
    [[ "${user_disk_gb}" -lt 20 ]] && disk_node_ok=0
    [[ "${lmdb_gb}" -gt 0 && "${user_disk_gb}" -lt "${lmdb_gb}" ]] && disk_node_ok=0

    # ─ SN key ─ (try RPC first; fall back to xeqm-node.sh for installer layout)
    local sn_key=""
    if [[ -n "${_nrpc}" ]]; then
      sn_key=$(curl -s -m 3 "http://127.0.0.1:${_nrpc}/json_rpc" \
        -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_service_node_key"}' 2>/dev/null \
        | grep -o '"service_node_pubkey":"[^"]*"' | cut -d'"' -f4 || true)
    fi
    if [[ -z "${sn_key}" && "${_nlayout}" = "installer" ]]; then
      sn_key="$(sudo -H -u "${_nuser}" bash -c \
        'cd ~/xeqm-installer/ && bash xeqm-node.sh print_sn_key 2>/dev/null' \
        | grep 'Public Key:' | grep -oP '(?<=: )+.*' || true)"
    fi

    # ─ Blockchain + Peers ─
    local chain_state="unknown" chain_col=""
    local blocks_done="" total_blocks="" perc=""
    local peers_in=0 peers_out=0
    local _node_info=""

    if [[ -n "${_nrpc}" ]]; then
      _node_info=$(curl -s -m 5 "http://127.0.0.1:${_nrpc}/json_rpc" \
        -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' 2>/dev/null) || true
      blocks_done=$(echo "${_node_info}" | grep -o '"height":[0-9]*'        | cut -d: -f2 || true)
      total_blocks=$(echo "${_node_info}" | grep -o '"target_height":[0-9]*' | cut -d: -f2 || true)
      peers_in=$(echo "${_node_info}"    | grep -o '"incoming_connections_count":[0-9]*' | cut -d: -f2 || echo 0)
      peers_out=$(echo "${_node_info}"   | grep -o '"outgoing_connections_count":[0-9]*' | cut -d: -f2 || echo 0)
      peers_in="${peers_in:-0}"; peers_out="${peers_out:-0}"
      if [[ -n "${blocks_done}" && -n "${total_blocks}" && "${total_blocks}" -gt 0 ]]; then
        perc=$(awk "BEGIN{printf \"%.1f\", ${blocks_done}/${total_blocks}*100}" 2>/dev/null || true)
      fi
    elif [[ "${_nlayout}" = "installer" ]]; then
      read -r blocks_done total_blocks perc <<< "$(sudo -H -u "${_nuser}" bash -c \
        'cd ~/xeqm-installer/ && bash xeqm-node.sh status 2>/dev/null' \
        | grep -o 'Height:.*' \
        | sed -n 's/^Height: \([0-9]*\)\/\([0-9]*\) (\([0-9.]*\).*/\1 \2 \3/p' || true)"
    fi

    if [[ -z "${blocks_done}" ]]; then
      local lmdb_path="${_ndata}/lmdb/data.mdb"
      if [[ -f "${lmdb_path}" ]]; then
        chain_state="syncing"
        local lmdb_mb
        lmdb_mb=$(( $(_stat_size "${lmdb_path}") / 1024 / 1024 ))
        chain_col="SYNC (${lmdb_mb}MB)"
      else
        chain_state="nodata"
        chain_col="NO DATA"
        nodata_blockchains+=("${i}")
      fi
    elif [[ "${current_block}" -eq 0 ]]; then
      # No responsive daemon could tell us the network tip — can't classify as ok
      chain_state="syncing"
      chain_col="SYNC ${blocks_done}"
    elif [[ "${blocks_done}" -lt "${current_block_with_margin}" && "${perc}" = "100.0" ]]; then
      chain_state="stuck"
      chain_col="STUCK@${blocks_done}"
      stuck_blockchains+=("${i}")
    elif [[ "${blocks_done}" -lt "${current_block_with_margin}" ]]; then
      chain_state="syncing"
      chain_col="SYNC ${blocks_done}"
    else
      chain_state="ok"
      chain_col="${blocks_done}"
      healthy_blockchains+=("${i}")
    fi

    # ─ Registration status (chain-authoritative, synced nodes only) ─
    local reg_state="—"
    if [[ "${chain_state}" = "ok" && -n "${_nrpc}" && -n "${sn_key}" ]]; then
      local _sn_chain_json
      _sn_chain_json=$(curl -s -m 5 "http://127.0.0.1:${_nrpc}/json_rpc" \
        -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_service_nodes\",\
\"params\":{\"service_node_pubkeys\":[\"${sn_key}\"]}}" 2>/dev/null) || true
      if echo "${_sn_chain_json}" | grep -q '"service_node_pubkey"'; then
        local _ulk_ht
        _ulk_ht=$(echo "${_sn_chain_json}" | grep -o '"requested_unlock_height":[0-9]*' \
          | head -1 | cut -d: -f2 || echo 0)
        if [[ "${_ulk_ht:-0}" -gt 0 ]]; then
          reg_state="unlock"
        else
          reg_state="reg'd"
        fi
      else
        reg_state="unreg"
      fi
    elif [[ "${chain_state}" = "syncing" || "${chain_state}" = "nodata" ]]; then
      reg_state="sync"
    fi

    # ─ Key display (14 hex chars) ─
    local key_col="—"
    [[ -n "${sn_key}" ]] && key_col="${sn_key:0:14}"

    # ─ Build issue text ─
    local node_issue_text=""
    local _log_hint=""
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
      _log_hint="→ tail -n 50 ${XEQM_STATE_BASE}/${_nname}/xeqm-d.log"
    else
      _log_hint="→ sudo journalctl -u ${_nsvc} -n 30"
    fi
    if [[ "${svc_state}" = "fail" ]]; then
      node_issue_text+="Service not running\n"
      if [[ "${OS_TYPE}" == "Darwin" ]]; then
        node_issue_text+="→ launchctl start $(svc_label "${_nname}")\n\n"
      else
        node_issue_text+="→ sudo systemctl start ${_nsvc}\n\n"
      fi
    fi
    if [[ -n "${fw_issue_text}" ]]; then
      node_issue_text+="${fw_issue_text}\n"
    fi
    if [[ "${disk_node_ok}" -eq 0 ]]; then
      node_issue_text+="Low disk: ${user_disk_gb} GB free, ${lmdb_gb} GB blockchain (keep 20+ GB free)\n"
      node_issue_text+="→ du -sh ${_ndata}\n\n"
    fi
    if [[ -z "${sn_key}" && "${fw_state}" != "starting" ]]; then
      node_issue_text+="SN key unavailable (daemon may be down or node not yet prepared)\n"
      if [[ "${_nlayout}" = "installer" ]]; then
        node_issue_text+="→ sudo -H -u ${_nuser} bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh prepare_sn'\n\n"
      else
        node_issue_text+="${_log_hint}\n\n"
      fi
    fi
    local _total_peers=$(( peers_in + peers_out ))
    if [[ "${svc_state}" = "ok" && "${_total_peers}" -eq 0 && "${fw_state}" != "starting" ]]; then
      node_issue_text+="No peers — daemon is isolated from the network\n"
      node_issue_text+="${_log_hint}\n\n"
    elif [[ "${svc_state}" = "ok" && "${_total_peers}" -lt 3 && "${fw_state}" != "starting" ]]; then
      node_issue_text+="# Low peer count (${_total_peers}) — monitor for network isolation\n\n"
    fi
    if [[ "${chain_state}" = "stuck" ]]; then
      node_issue_text+="Blockchain stuck at ${blocks_done} (network tip: ${current_block}) — see auto-fix below\n"
      if [[ "${OS_TYPE}" == "Darwin" ]]; then
        node_issue_text+="→ launchctl stop $(svc_label "${_nname}") && sleep 2 && launchctl start $(svc_label "${_nname}")\n\n"
      else
        node_issue_text+="→ sudo systemctl stop ${_nsvc} && sleep 2 && sudo systemctl start ${_nsvc}\n\n"
      fi
    elif [[ "${chain_state}" = "nodata" ]]; then
      node_issue_text+="No blockchain data — daemon not responding\n"
      if [[ "${OS_TYPE}" == "Darwin" ]]; then
        node_issue_text+="→ tail -n 50 ${XEQM_STATE_BASE}/${_nname}/xeqm-d.log\n\n"
      else
        node_issue_text+="→ sudo journalctl -u ${_nsvc} -n 50\n\n"
      fi
    fi

    d_name+=( "${_nname}" )
    d_svc+=( "${svc_state}" )
    d_chain_state+=( "${chain_state}" )
    d_chain_col+=( "${chain_col}" )
    d_key+=( "${key_col}" )
    d_fw_state+=( "${fw_state}" )
    d_disk_ok+=( "${disk_node_ok}" )
    d_disk_gb+=( "${user_disk_gb}" )
    d_lmdb_gb+=( "${lmdb_gb}" )
    d_issues+=( "${node_issue_text}" )
    d_reg+=( "${reg_state}" )
    d_peers+=( "${peers_in}/${peers_out}" )
    d_uptime+=( "${uptime_str}" )
    d_ram_mb+=( "${ram_mb}" )
  done
  printf "\r%-70s\r" ""

  # ── Summary header ────────────────────────────────────────────────────────
  echo ""
  local _ntp_str _disk_str _tip_str
  if [[ "${ntp_ok}" -eq 1 ]]; then
    _ntp_str="\033[0;32mNTP: ok\033[0m"
  else
    _ntp_str="\033[0;31mNTP: not synchronized\033[0m"
  fi
  if [[ "${global_disk_warn}" -eq 0 ]]; then
    _disk_str="\033[0;32mdisk: ${free_gb} GB free\033[0m"
  else
    _disk_str="\033[0;33mdisk: ${free_gb} GB free\033[0m"
  fi
  if [[ "${current_block}" -gt 0 ]]; then
    _tip_str="network tip: block ${current_block}"
  else
    _tip_str="\033[0;33mnetwork tip: unavailable\033[0m"
  fi
  echo -e "  ${_ntp_str}   ${_disk_str}   ${_tip_str}"
  echo ""

  # ── Summary table ─────────────────────────────────────────────────────────
  local W_NAME=15 W_SVC=4 W_CHAIN=12 W_PEERS=6 W_UP=8 W_RAM=6 W_REG=6 W_FW=4 W_KEY=14
  printf "  %-${W_NAME}s  %-${W_SVC}s  %-${W_CHAIN}s  %-${W_PEERS}s  %-${W_UP}s  %-${W_RAM}s  %-${W_REG}s  %-${W_FW}s  %s\n" \
    "Node" "Svc" "Chain" "Peers" "Uptime" "RAM" "Reg" "FW" "SN Key"
  printf "  %s  %s  %s  %s  %s  %s  %s  %s  %s\n" \
    "$(printf '%*s' ${W_NAME}  '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_SVC}   '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_CHAIN} '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_PEERS} '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_UP}    '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_RAM}   '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_REG}   '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_FW}    '' | tr ' ' '-')" \
    "$(printf '%*s' ${W_KEY}   '' | tr ' ' '-')"

  for i in "${!d_name[@]}"; do
    local _svc_txt _chain_txt _fw_txt _peers_txt _up_txt _ram_txt _reg_txt

    _svc_txt="$(printf "%-${W_SVC}s" "${d_svc[$i]^^}")"
    case "${d_svc[$i]}" in
      ok)   _svc_txt="\033[0;32m${_svc_txt}\033[0m" ;;
      *)    _svc_txt="\033[0;31m${_svc_txt}\033[0m" ;;
    esac

    _chain_txt="$(printf "%-${W_CHAIN}s" "${d_chain_col[$i]}")"
    case "${d_chain_state[$i]}" in
      ok)      _chain_txt="\033[0;32m${_chain_txt}\033[0m" ;;
      syncing) _chain_txt="\033[0;33m${_chain_txt}\033[0m" ;;
      stuck)   _chain_txt="\033[0;31m${_chain_txt}\033[0m" ;;
      nodata)  _chain_txt="\033[0;31m${_chain_txt}\033[0m" ;;
    esac

    # Peers
    local _p_raw="${d_peers[$i]:-0/0}"
    local _p_in="${_p_raw%%/*}" _p_out="${_p_raw##*/}"
    _p_in="${_p_in:-0}"; _p_out="${_p_out:-0}"
    local _p_total=$(( _p_in + _p_out ))
    _peers_txt="$(printf "%-${W_PEERS}s" "${_p_raw}")"
    if [[ "${d_svc[$i]}" != "ok" ]]; then
      _peers_txt="$(printf "%-${W_PEERS}s" "—")"
    elif [[ "${_p_total}" -eq 0 ]]; then
      _peers_txt="\033[0;31m${_peers_txt}\033[0m"
    elif [[ "${_p_total}" -lt 3 ]]; then
      _peers_txt="\033[0;33m${_peers_txt}\033[0m"
    else
      _peers_txt="\033[0;32m${_peers_txt}\033[0m"
    fi

    # Uptime + RAM (dim when service is down)
    if [[ "${d_svc[$i]}" != "ok" ]]; then
      _up_txt="$(printf "%-${W_UP}s" "—")"
      _ram_txt="$(printf "%-${W_RAM}s" "—")"
    else
      _up_txt="$(printf "%-${W_UP}s" "${d_uptime[$i]}")"
      local _rf; _rf="$(_fmt_ram "${d_ram_mb[$i]}")"
      _ram_txt="$(printf "%-${W_RAM}s" "${_rf}")"
    fi

    # Reg
    _reg_txt="$(printf "%-${W_REG}s" "${d_reg[$i]}")"
    case "${d_reg[$i]}" in
      "reg'd")  _reg_txt="\033[0;32m${_reg_txt}\033[0m" ;;
      "unreg")  _reg_txt="\033[0;33m${_reg_txt}\033[0m" ;;
      "unlock") _reg_txt="\033[0;33m${_reg_txt}\033[0m" ;;
      "sync")   _reg_txt="\033[0;90m${_reg_txt}\033[0m" ;;
    esac

    local _fw_label
    case "${d_fw_state[$i]}" in
      starting) _fw_label="SCAN" ;;
      *)        _fw_label="${d_fw_state[$i]^^}" ;;
    esac
    _fw_txt="$(printf "%-${W_FW}s" "${_fw_label}")"
    case "${d_fw_state[$i]}" in
      ok)       _fw_txt="\033[0;32m${_fw_txt}\033[0m" ;;
      fail)     _fw_txt="\033[0;31m${_fw_txt}\033[0m" ;;
      ext)      _fw_txt="\033[0;33m${_fw_txt}\033[0m" ;;
      skip)     _fw_txt="\033[0;33m${_fw_txt}\033[0m" ;;
      starting) _fw_txt="\033[0;90m${_fw_txt}\033[0m" ;;
    esac

    local _name_txt
    _name_txt="$(printf "%-${W_NAME}s" "${d_name[$i]}")"
    [[ -n "${d_issues[$i]}" ]] && _name_txt="\033[0;31m${_name_txt}\033[0m"

    printf "  %b  %b  %b  %b  %b  %b  %b  %b  %s\n" \
      "${_name_txt}" "${_svc_txt}" "${_chain_txt}" \
      "${_peers_txt}" "${_up_txt}" "${_ram_txt}" \
      "${_reg_txt}" "${_fw_txt}" "${d_key[$i]}"
  done

  # EXT footnote
  local _has_ext=0
  for i in "${!d_name[@]}"; do [[ "${d_fw_state[$i]}" = "ext" ]] && { _has_ext=1; break; }; done
  if [[ "${_has_ext}" -eq 1 ]]; then
    echo -e "  \033[0;33mEXT\033[0m = daemon listening; ports not managed by UFW — verify access in your external firewall (OPNSense, cloud security group, etc.)"
    echo ""
  fi

  # ── Ready to register callout ─────────────────────────────────────────────
  local -a _rtr_nodes=()
  for i in "${!d_name[@]}"; do
    [[ "${d_reg[$i]}" = "unreg" && "${d_chain_state[$i]}" = "ok" && \
       "${d_svc[$i]}" = "ok" ]] && _rtr_nodes+=( "${d_name[$i]}" )
  done
  if [[ "${#_rtr_nodes[@]}" -gt 0 ]]; then
    echo ""
    tput rev 2>/dev/null || true; printf "\033[1m  READY TO REGISTER (%d node(s))  \033[0m\n" "${#_rtr_nodes[@]}"; tput sgr0 2>/dev/null || true
    echo ""
    echo -e "  The following node(s) are fully synced and not yet registered:"
    for _rn in "${_rtr_nodes[@]}"; do
      echo -e "    \033[0;32m●\033[0m ${_rn}"
    done
    echo -e "\n  Run register.sh or select Register from the menu:"
    echo -e "  \033[0;36m→ sudo bash ${script_basedir}/register.sh\033[0m"
    echo ""
  fi

  # ── Issues & remediation ──────────────────────────────────────────────────
  local _any_issue=0
  for i in "${!d_name[@]}"; do [[ -n "${d_issues[$i]}" ]] && { _any_issue=1; break; }; done
  [[ "${ntp_ok}" -eq 0 || "${global_disk_warn}" -eq 1 ]] && _any_issue=1

  if [[ "${_any_issue}" -eq 1 ]]; then
    echo ""
    tput rev 2>/dev/null || true; printf "\033[1m  ISSUES & REMEDIATION  \033[0m\n"; tput sgr0 2>/dev/null || true
    echo ""

    if [[ "${ntp_ok}" -eq 0 ]]; then
      echo -e "  \033[0;31m[!]\033[0m NTP not synchronized — clock drift can cause deregistration"
      echo -e "      \033[0;36m→ sudo timedatectl set-ntp true\033[0m"
      echo ""
    fi

    if [[ "${global_disk_warn}" -eq 1 ]]; then
      echo -e "  \033[0;33m[!]\033[0m disk low: ${free_gb} GB free (recommended: 50+ GB)"
      echo ""
    fi

    for i in "${!d_name[@]}"; do
      [[ -z "${d_issues[$i]}" ]] && continue
      printf "  \033[1m%s\033[0m\n" "${d_name[$i]}"
      while IFS= read -r _line; do
        if [[ -z "${_line}" ]]; then
          echo ""
        elif [[ "${_line}" =~ ^→ ]]; then
          printf "      \033[0;36m%s\033[0m\n" "${_line}"
        elif [[ "${_line}" =~ ^# ]]; then
          printf "      \033[0;33m%s\033[0m\n" "${_line}"
        else
          printf "    \033[0;31m[!]\033[0m %s\n" "${_line}"
        fi
      done < <(printf '%b' "${d_issues[$i]}")
    done
  else
    echo -e "\n\033[1;32mAll nodes healthy.\033[0m"
  fi

  # ── Auto-fix: stuck daemons — offer restart ───────────────────────────────
  if [[ "${#stuck_blockchains[@]}" -gt 0 ]]; then
    echo ""
    tput rev 2>/dev/null || true
    printf "\033[1m  STUCK DAEMON(S) — AUTO-FIX  \033[0m\n"
    tput sgr0 2>/dev/null || true
    local _do_restart=1
    if wt_available; then
      local _stuck_list=""
      for _si in "${stuck_blockchains[@]}"; do _stuck_list+="${node_names[$_si]} "; done
      wt_yesno "Stuck Daemons Detected" \
        "These daemons are synced but not advancing:\n\n  ${_stuck_list}\nA restart often resolves this without touching blockchain data.\nRestart now?" \
        12 66 "Restart Now" "Skip" || _do_restart=0
    else
      echo ""
      echo -e "  Stuck daemons (synced but height not advancing):"
      for _si in "${stuck_blockchains[@]}"; do echo -e "    • ${node_names[$_si]}"; done
      local _yn
      read -rp $'\n\033[1mRestart stuck daemons now?\e[0m [Y/n]: ' _yn
      _yn="${_yn:-Y}"
      [[ "${_yn,,}" != "y" ]] && _do_restart=0
    fi
    if [[ "${_do_restart}" -eq 1 ]]; then
      echo ""
      for _si in "${stuck_blockchains[@]}"; do
        printf "  Restarting %s...\n" "${node_names[$_si]}"
        svc_stop "${node_names[$_si]}" 2>/dev/null || true
        sleep 2
        svc_start "${node_names[$_si]}"
        echo -e "  \033[0;32mRestarted\033[0m — re-run doctor in a few minutes to confirm"
      done
    fi
  fi

  # ── Auto-fix: missing/corrupt blockchain ─────────────────────────────────
  if [[ "${#nodata_blockchains[@]}" -gt 0 && "${#healthy_blockchains[@]}" -gt 0 ]]; then
    local _do_fix=1
    if [[ "${doctor_config[fix_mode]}" = "interactive" ]]; then
      if wt_available; then
        wt_yesno "Auto-Fix Blockchain" \
          "Missing/corrupt blockchain detected.\n\nReplace from a healthy donor node on this server?" \
          10 62 "Fix now" "Skip" || _do_fix=0
      else
        while true; do
          read -rp $'\n\033[1mMissing/corrupt blockchain found. Auto-fix from healthy donor?\e[0m [Y/N]: ' yn
          yn="${yn:-N}"
          case "${yn}" in
            [Yy]*) break ;;
            [Nn]*) _do_fix=0; break ;;
            *) echo "(Please answer Y or N)" ;;
          esac
        done
      fi
    fi
    if [[ "${_do_fix}" -eq 1 ]]; then
      local donor_idx="${healthy_blockchains[0]}"
      local donor_name="${node_names[${donor_idx}]}"
      local donor_data="${node_data_dirs[${donor_idx}]}"
      for bad_idx in "${nodata_blockchains[@]}"; do
        local bad_name="${node_names[${bad_idx}]}"
        local bad_data="${node_data_dirs[${bad_idx}]}"
        local bad_svc="${node_svcs[${bad_idx}]}"
        local bad_user="${node_users[${bad_idx}]}"
        local bad_layout="${node_layouts[${bad_idx}]}"
        echo -e "\n\033[1mFixing blockchain for '${bad_name}'...\033[0m"
        if [[ "${bad_layout}" = "installer" ]]; then
          sudo -H -u "${bad_user}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop'
        else
          svc_stop "${bad_name}" 2>/dev/null || true
        fi
        echo -e "  Copying lmdb from donor '${donor_name}'... (may take a few minutes)"
        ${_SUDO} rm -Rf "${bad_data}/lmdb"
        ${_SUDO} cp -R "${donor_data}/lmdb" "${bad_data}"
        [[ "${OS_TYPE}" != "Darwin" ]] && ${_SUDO} chown -R "${bad_user}:${bad_user}" "${bad_data}"
        if [[ "${bad_layout}" = "installer" ]]; then
          sudo -H -u "${bad_user}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'
        else
          svc_start "${bad_name}"
        fi
        echo -e "  \033[0;32mDone.\033[0m"
      done
    fi

  elif [[ "${#nodata_blockchains[@]}" -gt 0 ]]; then
    local _fix_choice=2
    if wt_available; then
      local _wt_fc=""
      wt_menu "No Blockchain Data — Fix Options" \
        "No healthy donor on this server. Choose a fix:" \
        12 70 2 _wt_fc \
        "bootstrap" "Download from bootstrap.xeqmlabs.com (~15 min)" \
        "skip"      "Skip — fix manually later" || true
      [[ "${_wt_fc}" = "bootstrap" ]] && _fix_choice=1
    else
      echo -e "\n\033[0;33mNo blockchain data — no healthy donor available.\033[0m"
      prompt_menu "How would you like to fix?" _fix_choice 1 \
        "Download bootstrap from bootstrap.xeqmlabs.com (~15 min)" \
        "Skip — fix manually later"
    fi
    if [[ "${_fix_choice}" -eq 1 ]]; then
      for bad_idx in "${nodata_blockchains[@]}"; do
        local bad_name="${node_names[${bad_idx}]}"
        local bad_data="${node_data_dirs[${bad_idx}]}"
        local bad_svc="${node_svcs[${bad_idx}]}"
        local bad_user="${node_users[${bad_idx}]}"
        local bad_layout="${node_layouts[${bad_idx}]}"
        echo -e "\n\033[1mFixing '${bad_name}' via bootstrap...\033[0m"
        if [[ "${bad_layout}" = "installer" ]]; then
          sudo -H -u "${bad_user}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop' 2>/dev/null || true
        else
          svc_stop "${bad_name}" 2>/dev/null || true
        fi
        download_bootstrap "${bad_data}" "${bad_user}"
        if [[ "${bad_layout}" = "installer" ]]; then
          sudo -H -u "${bad_user}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'
        else
          svc_start "${bad_name}"
        fi
        echo -e "  \033[0;32mDone.\033[0m"
      done
    else
      echo -e "\nSkipped. See issues above for manual steps."
    fi
  fi

  if [[ "${XEQM_FROM_MENU:-0}" = "1" ]]; then
    echo ""
    read -rp $'  Press Enter to return to the menu...' _
  fi
}
doctor_usage() {
  cat <<USAGEMSG

bash $0 [OPTIONS...]

Options:
  -f --auto-fix                         Scans for "corrupted" blockchains of active service
                                        nodes and will attempt to fix it without user interaction

  -h  --help                            Show this help text

USAGEMSG
}

doctor_finally() {
  result=$?
  echo ""
  exit ${result}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap doctor_finally EXIT ERR INT
  doctor_run "${@}"
fi

