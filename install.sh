#!/usr/bin/env bash
# by Mister R

set -euo pipefail

# When piped via `curl | bash`, BASH_SOURCE[0] is unset — clone the repo to the
# canonical location and re-exec from there so the sourced helpers are available.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "bash" || "${BASH_SOURCE[0]}" == "-bash" ]]; then
  _INSTALL_DIR="/opt/xeqm-node-installer-script"
  if [[ ! -d "${_INSTALL_DIR}/.git" ]]; then
    git clone --depth=1 https://github.com/vellitas/xeqm-node-installer-script.git "${_INSTALL_DIR}" >/dev/null 2>&1
  else
    git -C "${_INSTALL_DIR}" pull --ff-only >/dev/null 2>&1
  fi
  exec bash "${_INSTALL_DIR}/install.sh" "$@"
fi

: "${script_basedir:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

typeset -A command_options_set
command_options_set=(
  [help]=0
  [copy_blockchain]=0
  [copy_binaries]=0
  [inspect_auto_magic]=0
  [nodes]=0
  [ports]=0
  [version]=0
  [daemon_no_fluffy_blocks]=0
  [daemon_log_level]=0
  [git_repository]=0
  [open_firewall]=0
  [quiet]=0
  [force]=0
)
copy_binaries_option_value=
copy_blockchain_option_value=
nodes_option_value=
ports_option_value=
version_option_value=
daemon_log_level_option_value=
git_repository_option_value=

declare -A system_info

detect_and_migrate_installer_nodes() {
  # Old installer layout only existed on Linux — skip entirely on macOS
  [[ "${OS_TYPE}" == "Darwin" ]] && return 0

  # Scan for installer-layout nodes: OS users whose home is /home/snodeN and whose
  # unit file has User=snodeN (not User=xeqm).
  local -a _installer_nodes=()
  local _u
  while IFS= read -r _u; do
    [[ -z "${_u}" ]] && continue
    local _unit="/etc/systemd/system/xeqmnode_${_u}.service"
    if [[ -f "${_unit}" ]] && ! grep -q '^User=xeqm$' "${_unit}" 2>/dev/null; then
      _installer_nodes+=("${_u}")
    fi
  done < <(getent passwd | awk -F: '$6 ~ /^\/home\/snode/ { print $1 }' | sort)

  [[ "${#_installer_nodes[@]}" -eq 0 ]] && return 0

  local _count="${#_installer_nodes[@]}"
  local _do_migrate=0
  if [[ "${config[quiet_mode]:-0}" -eq 1 ]]; then
    _do_migrate=1
  elif wt_available; then
    if wt_yesno "Migrate to Canonical Layout" \
      "Found ${_count} installer-layout node(s):\n  ${_installer_nodes[*]}\n\nMigrate them to canonical layout now?\nThis should be done before installing new nodes." \
      12 68 "Migrate" "Skip"; then
      _do_migrate=1
    fi
  else
    echo -e "\n\033[1;33mFound ${_count} installer-layout node(s) on this server:\033[0m"
    for _n in "${_installer_nodes[@]}"; do echo -e "  - ${_n}"; done
    echo -e "\n  These nodes use the old per-user layout and should be migrated to canonical layout before adding new nodes."
    local _yn
    read -rp $'\n\033[1mMigrate now?\e[0m [Y/n]: ' _yn
    _yn="${_yn:-Y}"
    [[ "${_yn,,}" = y* ]] && _do_migrate=1
  fi

  if [[ "${_do_migrate}" -eq 1 ]]; then
    wt_available && whiptail --infobox "Migrating installer-layout nodes to canonical layout..." 5 60
    bash "${script_basedir}/to_canonical.sh" --all
  fi
}

install_run() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Service Node Installer" "${xeqmnode_installer_version}"

  local _start_slot
  _start_slot="$(next_snode_slot)"
  if [[ "${XEQM_FROM_MENU:-0}" != "1" ]]; then
    if [[ "${_start_slot}" -eq 1 ]]; then
      echo -e "\n  No existing service nodes found — fresh install."
    else
      local _last=$(( _start_slot - 1 ))
      echo -e "\n  Existing: \033[1msnode1..snode${_last}\033[0m"
      echo -e "  Next node will be: \033[1;36msnode${_start_slot}\033[0m"
    fi
  fi

  detect_and_migrate_installer_nodes

  discover_system system_info
  process_command_line_args "$@"

  pre_install_checks
  pre_install_summary
  [[ "${config[wizard_confirmed]:-0}" -eq 1 ]] && clear
  install_manager
}

process_command_line_args() {
  parse_command_line_args "$@"
  validate_parsed_command_line_args
  set_config_and_execute_info_commands
}

parse_command_line_args() {
  args="$(getopt -a -n installer -o "hib:c:n:p:qv:" --long help,inspect-auto-magic,copy-binaries:,copy-blockchain:,nodes:,ports:,quiet,version:,set-daemon-log-level:,set-daemon-no-fluffy-blocks,git-repository:,open-firewall,force -- "$@")"
  eval set -- "${args}"

  while :
  do
    case "$1" in
      -h | --help)                    command_options_set[help]=1 ; shift ;;
      -b | --copy-binaries)           command_options_set[copy_binaries]=1; copy_binaries_option_value="$2"; shift 2 ;;
      -c | --copy-blockchain)         command_options_set[copy_blockchain]=1; copy_blockchain_option_value="$2"; shift 2 ;;
      -i | --inspect-auto-magic)      command_options_set[inspect_auto_magic]=1; shift ;;
      -n | --nodes)                   command_options_set[nodes]=1; nodes_option_value="$2"; shift 2 ;;
      -p | --ports)                   command_options_set[ports]=1; ports_option_value="$2"; shift 2 ;;
      -q | --quiet)                   command_options_set[quiet]=1; shift ;;
      -v | --version)                 command_options_set[version]=1; version_option_value="$2"; shift 2 ;;
      --set-daemon-no-fluffy-blocks)  command_options_set[daemon_no_fluffy_blocks]=1; shift ;;
      --set-daemon-log-level)         command_options_set[daemon_log_level]=1; daemon_log_level_option_value="$2"; shift 2 ;;
      --git-repository)               command_options_set[git_repository]=1; git_repository_option_value="$2"; shift 2 ;;
      --open-firewall)                command_options_set[open_firewall]=1; shift ;;
      --force)                        command_options_set[force]=1; shift ;;
      --)                             shift ; break ;;
      *)                              echo "Unexpected option: $1" ;
                                      install_usage
                                      exit 0 ;;
    esac
  done
}

set_config_and_execute_info_commands() {
  [[ "${command_options_set[help]}" -eq 1 ]] && install_usage && exit 0

  if [[ "${command_options_set[force]}" -eq 1 ]]; then config[force_install]=1; fi
  if [[ "${command_options_set[quiet]}" -eq 1 ]]; then config[quiet_mode]=1; fi

  local _wz_any=0
  for _wz_f in nodes ports copy_blockchain copy_binaries version open_firewall inspect_auto_magic; do
    [[ "${command_options_set[${_wz_f}]:-0}" -eq 1 ]] && _wz_any=1 && break
  done
  if [[ "${config[quiet_mode]:-0}" -eq 0 && "${_wz_any}" -eq 0 ]] && wt_available; then
    run_wizard
    return 0
  fi

  if [[ "${command_options_set[nodes]}" -eq 1 ]]; then
    nodes_option_handler "${nodes_option_value}"
  elif [[ "${command_options_set[quiet]}" -eq 1 ]]; then
    nodes_option_handler 1
  else
    prompt_nodes_count
  fi

  [[ "${command_options_set[inspect_auto_magic]}" -eq 1 ]] && inspect_auto_magic_option_handler && exit 0

  if [[ "${command_options_set[daemon_no_fluffy_blocks]}" -eq 1 ]]; then config[daemon_no_fluffy_blocks]=1; fi

  if [[ "${command_options_set[version]}" -eq 1 ]]; then version_option_handler "${version_option_value}"; else version_option_handler "auto"; fi
  if [[ "${command_options_set[ports]}" -eq 1 ]]; then ports_option_handler "${ports_option_value}"; else ports_option_handler "auto"; fi
  if [[ "${command_options_set[copy_blockchain]}" -eq 1 ]]; then
    copy_blockchain_option_handler "${copy_blockchain_option_value}"
  elif [[ "${config[quiet_mode]}" -eq 1 ]]; then
    copy_blockchain_option_handler "bootstrap"
  else
    blockchain_selection_menu
  fi
  if [[ "${command_options_set[copy_binaries]}" -eq 1 ]]; then
    config[binary_source]="${copy_binaries_option_value}"
  elif [[ "${config[quiet_mode]}" -eq 1 ]]; then
    config[binary_source]="download"
  else
    prompt_binary_source
  fi
  if [[ "${command_options_set[daemon_log_level]}" -eq 1 ]]; then daemon_log_level_option_handler "${daemon_log_level_option_value}"; fi
  if [[ "${command_options_set[git_repository]}" -eq 1 ]]; then git_repository_option_handler "${git_repository_option_value}"; fi
  if [[ "${config[quiet_mode]}" -eq 1 ]]; then
    config[service_node_public_ip]="$(detect_public_ip)"
  else
    prompt_service_node_public_ip
  fi

  if [[ "${command_options_set[open_firewall]}" -eq 1 ]]; then
    config[open_firewall]=1
    config[firewall_mode]='ufw'
  elif [[ "${config[quiet_mode]}" -eq 0 ]]; then
    prompt_firewall_mode
  fi

  return 0
}

validate_parsed_command_line_args() {
  local valid_option_combinations=(
    "<no_options_set>"
    "copy_blockchain copy_binaries nodes ports version daemon_no_fluffy_blocks daemon_log_level git_repository open_firewall quiet force"
    "inspect_auto_magic nodes"
    "help"
  )
  validate_command_line_option_combinations valid_option_combinations
}

# Canonical-layout capacity formula:
#   RAM: 600 MB/node (peak quorum load, not idle RSS), 1.5 GB system reserve
#   Disk: 1.5 GB/node, 5 GB system reserve
#   CPU: 1 GHz-core per node — cores × MHz/1000 — penalises slow clocks (e.g. N3450@1.1GHz=4)
_calculate_max_nodes() {
  local _total_ram_mb=$(( system_info[memory] / 1024 ))
  local _free_disk_mb=$(( system_info[free_space_var_lib] / 1024 ))
  local _ncpu; _ncpu="$(nproc 2>/dev/null || echo 1)"

  # Read current CPU MHz; fall back to 2000 if unavailable (e.g. macOS)
  local _cpu_mhz=2000
  local _raw_mhz
  _raw_mhz="$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | awk '{printf "%d", $4}' || true)"
  [[ "${_raw_mhz}" =~ ^[0-9]+$ && "${_raw_mhz}" -gt 0 ]] && _cpu_mhz="${_raw_mhz}"
  local _ghz_cores=$(( _ncpu * _cpu_mhz / 1000 ))
  [[ "${_ghz_cores}" -lt 1 ]] && _ghz_cores=1

  _max_by_ram=$(( (_total_ram_mb - 1536) / 600 ))
  _max_by_disk=$(( (_free_disk_mb - 5120) / 1536 ))
  _max_by_cpu="${_ghz_cores}"

  [[ "${_max_by_ram}"  -lt 1 ]] && _max_by_ram=1
  [[ "${_max_by_disk}" -lt 1 ]] && _max_by_disk=1

  _max_nodes="${_max_by_ram}"
  _limit_reason="RAM"
  if [[ "${_max_by_disk}" -lt "${_max_nodes}" ]]; then
    _max_nodes="${_max_by_disk}"
    _limit_reason="disk space"
  fi
  if [[ "${_max_by_cpu}" -lt "${_max_nodes}" ]]; then
    _max_nodes="${_max_by_cpu}"
    _limit_reason="CPU (${_ncpu} cores × ${_cpu_mhz} MHz)"
  fi
}

prompt_nodes_count() {
  _calculate_max_nodes
  local count max_nodes="${_max_nodes}" limit_reason="${_limit_reason}"

  echo -e "\n  This server can support up to \033[1m${max_nodes}\033[0m node(s) based on available ${limit_reason}."
  echo -e "  (RAM: ${_max_by_ram}  |  Disk: ${_max_by_disk}  |  CPU: ${_max_by_cpu} — limited by ${limit_reason})"
  echo -e "  \033[0;33mThis is a hardware estimate. Actual capacity depends on workload.\033[0m"

  while true; do
    read -rp $'\n\033[1mHow many service nodes would you like to install?\e[0m [1]: ' count
    count="${count:-1}"
    if ! [[ "${count}" =~ ^[0-9]+$ && "${count}" -ge 1 ]]; then
      echo -e "  \033[0;33mPlease enter a number between 1 and ${max_nodes}.\033[0m"
      continue
    fi
    if [[ "${count}" -gt "${max_nodes}" && "${config[force_install]:-0}" -ne 1 ]]; then
      echo -e "  \033[0;33mThis server can support a maximum of ${max_nodes} node(s) (limited by ${limit_reason})."
      echo -e "  Please enter a number between 1 and ${max_nodes}.\033[0m"
      continue
    fi
    nodes_option_handler "${count}"
    return 0
  done
}

nodes_option_handler() {
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo -e "\033[0;33merror: Invalid --nodes option value. Numbers only.\033[0m\n"
    install_usage
    exit 1
  fi

  _calculate_max_nodes
  local max_nodes="${_max_nodes}"

  if [[ "$1" -gt "${max_nodes}" && "${config[force_install]:-0}" -ne 1 ]]; then
    echo -e "\033[0;33merror: Too many nodes set as --nodes option value. Max nodes: ${max_nodes}. Check system specifications (memory/disk space).\033[0m\n"
    exit 1
  fi
  config[nodes]="$1"

  local idx=1
  while [ "${idx}" -le "${config[nodes]}" ]; do
    config["snode${idx}__copy_blockchain"]=
    config["snode${idx}__copy_binaries"]=
    config["snode${idx}__p2p_bind_port"]=0
    config["snode${idx}__rpc_bind_port"]=0
    config["snode${idx}__quorumnet_port"]=0
    config["snode${idx}__oxenmq_port"]=0
    idx=$((idx + 1))
  done

  return 0
}

copy_binaries_option_handler() {
  local binaries_version
  local idx=1
  local option_value="$1"

  if [[ -f "${option_value}/xeqm-d" ]]; then
      binaries_version="$("${option_value}"/xeqm-d --version | grep -oP '(?<=\()+v[0-9.]+')"

      if [[ "${command_options_set[version]}" -eq 1 && "${config[install_version]}" != "${binaries_version}" ]]; then
        echo -e "\n\033[0;33merror: ${option_value}/xeqm-d version '${binaries_version}' does not match version '${config[install_version]}'\033[0m\n"
        exit 1
      fi

      while [ "${idx}" -le "${config[nodes]}" ]; do
        config["snode${idx}__copy_binaries"]="${option_value}"
        idx=$((idx + 1))
      done
  else
    echo -e "\n\033[0;33merror: xeqm-d not found in --copy-binaries directory '$1'\033[0m\n"
    exit 1
  fi
}

prompt_binary_source() {
  local existing_bins=""
  find_existing_binaries_on_server existing_bins

  local _compile_label="Compile from source  (slowest, ~1 hour)"
  [[ "${OS_TYPE}" == "Darwin" ]] && _compile_label="Compile from source  (requires Xcode + Homebrew, ~1 hour)"

  local pm__choice
  if [[ -n "${existing_bins}" ]]; then
    prompt_menu "How would you like to get the XEQM node binaries?" pm__choice 1 \
      "Download pre-built binaries from GitHub  (fastest)" \
      "Use existing binaries already on this server  (${existing_bins})" \
      "${_compile_label}"
    case "${pm__choice}" in
      1) config[binary_source]="download" ;;
      2) config[binary_source]="${existing_bins}" ;;
      3) config[binary_source]="compile" ;;
    esac
  else
    prompt_menu "How would you like to get the XEQM node binaries?" pm__choice 1 \
      "Download pre-built binaries from GitHub  (fastest)" \
      "${_compile_label}"
    case "${pm__choice}" in
      1) config[binary_source]="download" ;;
      2) config[binary_source]="compile" ;;
    esac
  fi
}

blockchain_selection_menu() {
  local choice
  prompt_menu "How should this node get its blockchain?" choice 1 \
    "Download bootstrap  (fastest, ~15 min  —  https://bootstrap.xeqmlabs.com)" \
    "Copy from an existing active node on this server  (auto-detect)" \
    "Sync from the network  (slowest, may take many hours)"

  case "${choice}" in
    1) copy_blockchain_option_handler "bootstrap" ;;
    2) copy_blockchain_option_handler "auto" ;;
    3) copy_blockchain_option_handler "no" ;;
  esac
}

copy_blockchain_option_handler() {
  local blockchain
  local idx=1
  local option_value="$1"

  if [[ "${option_value}" = "bootstrap" ]]; then
    # First node bootstraps; subsequent nodes copy from it once it's fully indexed.
    # By the time node 2 is installed, node 1 has completed its scan and its
    # sqlite.db/ons.db are ready — so subsequent nodes skip the full rescan.
    config["snode1__copy_blockchain"]="bootstrap"
    idx=2
    while [ "${idx}" -le "${config[nodes]}" ]; do
      config["snode${idx}__copy_blockchain"]="copy_from_snode1"
      idx=$((idx + 1))
    done
    echo -e "\n\033[1mBlockchain: node 1 downloads bootstrap; remaining nodes copy from node 1\033[0m"
    return 0
  fi

  if [[ "${option_value}" = "auto" ]]; then
    blockchain="$(discover_biggest_blockchain)"
    if [[ -d "${blockchain}" ]]; then option_value="${blockchain}"; else option_value="no,auto"; fi
  fi

  if [[ "${option_value}" = "no" || -f "${option_value}/lmdb/data.mdb" ]]; then
      while [ "${idx}" -le "${config[nodes]}" ]; do
        config["snode${idx}__copy_blockchain"]="${option_value}"
        idx=$((idx + 1))
      done
  elif [[ "${option_value}" = "no,auto" ]]; then
      # node 1 syncs from network; subsequent nodes copy from node 1's data_dir at runtime
      while [ "${idx}" -le "${config[nodes]}" ]; do
        if [[ "${idx}" -eq 1 ]]; then
            config["snode${idx}__copy_blockchain"]="no"
        else
            config["snode${idx}__copy_blockchain"]="copy_from_snode1"
        fi
        idx=$((idx + 1))
      done
  else
    echo -e "\n\033[0;33merror: invalid --copy-blockchain value or directory '$1'\033[0m\n"
    install_usage
    exit 1
  fi

  idx=1
  echo -e "\n\033[1mBlockchain copy settings...\033[0m"
  while [ "${idx}" -le "${config[nodes]}" ]; do
    [[ "${config[nodes]}" -gt 1 ]] && echo -e "\nService Node ${idx}:"
    echo -e "  Copy blockchain: ${config["snode${idx}__copy_blockchain"]}"
    idx=$((idx + 1))
  done
}

auto_ports_option_handler() {
  echo -e "\n\033[1mAuto-detecting available ports...\033[0m"
  declare -A discovered_sets
  discover_free_port_sets discovered_sets "${config[nodes]}"

  local idx=1
  while [ "${idx}" -le "${config[nodes]}" ]; do
    config["snode${idx}__p2p_bind_port"]="${discovered_sets["set${idx}__p2p_bind_port"]}"
    config["snode${idx}__rpc_bind_port"]="${discovered_sets["set${idx}__rpc_bind_port"]}"
    config["snode${idx}__quorumnet_port"]="${discovered_sets["set${idx}__quorumnet_port"]}"
    config["snode${idx}__oxenmq_port"]="${discovered_sets["set${idx}__oxenmq_port"]}"

    [[ "${config[nodes]}" -gt 1 ]] && echo -e "\nService Node ${idx}:"
    echo -e "  p2p_bind_port  -> ${config["snode${idx}__p2p_bind_port"]}"
    echo -e "  rpc_bind_port  -> ${config["snode${idx}__rpc_bind_port"]}"
    echo -e "  quorumnet_port -> ${config["snode${idx}__quorumnet_port"]}"
    echo -e "  oxenmq_port    -> ${config["snode${idx}__oxenmq_port"]}"

    idx=$((idx + 1))
  done
}

inspect_auto_magic_option_handler() {
  version_option_handler "auto"
  ports_option_handler "auto"
  copy_blockchain_option_handler "auto"

  echo -e "\nIf needed you can alter these settings manually by one of the following example commands (or combination):\n\033[0;33m"
  echo -e "    bash install.sh --version ${config[install_version]}"
  echo -e "    bash install.sh --ports p2p:9330,rpc:9331"
  echo -e "    bash install.sh --copy-blockchain no\033[0m\n"
}

ports_option_handler() {
  if [[ "$1" = "auto" ]]; then
    auto_ports_option_handler
  elif valid_manual_port_string_format "$1" ; then
    parse_manual_port_string_and_set_config_if_valid "$1"
  else
    echo -e "\033[0;33merror: Invalid --ports config format '$1'\033[0m\n"
    install_usage
    exit 1
  fi
}

valid_manual_port_string_format() {
  local _n="${config[nodes]}" _p2p_count _rpc_count _uniq_count
  local _p2p_part _rpc_part
  # Basic structure check (POSIX ERE — compatible with BSD and GNU grep)
  echo "$1" | grep -qE "^(p2p:[0-9+]+,rpc:[0-9+]+|rpc:[0-9+]+,p2p:[0-9+]+)$" || return 1
  # Extract the numeric portion only (strips "p2p:"/"rpc:" prefix to avoid the '2' in 'p2p')
  _p2p_part="$(echo "$1" | grep -oE 'p2p:[0-9+]+' | cut -d: -f2)"
  _rpc_part="$(echo "$1"  | grep -oE 'rpc:[0-9+]+' | cut -d: -f2)"
  # Count ports by counting '+' separators and adding 1
  _p2p_count=$(( $(printf '%s' "${_p2p_part}" | tr -cd '+' | wc -c | tr -d ' ') + 1 ))
  _rpc_count=$(( $(printf '%s' "${_rpc_part}"  | tr -cd '+' | wc -c | tr -d ' ') + 1 ))
  # Uniqueness check: expand both port lists and count distinct values
  _uniq_count="$(printf '%s\n%s' "${_p2p_part}" "${_rpc_part}" | tr '+' '\n' | sort -u | grep -c '[0-9]' || true)"
  [[ "${_p2p_count}" -eq "${_n}" && "${_rpc_count}" -eq "${_n}" && "${_uniq_count}" -eq "$(( _n * 2 ))" ]]
}

parse_manual_port_string_and_set_config_if_valid() {
  typeset -A key_to_config_param
  key_to_config_param=(
    [p2p]='p2p_bind_port'
    [rpc]='rpc_bind_port'
  )
  local params validation_result port_error port_key port_values port_value_string single_port_value

  read -a params <<< "${1//,/ }"
  port_error=0

  echo -e "\n\033[1mAnalyzing manual port configuration...\033[0m"

  for key_value in "${params[@]}"
  do
    local idx=1
    read -r port_key port_value_string <<< "${key_value//:/ }"
    read -a port_values <<< "${port_value_string//+/ }"

    for single_port_value in "${port_values[@]}"
    do
      validation_result="$(validate_port "${single_port_value}")"

      case "${validation_result}" in
        'outside_port_range') printf "%s: %d -> \033[0;33mOut of range [allowed between 5000-49151]\033[0m\n" "${key_to_config_param[${port_key}]}" "${single_port_value}"
                              port_error=1 ;;

        'port_used')          printf "%s: %d -> \033[0;33mIn use\033[0m\n" "${key_to_config_param[${port_key}]}" "${single_port_value}"
                              port_error=1 ;;

        'free_port')          printf "%s: %d -> OK\n" "${key_to_config_param[${port_key}]}" "${single_port_value}"
                              config["snode${idx}__${key_to_config_param[${port_key}]}"]="${single_port_value}" ;;

        *)                    echo "Unknown port validation result" ; exit 1 ;;
      esac
      idx=$((idx + 1))
    done
  done
  if [[ "${port_error}" -eq 1 ]]; then
    exit 1
  fi

  local qidx=1
  while [ "${qidx}" -le "${config[nodes]}" ]; do
    local _qnet=$(( config["snode${qidx}__p2p_bind_port"] + 2 ))
    local _omq=$(( config["snode${qidx}__p2p_bind_port"] + 3 ))
    local _qnet_result _omq_result
    _qnet_result="$(validate_port "${_qnet}")"
    _omq_result="$(validate_port "${_omq}")"
    if [[ "${_qnet_result}" = "port_used" ]]; then
      printf "snode%d quorumnet: %d -> \033[0;33mIn use\033[0m (derived from p2p+2)\n" "${qidx}" "${_qnet}"
      port_error=1
    elif [[ "${_qnet_result}" = "outside_port_range" ]]; then
      printf "snode%d quorumnet: %d -> \033[0;33mOut of range\033[0m\n" "${qidx}" "${_qnet}"
      port_error=1
    fi
    if [[ "${_omq_result}" = "port_used" ]]; then
      printf "snode%d oxenmq:    %d -> \033[0;33mIn use\033[0m (derived from p2p+3)\n" "${qidx}" "${_omq}"
      port_error=1
    elif [[ "${_omq_result}" = "outside_port_range" ]]; then
      printf "snode%d oxenmq:    %d -> \033[0;33mOut of range\033[0m\n" "${qidx}" "${_omq}"
      port_error=1
    fi
    config["snode${qidx}__quorumnet_port"]="${_qnet}"
    config["snode${qidx}__oxenmq_port"]="${_omq}"
    qidx=$((qidx + 1))
  done
  if [[ "${port_error}" -eq 1 ]]; then
    exit 1
  fi
}

print_step() {
  local current="$1"
  local total="$2"
  local label="$3"
  echo -e "\n  \033[1;36m[ ${current} / ${total} ]\033[0m \033[1m${label}\033[0m"
}

pre_install_summary() {
  # Wizard already showed a summary and got confirmation — skip the text version
  if [[ "${config[quiet_mode]:-0}" -eq 1 || "${config[wizard_confirmed]:-0}" -eq 1 ]]; then
    return 0
  fi

  local inner="Installation Summary"
  local box_w=54
  local pad_l=$(( (box_w - ${#inner}) / 2 ))
  local pad_r=$(( box_w - ${#inner} - pad_l ))
  local border; border="$(printf '═%.0s' $(seq 1 ${box_w}))"
  echo ""
  echo -e "\033[1;36m  ╔${border}╗\033[0m"
  printf "\033[1;36m  ║\033[0m%*s\033[1m%s\033[0m%*s\033[1;36m║\033[0m\n" "${pad_l}" "" "${inner}" "${pad_r}" ""
  echo -e "\033[1;36m  ╚${border}╝\033[0m"
  echo ""

  local _start_slot
  _start_slot="$(next_snode_slot)"

  printf "  %-24s %s\n" "Nodes:"         "${config[nodes]}"
  printf "  %-24s %s\n" "Binary version:" "${config[install_version]}"

  local bin_src="${config[binary_source]}"
  [[ "${bin_src}" = "download" ]] && bin_src="Download from GitHub"
  [[ "${bin_src}" = "compile" ]]  && bin_src="Compile from source"
  printf "  %-24s %s\n" "Binary source:" "${bin_src}"

  local bc="${config["snode1__copy_blockchain"]}"
  [[ "${bc}" = "bootstrap" ]]        && bc="Bootstrap (bootstrap.xeqmlabs.com)"
  [[ "${bc}" = "no" ]]               && bc="Sync from network"
  [[ "${bc}" = "copy_from_snode1" ]] && bc="Copy from snode1 (first syncs, rest copy)"
  printf "  %-24s %s\n" "Blockchain:" "${bc}"

  local fw="${config[firewall_mode]:-none}"
  case "${fw}" in
    ufw)      fw="UFW (auto-configure)" ;;
    iptables) fw="iptables (auto-configure)" ;;
    oci)      fw="Oracle Cloud (UFW + REJECT fix)" ;;
    external) fw="External firewall (manual)" ;;
    none)     fw="None (manual)" ;;
  esac
  printf "  %-24s %s\n" "Firewall:" "${fw}"
  printf "  %-24s %s\n" "Public IP:" "${config[service_node_public_ip]:-auto-detect}"
  echo ""

  local idx=1
  while [ "${idx}" -le "${config[nodes]}" ]; do
    local _slot=$(( _start_slot + idx - 1 ))
    printf "  Node %-3s  snode=%-12s  p2p=%-6s  rpc=%-6s  quorumnet=%s\n" \
      "${idx}:" "snode${_slot}" \
      "${config["snode${idx}__p2p_bind_port"]}" \
      "${config["snode${idx}__rpc_bind_port"]}" \
      "${config["snode${idx}__quorumnet_port"]}"
    idx=$((idx + 1))
  done
  echo ""

  local yn
  while true; do
    read -rp $'\033[1mProceed with installation?\e[0m [Y/n]: ' yn
    yn="${yn:-Y}"
    case "${yn}" in
      [Yy]*) return 0 ;;
      [Nn]*) echo -e "\nInstallation cancelled."; exit 0 ;;
      *) echo -e "  (Please answer Y or N)" ;;
    esac
  done
}

install_manager() {
  declare -A node_config
  local idx=1
  local start_slot
  start_slot="$(next_snode_slot)"
  local snode1_data_dir=

  ensure_xeqm_user

  print_step 1 3 "Installing XEQM binary to ${XEQM_BIN_DIR}/"
  install_binary_to_opt

  while [ "${idx}" -le "${config[nodes]}" ]; do
    local snode_name="snode$(( start_slot + idx - 1 ))"
    local data_dir="${XEQM_STATE_BASE}/${snode_name}"
    generate_node_config node_config "${idx}" "${snode_name}" "${data_dir}"

    tput rev 2>/dev/null || true; echo -e "\n\033[1m  Service Node ${idx} of ${config[nodes]} — ${snode_name}  \033[0m"; tput sgr0 2>/dev/null || true

    print_step 2 4 "Creating data directory ${data_dir}"
    ${_SUDO} mkdir -p "${data_dir}"
    if [[ "${OS_TYPE}" != "Darwin" ]]; then
      ${_SUDO} chown xeqm:xeqm "${data_dir}"
    fi
    ${_SUDO} chmod 0700 "${data_dir}"

    print_step 3 4 "Setting up blockchain data"
    local bc_val="${node_config[copy_blockchain]}"
    if [[ "${bc_val}" = "copy_from_snode1" ]]; then
      if [[ -n "${snode1_data_dir}" && -d "${snode1_data_dir}" ]]; then
        bc_val="${snode1_data_dir}"
      else
        echo -e "  \033[0;33mWarning: snode1 data dir not ready — falling back to network sync\033[0m"
        bc_val="no"
      fi
    fi
    copy_blockchain_to_data_dir "${data_dir}" "${bc_val}"
    [[ "${idx}" -eq 1 ]] && snode1_data_dir="${data_dir}"

    print_step 4 4 "Writing service unit and starting service"
    write_canonical_unit \
      "${snode_name}" \
      "${node_config[p2p_bind_port]}" \
      "${node_config[rpc_bind_port]}" \
      "${node_config[quorumnet_port]}" \
      "${config[service_node_public_ip]}" \
      "${config[daemon_log_level]:-}"

    svc_reload_daemon
    clear_port_if_stale "${node_config[p2p_bind_port]}"
    svc_enable "${snode_name}"
    svc_start "${snode_name}"

    if [[ "${config[quiet_mode]:-0}" -eq 0 ]]; then
      watch_daemon_status "${node_config[rpc_bind_port]}" "xeqmnode_${snode_name}"
    fi

    if [[ "${config[open_firewall]:-0}" -eq 1 ]]; then
      open_firewall_for_node "${node_config[p2p_bind_port]}" "${node_config[quorumnet_port]}"
    fi

    echo -e "\n  \033[1;32m[DONE]\033[0m Service Node ${idx} (${snode_name}) installed."
    idx=$((idx + 1))
  done
  install_agent
  next_steps
}

generate_node_config() {
  local -n gnc__node_config_ref="$1"
  local node_id="$2"
  local snode_name="$3"
  local data_dir="$4"
  gnc__node_config_ref=(
    [node_id]="${node_id}"
    [snode_name]="${snode_name}"
    [data_dir]="${data_dir}"
    [unit_name]="xeqmnode_${snode_name}"
    [install_version]="${config[install_version]}"
    [git_repository]="${config[git_repository]}"
    [p2p_bind_port]="${config["snode${node_id}__p2p_bind_port"]}"
    [rpc_bind_port]="${config["snode${node_id}__rpc_bind_port"]}"
    [quorumnet_port]="${config["snode${node_id}__quorumnet_port"]}"
    [oxenmq_port]="${config["snode${node_id}__oxenmq_port"]}"
    [copy_blockchain]="${config["snode${node_id}__copy_blockchain"]}"
    [copy_binaries]="${config["snode${node_id}__copy_binaries"]:-}"
    [binary_source]="${config[binary_source]}"
    [daemon_no_fluffy_blocks]="${config[daemon_no_fluffy_blocks]}"
    [daemon_log_level]="${config[daemon_log_level]}"
    [service_node_public_ip]="${config[service_node_public_ip]}"
    [open_firewall]="${config[open_firewall]}"
    [firewall_mode]="${config[firewall_mode]:-}"
  )
}

# Find a local snode data dir that has a fully-indexed sqlite.db, excluding $1
_find_indexed_snode() {
  local exclude_dir="$1"
  local _mdb _candidate
  while IFS= read -r _mdb; do
    _candidate="$(dirname "$(dirname "${_mdb}")")"
    # Only use snode* directories — skip seed, pubnode, etc.
    [[ "$(basename "${_candidate}")" != snode* ]] && continue
    if [[ -f "${_candidate}/sqlite.db" && "${_candidate}" != "${exclude_dir}" ]]; then
      echo "${_candidate}"
      return 0
    fi
  done < <(find "${XEQM_STATE_BASE}" -maxdepth 3 -name 'data.mdb' 2>/dev/null | sort)
}

# Copy lmdb + sqlite.db + ons.db from $1 into $2 (excludes keys, sockets, logs)
_copy_chain_state() {
  local src="$1" dst="$2"
  if [[ -d "${dst}/lmdb" ]]; then
    ${_SUDO} mv "${dst}/lmdb" "${dst}/lmdb_$(printf '%08x' $RANDOM)"
  fi
  [[ -d "${src}/lmdb" ]] && ${_SUDO} cp -R "${src}/lmdb" "${dst}/" || true
  for _db in sqlite.db ons.db; do
    for _sfx in "" "-shm" "-wal"; do
      if [[ -f "${src}/${_db}${_sfx}" ]]; then
        ${_SUDO} cp "${src}/${_db}${_sfx}" "${dst}/${_db}${_sfx}"
      fi
    done
  done
  [[ "${OS_TYPE}" != "Darwin" ]] && ${_SUDO} chown -R xeqm:xeqm "${dst}" || true
}

copy_blockchain_to_data_dir() {
  local data_dir="$1"
  local blockchain_value="$2"

  if [[ "${blockchain_value}" = "bootstrap" ]]; then
    # If any local node already has sqlite.db (fully indexed), copy from it —
    # avoids the 6-min rescan on every node across re-runs of the installer.
    local _local_src
    _local_src="$(_find_indexed_snode "${data_dir}")"
    if [[ -n "${_local_src}" ]]; then
      echo -e "\n\033[1mCopying blockchain + chain state from existing node '${_local_src}'...\033[0m"
      _copy_chain_state "${_local_src}" "${data_dir}"
      return 0
    fi
    download_bootstrap "${data_dir}" "xeqm"
    return 0
  fi

  if [[ "${blockchain_value}" = "no" ]]; then
    echo -e "\n  Blockchain: will sync from network."
    return 0
  fi

  if [[ -d "${blockchain_value}" ]]; then
    echo -e "\n\033[1mCopying blockchain + chain state from '${blockchain_value}'...\033[0m"
    _copy_chain_state "${blockchain_value}" "${data_dir}"
  fi
}

open_firewall_for_node() {
  local p2p_port="$1"
  local fw_quorumnet_port="$2"
  local public_ports=("${p2p_port}" "${fw_quorumnet_port}")

  local firewall_mode
  if [[ "${config[firewall_mode]:-}" = "ufw" ]]; then
    firewall_mode='ufw'
  elif [[ "${config[firewall_mode]:-}" = "iptables" ]]; then
    firewall_mode='iptables'
  elif [[ "${config[firewall_mode]:-}" = "oci" ]]; then
    firewall_mode='oci'
  elif [[ -x "$(command -v ufw)" ]] && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    firewall_mode='ufw'
  else
    firewall_mode='iptables'
  fi

  if [[ "${firewall_mode}" = 'iptables' ]]; then
    echo -e "\n\033[1mOpening firewall ports [iptables]: ${public_ports[*]}...\033[0m"
    check_iptables_dependencies

    for port in "${public_ports[@]}"; do
      sudo iptables -A INPUT -p tcp --dport "${port}" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
      sudo iptables -A OUTPUT -p tcp --sport "${port}" -m conntrack --ctstate ESTABLISHED -j ACCEPT
    done
    sudo iptables -A INPUT -p udp --dport "${fw_quorumnet_port}" -j ACCEPT
    sudo iptables -A OUTPUT -p udp --sport "${fw_quorumnet_port}" -j ACCEPT
    sudo iptables-save | uniq | sudo tee /etc/iptables/rules.v4 | sudo iptables-restore
    sudo ip6tables-save | uniq | sudo tee /etc/iptables/rules.v6 | sudo ip6tables-restore

  elif [[ "${firewall_mode}" = 'ufw' || "${firewall_mode}" = 'oci' ]]; then
    if ! [[ -x "$(command -v ufw)" ]]; then
      echo -e "\n\033[1mInstalling ufw...\033[0m"
      sudo apt-get -y install ufw
    fi
    echo -e "\n\033[1mOpening firewall ports [ufw]: ${public_ports[*]}...\033[0m"
    sudo ufw allow ssh
    sudo ufw allow "${p2p_port}/tcp"
    sudo ufw allow "${fw_quorumnet_port}"
    sudo ufw --force enable
    if [[ "${firewall_mode}" = 'oci' ]]; then
      echo -e "\n\033[1mOracle Cloud: removing raw iptables REJECT rule...\033[0m"
      sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
      sudo ip6tables -D INPUT -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
      sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null 2>/dev/null || true
    fi
  fi
}

check_iptables_dependencies() {
    if ! [[ -x "$(command -v iptables)" && -x "$(command -v iptables-save)" ]]; then
      echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
      echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

      sudo apt-get -y install iptables iptables-persistent

      sudo iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
      sudo iptables -A OUTPUT -p tcp --sport 22 -m conntrack --ctstate ESTABLISHED -j ACCEPT
      sudo iptables-save | uniq | sudo tee /etc/iptables/rules.v4 | sudo iptables-restore
      sudo ip6tables-save | uniq | sudo tee /etc/iptables/rules.v6 | sudo ip6tables-restore
    fi
}

watch_daemon_status() {
  local rpc_port="$1"
  local svc_name="$2"
  local rpc_url="http://127.0.0.1:${rpc_port}/get_info"
  local last_height=0 stall_count=0 max_stall=18
  local spin_chars='|/-\' spin_i=0
  local start_time; start_time="$(date +%s)"
  _watch_elapsed() { local s=$(( $(date +%s) - $1 )); printf "%dm%02ds" $(( s/60 )) $(( s%60 )); }

  local _status="Daemon initializing..." _detail=""
  local info="" height="" target_height=""
  local _synced_checks=0  # consecutive checks where target_height=0 and height stable
  local _init_stall=0    # consecutive RPC-silent ticks; bail after 180 (30 min)
  local _max_init_stall=180

  # Extract snode name (xeqmnode_snodeN → snodeN)
  local _snode_name="${svc_name#xeqmnode_}"

  # Capture service activation time once for journal queries (Linux only)
  local _svc_since=""
  if [[ "${OS_TYPE}" != "Darwin" ]]; then
    _svc_since="$(sudo systemctl show "${svc_name}" -p ActiveEnterTimestamp --value \
      2>/dev/null | sed 's/ [A-Z]*$//' || true)"
  fi

  echo -e "\n\033[1mMonitoring blockchain sync progress:\033[0m"

  # Wait up to 90s for the service unit to be active — spinner updates every second
  local deadline=$(( $(date +%s) + 90 ))
  while [[ $(date +%s) -lt ${deadline} ]]; do
    svc_is_active "${_snode_name}" 2>/dev/null && break
    spin_i=$(( spin_i + 1 ))
    printf "\r  %s  Starting daemon...  (%s elapsed)%-20s" \
      "${spin_chars:$(( spin_i % 4 )):1}" "$(_watch_elapsed "${start_time}")" ""
    sleep 1
  done
  printf "\r%-78s\r" ""

  # Spinner ticks every 1s; RPC check every 10s
  local _rpc_tick=10
  while true; do
    spin_i=$(( spin_i + 1 ))
    printf "\r  %s  %s%s  (%s elapsed)%-20s" \
      "${spin_chars:$(( spin_i % 4 )):1}" "${_status}" "${_detail}" \
      "$(_watch_elapsed "${start_time}")" ""

    _rpc_tick=$(( _rpc_tick + 1 ))
    if [[ ${_rpc_tick} -ge 10 ]]; then
      _rpc_tick=0

      # Search all logs since service started for the sync completion marker
      local _log_output=""
      if [[ "${OS_TYPE}" == "Darwin" ]]; then
        _log_output="$(tail -n 2000 "${XEQM_STATE_BASE}/${_snode_name}/xeqm-d.log" 2>/dev/null || true)"
      else
        local _journal_args=(--no-pager)
        [[ -n "${_svc_since}" ]] && _journal_args+=(--since "${_svc_since}") || _journal_args+=(-n 2000)
        _log_output="$(sudo journalctl -u "${svc_name}" "${_journal_args[@]}" 2>/dev/null || true)"
      fi
      if printf '%s' "${_log_output}" | grep -q "You are now synchronized with the network"; then
        printf "\r  \033[1;32m✓ Blockchain synchronized\033[0m  (%s elapsed)%-40s\n" \
          "$(_watch_elapsed "${start_time}")" ""
        break
      fi

      info="$(curl -s --connect-timeout 3 "${rpc_url}" 2>/dev/null)" || true
      height="$(printf '%s' "${info}" | grep -o '"height":[0-9]*' | head -1 | cut -d: -f2)" || true
      target_height="$(printf '%s' "${info}" | grep -o '"target_height":[0-9]*' | head -1 | cut -d: -f2)" || true

      if [[ "${target_height}" =~ ^[0-9]+$ && "${target_height}" -gt "${height:-0}" \
            && "${target_height}" -gt 1000 ]]; then
        # Syncing: more than 1000 blocks behind
        _synced_checks=0
        local perc_int perc_dec
        perc_int=$(( ${height:-0} * 100 / target_height ))
        perc_dec=$(( (${height:-0} * 1000 / target_height) % 10 ))
        _status="Syncing"
        _detail="  ${perc_int}.${perc_dec}%  —  ${height:-0} / ${target_height} blocks"

        if [[ "${height:-0}" -ge "${target_height}" ]]; then
          printf "\r  \033[1;32m✓ Blockchain synchronized\033[0m  (%s elapsed)%-40s\n" \
            "$(_watch_elapsed "${start_time}")" ""
          break
        fi
        if [[ "${height:-0}" -eq "${last_height}" ]]; then
          stall_count=$(( stall_count + 1 ))
          if [[ "${stall_count}" -ge "${max_stall}" ]]; then
            printf "\r  \033[1;33mNo new blocks for 3 min — assuming synced\033[0m%-30s\n" ""
            break
          fi
        else
          stall_count=0; last_height="${height:-0}"
        fi
      elif [[ "${height}" =~ ^[0-9]+$ && "${height}" -gt 0 ]]; then
        # RPC responding with a height and target_height=0 (or < 1000 blocks behind).
        # target_height=0 is how xeqm-d signals "I am at tip". Require 6 consecutive
        # stable checks (60s) to avoid declaring synced before peers are found — a
        # fresh daemon with no peers reports target_height=0 at whatever height the
        # LMDB loaded to, which may be far below the actual network tip.
        if [[ "${height}" -eq "${last_height}" ]]; then
          _synced_checks=$(( _synced_checks + 1 ))
        else
          _synced_checks=0
          last_height="${height}"
        fi
        if [[ "${_synced_checks}" -ge 6 ]]; then
          printf "\r  \033[1;32m✓ Blockchain synchronized\033[0m  (height=%d, %s elapsed)%-20s\n" \
            "${height}" "$(_watch_elapsed "${start_time}")" ""
          break
        fi
        _status="Waiting for peer confirmation"
        _detail="  (height=${height})"
      else
        # RPC not yet up — first check if the service is in a hard-failure state
        _synced_checks=0
        if [[ "${OS_TYPE}" != "Darwin" ]]; then
          local _svc_result
          _svc_result="$(sudo systemctl show "${svc_name}" -p Result --value 2>/dev/null || true)"
          if [[ "${_svc_result}" = "core-dump" || "${_svc_result}" = "exit-code" || "${_svc_result}" = "signal" ]]; then
            local _svc_exit
            _svc_exit="$(sudo systemctl show "${svc_name}" -p ExecMainStatus --value 2>/dev/null || true)"
            printf "\r  \033[0;31m✗ Service crashed (Result=%s, exit=%s) — installation cannot continue.\033[0m%-10s\n" \
              "${_svc_result}" "${_svc_exit:-?}" ""
            printf "  \033[0;33m  sudo journalctl -u %s -n 30 --no-pager\033[0m\n" "${svc_name}"
            return 1
          fi
        fi
        # Check journal for internal blockchain scan progress
        local _scan_line _sc _st
        local _scan_src
        if [[ "${OS_TYPE}" == "Darwin" ]]; then
          _scan_src="$(tail -n 50 "${XEQM_STATE_BASE}/${_snode_name}/xeqm-d.log" 2>/dev/null || true)"
        else
          _scan_src="$(sudo journalctl -u "${svc_name}" --no-pager -n 50 2>/dev/null || true)"
        fi
        _scan_line="$(printf '%s' "${_scan_src}" | grep 'scanning height' | tail -1 || true)"
        if [[ -n "${_scan_line}" ]]; then
          _sc="$(printf '%s' "${_scan_line}" | sed 's/.*scanning height \([0-9]*\)\/.*/\1/')"
          _st="$(printf '%s' "${_scan_line}" | sed 's/.*scanning height [0-9]*\/\([0-9]*\).*/\1/')"
          if [[ "${_st}" =~ ^[0-9]+$ && "${_st}" -gt 0 ]]; then
            local _sp=$(( ${_sc:-0} * 100 / _st ))
            _status="Indexing chain data"
            _detail="  ${_sp}%  (${_sc:-0} / ${_st} blocks scanned)"
            _init_stall=0
          else
            _status="Daemon initializing..."
            _detail=""
            _init_stall=$(( _init_stall + 1 ))
          fi
        else
          _status="Daemon initializing..."
          _detail=""
          _init_stall=$(( _init_stall + 1 ))
        fi
        if [[ "${_init_stall}" -ge "${_max_init_stall}" ]]; then
          printf "\r  \033[1;33mDaemon did not initialize after 30 min — check logs, continuing install.\033[0m%-10s\n" ""
          printf "  \033[0;33m  journalctl -u %s -n 50 --no-pager\033[0m\n" "${svc_name}"
          break
        fi
      fi
    fi

    sleep 1
  done
}

install_agent() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    if [[ -f "${HOME}/Library/LaunchAgents/com.xeqmlabs.agent.plist" ]]; then
      echo -e "\n  XEQM agent already installed — skipping."
      return 0
    fi
  else
    if systemctl is-enabled --quiet xeqm-agent.timer 2>/dev/null; then
      echo -e "\n  XEQM agent already installed and enabled — skipping."
      return 0
    fi
  fi

  local _dashboard_url="${config[agent_url]:-}"
  local _agent_token="${config[agent_token]:-}"

  if [[ -z "${_dashboard_url}" || -z "${_agent_token}" ]]; then
    if [[ "${config[quiet_mode]:-0}" -eq 1 ]]; then
      echo -e "  Agent installation skipped (set agent_url and agent_token for non-interactive install)."
      return 0
    fi
    echo -e "\n"
    tput rev 2>/dev/null || true; printf "\033[1m  XEQM Operator Dashboard Agent  \033[0m\n"; tput sgr0 2>/dev/null || true
    echo -e "\n  The agent reports this server's metrics and node status to your operator"
    echo -e "  dashboard, enabling remote monitoring and one-click node management."

    local _do_install=0
    if wt_available; then
      wt_yesno "Install Dashboard Agent?" \
        "Install the XEQM Operator Dashboard Agent?\n\nThis enables your operator dashboard to monitor\nand manage nodes on this server." \
        12 62 "Install Agent" "Skip"
      [[ $? -eq 0 ]] && _do_install=1
    else
      local _yn
      read -rp $'\n\033[1mInstall the XEQM Operator Dashboard Agent?\e[0m [Y/n]: ' _yn
      [[ "${_yn:-Y}" =~ ^[Yy] ]] && _do_install=1
    fi

    if [[ "${_do_install}" -eq 0 ]]; then
      echo -e "  Agent installation skipped."
      return 0
    fi

    if wt_available; then
      wt_inputbox "Dashboard URL" \
        "Base URL of your operator dashboard.\n\nExamples:\n  https://dashboard.example.com\n  http://192.168.1.100:8080" \
        13 66 _dashboard_url ""
      [[ $? -ne 0 || -z "${_dashboard_url}" ]] && { echo -e "  Agent installation skipped."; return 0; }
      wt_inputbox "Agent Token" \
        "Authentication token for this server.\n\nFind it in your dashboard:\n  Settings → Agents → Add Agent" \
        11 66 _agent_token ""
      [[ $? -ne 0 || -z "${_agent_token}" ]] && { echo -e "  Agent installation skipped."; return 0; }
    else
      while [[ -z "${_dashboard_url}" ]]; do
        read -rp $'\n\033[1mDashboard URL\e[0m (e.g. https://dashboard.example.com): ' _dashboard_url
      done
      while [[ -z "${_agent_token}" ]]; do
        read -rp $'\033[1mAgent token\e[0m (from dashboard Settings → Agents): ' _agent_token
      done
    fi
  fi

  echo -e "\n\033[1mInstalling XEQM Operator Dashboard Agent...\033[0m"

  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    local _mac_agent_dir="${HOME}/xeqm-agent"
    local _mac_plist="${HOME}/Library/LaunchAgents/com.xeqmlabs.agent.plist"

    if ! python3 -c "import psutil" 2>/dev/null; then
      echo -e "  Installing psutil..."
      pip3 install --quiet psutil
    fi

    mkdir -p "${_mac_agent_dir}"

    local _agent_installed=0
    if [[ -n "${_dashboard_url}" ]]; then
      echo -e "  Fetching agent from dashboard..."
      if curl -fsSL --max-time 15 \
          -o "${_mac_agent_dir}/xeqm_agent.py" \
          "${_dashboard_url}/agent.py" 2>/dev/null; then
        _agent_installed=1
        echo -e "  Fetched: ${_dashboard_url}/agent.py"
      else
        echo -e "  \033[0;33m[WARN]\033[0m Could not reach dashboard — using bundled agent"
      fi
    fi
    if [[ "${_agent_installed}" -eq 0 ]]; then
      cp "${script_basedir}/xeqm_agent.py" "${_mac_agent_dir}/xeqm_agent.py"
      echo -e "  Installed: bundled xeqm_agent.py"
    fi
    chmod 755 "${_mac_agent_dir}/xeqm_agent.py"

    cat > "${_mac_agent_dir}/xeqm-agent.conf" <<AGENTCONF
[agent]
url   = ${_dashboard_url}
token = ${_agent_token}
AGENTCONF
    chmod 600 "${_mac_agent_dir}/xeqm-agent.conf"
    echo -e "  Wrote: ${_mac_agent_dir}/xeqm-agent.conf"

    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "${_mac_plist}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.xeqmlabs.agent</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/python3</string>
		<string>${_mac_agent_dir}/xeqm_agent.py</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${_mac_agent_dir}/xeqm-agent.log</string>
	<key>StandardErrorPath</key>
	<string>${_mac_agent_dir}/xeqm-agent.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
	</dict>
</dict>
</plist>
PLISTEOF

    launchctl load "${_mac_plist}"
    echo -e "  Loaded: com.xeqmlabs.agent (reporting every 60s)"

    echo -e "\n  \033[1;32m[DONE]\033[0m Agent installed and reporting to ${_dashboard_url}"
    config[agent_installed]=1
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    sudo apt -y install python3
  fi
  if ! python3 -c "import psutil" 2>/dev/null; then
    sudo apt -y install python3-psutil
  fi

  if ! id -u xeqm-agent >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin \
      --comment "XEQM Dashboard Agent" xeqm-agent
    echo -e "  Created system user: xeqm-agent"
  fi
  if ! id -nG xeqm-agent 2>/dev/null | grep -qw systemd-journal; then
    sudo usermod -aG systemd-journal xeqm-agent
    echo -e "  Added xeqm-agent to systemd-journal group (enables log monitoring)"
  fi

  sudo mkdir -p /opt/xeqm-agent

  local _agent_installed=0
  if [[ -n "${_dashboard_url}" ]]; then
    echo -e "  Fetching agent from dashboard..."
    if sudo wget -q --timeout=15 -O /opt/xeqm-agent/xeqm_agent.py "${_dashboard_url}/agent.py" 2>/dev/null; then
      _agent_installed=1
      echo -e "  Fetched: ${_dashboard_url}/agent.py"
    else
      echo -e "  \033[0;33m[WARN]\033[0m Could not reach dashboard — using bundled agent"
    fi
  fi
  if [[ "${_agent_installed}" -eq 0 ]]; then
    sudo cp "${script_basedir}/xeqm_agent.py" /opt/xeqm-agent/xeqm_agent.py
    echo -e "  Installed: bundled xeqm_agent.py"
  fi

  sudo chmod 755 /opt/xeqm-agent/xeqm_agent.py
  sudo chown -R xeqm-agent:xeqm-agent /opt/xeqm-agent

  sudo tee /etc/xeqm-agent.conf > /dev/null <<AGENTCONF
[agent]
url   = ${_dashboard_url}
token = ${_agent_token}
AGENTCONF
  sudo chmod 640 /etc/xeqm-agent.conf
  sudo chown root:xeqm-agent /etc/xeqm-agent.conf
  echo -e "  Wrote: /etc/xeqm-agent.conf"

  sudo tee /etc/sudoers.d/xeqm-agent-restart > /dev/null <<'SUDOERS'
xeqm-agent ALL=(root) NOPASSWD: /bin/systemctl stop xeqmnode_snode*.service, /bin/systemctl start xeqmnode_snode*.service
xeqm-agent ALL=(root) NOPASSWD: /usr/bin/cp * /opt/xeqm-agent/*
xeqm-agent ALL=(ALL) NOPASSWD: /usr/sbin/ufw status
xeqm-agent ALL=(ALL) NOPASSWD: /usr/sbin/ufw allow *
SUDOERS
  sudo chmod 440 /etc/sudoers.d/xeqm-agent-restart

  sudo tee /etc/systemd/system/xeqm-agent.service > /dev/null <<'SVCEOF'
[Unit]
Description=XEQMLabs Operator Dashboard Agent (oneshot, fired by timer)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=xeqm-agent
Group=xeqm-agent
ExecStart=/usr/bin/python3 /opt/xeqm-agent/xeqm_agent.py
TimeoutStartSec=600s

[Install]
WantedBy=multi-user.target
SVCEOF

  sudo tee /etc/systemd/system/xeqm-agent.timer > /dev/null <<'TIMEREOF'
[Unit]
Description=Periodic XEQM dashboard agent report

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true
Unit=xeqm-agent.service

[Install]
WantedBy=timers.target
TIMEREOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now xeqm-agent.timer
  echo -e "  Enabled: xeqm-agent.timer (reporting every 60s)"

  echo -e "  Running initial report..."
  sudo systemctl start xeqm-agent.service 2>/dev/null || true

  echo -e "\n  \033[1;32m[DONE]\033[0m Agent installed and reporting to ${_dashboard_url}"
  config[agent_installed]=1
}

next_steps() {
  # Discover ALL installed nodes from disk for complete port table.
  # Use a plain indexed array of "snodeName p2pPort qnetPort" strings to avoid
  # declare -A associative arrays, which have macOS bash compatibility issues.
  local -a _ns_lines=()
  local _pf _uf _sn _p2p _qnet

  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    while IFS= read -r _pf; do
      _sn="$(basename "${_pf}" .plist)"
      _sn="${_sn##*.}"
      _p2p="$(grep -o -- '--p2p-bind-port=[0-9]*' "${_pf}" | grep -o '[0-9]*$' || true)"
      _qnet="$(grep -o -- '--quorumnet-port=[0-9]*' "${_pf}" | grep -o '[0-9]*$' || true)"
      _ns_lines+=("${_sn} ${_p2p:-?} ${_qnet:-?}")
    done < <(find "${XEQM_SVC_DIR}" -maxdepth 1 -name "${XEQM_SVC_LABEL_PREFIX}.snode*.plist" 2>/dev/null | sort)
  else
    while IFS= read -r _uf; do
      if grep -q '^User=xeqm$' "${_uf}" 2>/dev/null; then
        _sn="$(basename "${_uf}" .service)"
        _sn="${_sn#xeqmnode_}"
        _p2p="$(grep -o -- '--p2p-bind-port=[0-9]*' "${_uf}" | grep -o '[0-9]*$' || true)"
        _qnet="$(grep -o -- '--quorumnet-port=[0-9]*' "${_uf}" | grep -o '[0-9]*$' || true)"
        _ns_lines+=("${_sn} ${_p2p:-?} ${_qnet:-?}")
      fi
    done < <(find /etc/systemd/system -maxdepth 1 -name 'xeqmnode_snode*.service' 2>/dev/null | sort)
  fi

  tput rev 2>/dev/null || true; echo -e "\n\033[1m  NEXT STEPS — COMPLETE YOUR SETUP  \033[0m"; tput sgr0 2>/dev/null || true

  # [1] Register
  echo -e "\n\033[1m  [1]  Register each node\033[0m  (run after your wallet is funded)\n"
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    echo -e "       \033[1mbash ${script_basedir}/register.sh\033[0m"
  else
    echo -e "       \033[1msudo bash ${script_basedir}/register.sh\033[0m"
  fi

  # [2] Firewall ports — all installed nodes
  echo -e "\n\033[1m  [2]  Open these firewall ports\033[0m\n"
  if [[ "${#_ns_lines[@]}" -gt 0 ]]; then
    while IFS=' ' read -r _sn _p2p _qnet; do
      printf "       %-14s  p2p %-6s TCP     quorumnet %-6s TCP+UDP\n" \
        "${_sn}:" "${_p2p}" "${_qnet}"
    done < <(printf '%s\n' "${_ns_lines[@]}" | natsort)
  else
    local start_slot
    start_slot="$(next_snode_slot)"
    local install_count="${config[nodes]}"
    local first_slot=$(( start_slot - install_count ))
    local idx=1
    while [ "${idx}" -le "${install_count}" ]; do
      _sn="snode$(( first_slot + idx - 1 ))"
      printf "       %-14s  p2p %-6s TCP     quorumnet %-6s TCP+UDP\n" \
        "${_sn}:" "${config["snode${idx}__p2p_bind_port"]}" "${config["snode${idx}__quorumnet_port"]}"
      idx=$((idx + 1))
    done
  fi

  # [3] Key backup — nodes installed this run only
  echo -e "\n\033[1m  [3]  Back up your service node keys\033[0m  (losing a key = losing the node)\n"
  local start_slot
  start_slot="$(next_snode_slot)"
  local install_count="${config[nodes]}"
  local first_slot=$(( start_slot - install_count ))
  local idx=1
  while [ "${idx}" -le "${install_count}" ]; do
    _sn="snode$(( first_slot + idx - 1 ))"
    local _rpc="${config["snode${idx}__rpc_bind_port"]}"
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
      echo -e "       \033[1m${XEQM_BIN_DIR}/xeqm-d print_sn_key --rpc-admin=127.0.0.1:${_rpc}\033[0m"
    else
      echo -e "       \033[1msudo -u xeqm /opt/xeqm/bin/xeqm-d print_sn_key --rpc-admin=127.0.0.1:${_rpc}\033[0m"
    fi
    idx=$((idx + 1))
  done
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    echo -e "\n       Key files: \033[1m${XEQM_STATE_BASE}/snodeN/key_bls\033[0m  and  \033[1m${XEQM_STATE_BASE}/snodeN/key_ed25519\033[0m\n"
  else
    echo -e "\n       Key files: \033[1m/var/lib/xeqm/snodeN/key_bls\033[0m  and  \033[1m/var/lib/xeqm/snodeN/key_ed25519\033[0m\n"
  fi

  # [4] Agent (if installed this run)
  if [[ "${config[agent_installed]:-0}" -eq 1 ]]; then
    echo -e "\n\033[1m  [4]  Operator Dashboard Agent\033[0m\n"
    echo -e "       Agent is installed and reporting to:  \033[1m${config[agent_url]:-your dashboard}\033[0m"
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
      echo -e "       Check status:  \033[1mlaunchctl list com.xeqmlabs.agent\033[0m"
      echo -e "       View logs:     \033[1mtail -f ~/xeqm-agent/xeqm-agent.log\033[0m\n"
    else
      echo -e "       Check status:  \033[1msystemctl status xeqm-agent.timer\033[0m"
      echo -e "       View logs:     \033[1mjournalctl -u xeqm-agent --since today\033[0m\n"
    fi
  fi

  # Public dashboard reminder — shown when this host also runs a seed or pubnode
  if [[ "${OS_TYPE}" != "Darwin" ]]; then
    local _fleet_role=""
    systemctl is-active xeqm-seed.service    &>/dev/null && _fleet_role="seed"
    systemctl is-active xeqm-pubnode.service &>/dev/null && _fleet_role="pubnode"
    if [[ -n "${_fleet_role}" ]]; then
      echo -e "\n\033[1m  [!]  Add this host to the public dashboard fleet\033[0m"
      echo -e "\n       This server runs \033[1mxeqm-${_fleet_role}.service\033[0m and should appear on"
      echo -e "       dashboard.xeqmlabs.com. Run on missoula:\n"
      echo -e "       \033[1mPUBLISHER_TOKEN=<token> bash /opt/xeqm-public-dashboard/deploy-publisher.sh\033[0m\n"
      echo -e "       Then add the hostname to FLEET_NODES in /opt/xeqm-public-dashboard/app.py\n"
    fi
  fi

  # External firewall table — all installed nodes
  if [[ "${config[firewall_mode]:-}" = "external" || "${config[firewall_mode]:-}" = "oci" ]]; then
    local -a entries=()
    if [[ "${#_ns_lines[@]}" -gt 0 ]]; then
      while IFS=' ' read -r _sn _p2p _qnet; do
        entries+=("${_sn} ${_p2p} ${_qnet}")
      done < <(printf '%s\n' "${_ns_lines[@]}" | natsort)
    else
      local idx=1
      local start_slot
      start_slot="$(next_snode_slot)"
      local install_count="${config[nodes]}"
      local first_slot=$(( start_slot - install_count ))
      while [ "${idx}" -le "${install_count}" ]; do
        _sn="snode$(( first_slot + idx - 1 ))"
        entries+=("${_sn} ${config["snode${idx}__p2p_bind_port"]} ${config["snode${idx}__quorumnet_port"]}")
        idx=$((idx + 1))
      done
    fi
    print_external_firewall_guidance "${entries[@]}"
  fi

  [[ "${XEQM_FROM_MENU:-0}" = "1" ]] && read -rp $'\n  Press Enter to return to the menu...' _
}

install_usage() {
  cat <<USAGEMSG

bash $0 [OPTIONS...]

install.sh auto-detects existing installer-layout nodes and migrates them to
canonical layout before installing new ones. Run it on any server — fresh,
canonical, or installer-layout — and it will do the right thing.

Options:
  -b --copy-binaries [path]             Copy previously compiled binaries. If --version is
                                        set to a specific version it verifies the match.

                                        Example: --copy-binaries /tmp/xeqm-bins

  -c --copy-blockchain [bootstrap|no|auto|path]
                                        How to seed the blockchain. 'bootstrap' downloads
                                        from https://bootstrap.xeqmlabs.com (~15 min).
                                        'auto' copies from an existing node on this server.
                                        'no' syncs fresh from the network (many hours).
                                        'no,auto' = first node syncs fresh, subsequent
                                        nodes copy from it (multi-node installs).

                                        Examples: --copy-blockchain bootstrap
                                                  --copy-blockchain auto
                                                  --copy-blockchain /var/lib/xeqm/snode1
                                                  --copy-blockchain no
                                                  --copy-blockchain no,auto

  -i --inspect-auto-magic               Preview auto-detected ports and version.

  -n --nodes [number]                   Number of nodes to install (default: 1).

  -p  --ports [auto|config]             Port configuration. Format:
                                        p2p:<port[+port+...]>,rpc:<port[+port+...]>
                                        Quorumnet and OxenMQ are derived as p2p+2 / p2p+3.

                                        Examples:
                                        --ports p2p:9230,rpc:9231
                                        --nodes 2 --ports p2p:9230+9330,rpc:9231+9331

  -q --quiet                            Non-interactive mode. All decisions use defaults
                                        or supplied flags. Exits with an error if a
                                        required flag is missing. Blockchain defaults to
                                        'bootstrap'.

  -v --version [auto|version|hash]      XEQM version tag (v0.0.0), 'master', or git hash.
                                        'auto' installs the latest release.

                                        Examples:   --version auto
                                                    --version v20.0.0
                                                    --version 122d5f6a6

  --set-daemon-log-level [level]        Set daemon --log-level in the service file.

                                        Example:   --set-daemon-log-level 0,stacktrace:FATAL

  --open-firewall                       Auto-configure UFW/iptables for all required ports.

  -h  --help                            Show this help text

USAGEMSG
}

# ── Whiptail wizard ──────────────────────────────────────────────────────────

wz_nodes() {
  _calculate_max_nodes
  local _max="${_max_nodes}" _reason="${_limit_reason}" _val
  local _detail="RAM: ${_max_by_ram}  |  Disk: ${_max_by_disk}  |  CPU: ${_max_by_cpu}"

  # Count already-installed snode units so the user knows what "additional" means
  local _existing _existing_note="" _prompt_verb="service nodes"
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    _existing="$(find "${XEQM_SVC_DIR}" -maxdepth 1 -name "${XEQM_SVC_LABEL_PREFIX}.snode*.plist" 2>/dev/null | wc -l | tr -d ' ')"
  else
    _existing="$(systemctl list-units 'xeqmnode_snode*.service' --no-pager --no-legend 2>/dev/null | wc -l)"
  fi
  if [[ "${_existing}" -gt 0 ]]; then
    _prompt_verb="additional service nodes"
    _existing_note="\n\nNote: ${_existing} node(s) already installed on this server.\nEnter how many ADDITIONAL nodes to install."
  fi

  while true; do
    wt_inputbox "Service Nodes" \
      "How many ${_prompt_verb} would you like to install?\n\nThis server supports up to ${_max} more node(s) based on ${_reason}.\n(${_detail})${_existing_note}\n\nLeave blank to default to 1:" \
      17 66 _val ""
    local _rc=$?; [[ ${_rc} -ne 0 ]] && return ${_rc}
    _val="${_val:-1}"
    if [[ "${_val}" =~ ^[0-9]+$ && "${_val}" -ge 1 && \
          ( "${_val}" -le "${_max}" || "${config[force_install]:-0}" -eq 1 ) ]]; then
      nodes_option_handler "${_val}"
      return 0
    fi
    wt_msgbox "Invalid Input" \
      "Please enter a number between 1 and ${_max}.\n\nThe limit is based on available ${_reason}." 9 52
  done
}

wz_binary_source() {
  local _existing="" _choice
  find_existing_binaries_on_server _existing
  local _compile_desc="Compile from source (~1 hour)"
  [[ "${OS_TYPE}" == "Darwin" ]] && _compile_desc="Compile from source (requires Xcode + Homebrew, ~1 hour)"
  if [[ -n "${_existing}" ]]; then
    wt_menu "XEQM Binaries" "How would you like to get the XEQM node binaries?" \
      12 68 3 _choice \
      "Download"  "Download pre-built binaries from GitHub (fastest)" \
      "Existing"  "Already installed: ${_existing}" \
      "Compile"   "${_compile_desc}"
  else
    wt_menu "XEQM Binaries" "How would you like to get the XEQM node binaries?" \
      10 68 2 _choice \
      "Download"  "Download pre-built binaries from GitHub (fastest)" \
      "Compile"   "${_compile_desc}"
  fi
  local _rc=$?; [[ ${_rc} -ne 0 ]] && return ${_rc}
  case "${_choice}" in
    Download) config[binary_source]="download" ;;
    Existing) config[binary_source]="${_existing}" ;;
    Compile)  config[binary_source]="compile" ;;
  esac
  return 0
}

wz_blockchain() {
  local _choice
  wt_menu "Blockchain" "How should the node(s) get their blockchain?" \
    12 70 3 _choice \
    "Bootstrap" "Download bootstrap (fastest, ~15 min)" \
    "Auto"      "Copy from an existing active node on this server" \
    "Sync"      "Sync from the network (slowest, may take many hours)"
  local _rc=$?; [[ ${_rc} -ne 0 ]] && return ${_rc}
  case "${_choice}" in
    Bootstrap) copy_blockchain_option_handler "bootstrap" >/dev/null 2>&1 ;;
    Auto)      copy_blockchain_option_handler "auto"      >/dev/null 2>&1 ;;
    Sync)      copy_blockchain_option_handler "no"        >/dev/null 2>&1 ;;
  esac
  return 0
}

wz_public_ip() {
  local _detected _val
  _detected="$(detect_public_ip)"
  while true; do
    wt_inputbox "Public IP Address" \
      "Service nodes must advertise their public IPv4 address to the network.\n\nAuto-detected: ${_detected:-not found}\n\nAccept the detected IP or enter a different one:" \
      13 64 _val "${_detected}"
    local _rc=$?; [[ ${_rc} -ne 0 ]] && return ${_rc}
    if [[ "${_val}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      config[service_node_public_ip]="${_val}"
      return 0
    fi
    wt_msgbox "Invalid Input" "Please enter a valid IPv4 address (e.g. 203.0.113.10)." 8 52
  done
}

wz_firewall() {
  local _choice
  if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    wt_yesno "Firewall" \
      "UFW detected as active on this server.\n\nFirewall ports will be configured automatically.\n\nContinue with UFW?" \
      10 62 "Continue" "Back"
    local _rc=$?; [[ ${_rc} -ne 0 ]] && return ${_rc}
    config[firewall_mode]='ufw'
    config[open_firewall]=1
    return 0
  fi

  wt_menu "Firewall" "How is the firewall managed on this server?" \
    13 70 4 _choice \
    "UFW"      "UFW — configure automatically (recommended)" \
    "IPTables" "iptables — configure automatically" \
    "OCI"      "Oracle Cloud — UFW + remove iptables REJECT rule" \
    "External" "External firewall (OPNsense/pfSense) — show ports"
  local _rc=$?; [[ ${_rc} -ne 0 ]] && return ${_rc}
  case "${_choice}" in
    UFW)      config[firewall_mode]='ufw';      config[open_firewall]=1 ;;
    IPTables) config[firewall_mode]='iptables'; config[open_firewall]=1 ;;
    OCI)      config[firewall_mode]='oci';      config[open_firewall]=1 ;;
    External) config[firewall_mode]='external'; config[open_firewall]=0 ;;
  esac
  return 0
}

wz_detect() {
  auto_ports_option_handler >/dev/null 2>&1

  if ! version_option_handler "auto" >/dev/null 2>&1; then
    whiptail --msgbox "Could not fetch the latest XEQM version from GitHub.\n\nCheck network connectivity and try again.\n\nIf GitHub is unreachable, run the installer directly:\n  sudo bash install.sh --version core-v1.0.7" 14 64
    return 1
  fi

  local _start_slot
  _start_slot="$(next_snode_slot)"

  local _sum
  _sum="Auto-detected configuration for ${config[nodes]} node(s):\n\n"
  _sum+="$(printf "%-5s %-14s %-7s %-7s %-10s\n" "Node" "Snode" "P2P" "RPC" "Quorumnet")\n"
  _sum+="$(printf "%-5s %-14s %-7s %-7s %-10s\n" "────" "──────────────" "──────" "──────" "─────────")\n"
  local _i=1
  while [[ ${_i} -le ${config[nodes]} ]]; do
    _sum+="$(printf "%-5s %-14s %-7s %-7s %s\n" \
      "${_i}" \
      "snode$(( _start_slot + _i - 1 ))" \
      "${config["snode${_i}__p2p_bind_port"]}" \
      "${config["snode${_i}__rpc_bind_port"]}" \
      "${config["snode${_i}__quorumnet_port"]}")\n"
    _i=$((_i + 1))
  done
  _sum+="\nXEQM version:  ${config[install_version]}\n"
  _sum+="\nAll ports confirmed free on this server.\n"
  _sum+="\nQuorumnet requires both TCP + UDP open on your firewall.\n"
  _sum+="To use custom ports, press Back and cancel out, then run:\n"
  _sum+="  sudo bash install.sh --ports p2p:9230+9330,rpc:9231+9331"

  local _detect_ht=$(( config[nodes] + 16 ))
  [[ "${_detect_ht}" -lt 20 ]] && _detect_ht=20
  [[ "${_detect_ht}" -gt 36 ]] && _detect_ht=36
  wt_scrolltext "Auto-Detected Configuration" "${_sum}" "${_detect_ht}" 72
  local _rc=$?
  [[ ${_rc} -ne 0 ]] && return 1
  return 0
}

wz_agent() {
  if systemctl is-enabled --quiet xeqm-agent.timer 2>/dev/null; then
    wt_yesno "Dashboard Agent" \
      "The XEQM Operator Dashboard Agent is already installed and running.\n\nSkip agent configuration?" \
      9 64 "Skip" "Back"
    local _rc=$?; [[ ${_rc} -ne 0 ]] && return ${_rc}
    config[agent_url]=""
    config[agent_token]=""
    return 0
  fi

  local _wza_step=0
  local _wza_url="" _wza_tok=""

  while true; do
    case "${_wza_step}" in
      0)
        local _do_install
        wt_yesno "Dashboard Agent" \
          "Install the XEQM Operator Dashboard Agent?\n\nThe agent reports this server's node metrics to\nyour operator dashboard for remote monitoring\nand one-click node management.\n\nYou will need:\n  • Dashboard URL (e.g. https://dash.example.com)\n  • An agent token from Settings → Agents" \
          18 64 "Install Agent" "Skip"
        _do_install=$?
        if [[ "${_do_install}" -eq 255 ]]; then return 1; fi  # Esc = back in wizard
        if [[ "${_do_install}" -ne 0 ]]; then                 # Skip
          config[agent_url]=""; config[agent_token]=""
          return 0
        fi
        _wza_step=1
        ;;
      1)
        _wza_url=""
        wt_inputbox "Dashboard URL" \
          "Base URL of your operator dashboard.\n\nExamples:\n  https://dashboard.example.com\n  http://192.168.1.100:8080" \
          13 66 _wza_url ""
        local _url_rc=$?
        if [[ "${_url_rc}" -ne 0 || -z "${_wza_url}" ]]; then _wza_step=0; continue; fi
        _wza_step=2
        ;;
      2)
        _wza_tok=""
        wt_inputbox "Agent Token" \
          "Authentication token for this server.\n\nFind it in your dashboard:\n  Settings → Agents → Add Agent" \
          11 66 _wza_tok ""
        local _tok_rc=$?
        if [[ "${_tok_rc}" -ne 0 || -z "${_wza_tok}" ]]; then _wza_step=1; continue; fi
        config[agent_url]="${_wza_url}"
        config[agent_token]="${_wza_tok}"
        return 0
        ;;
    esac
  done
}

wz_confirm() {
  local _start_slot
  _start_slot="$(next_snode_slot)"

  local _sum="Ready to install ${config[nodes]} XEQM service node(s).\n\n"

  local _bin="${config[binary_source]}"
  [[ "${_bin}" = "download" ]] && _bin="Download from GitHub"
  [[ "${_bin}" = "compile" ]]  && _bin="Compile from source"
  local _bc="${config["snode1__copy_blockchain"]}"
  [[ "${_bc}" = "bootstrap" ]] && _bc="Bootstrap (bootstrap.xeqmlabs.com)"
  [[ "${_bc}" = "no" ]]        && _bc="Sync from network"
  local _fw="${config[firewall_mode]:-none}"
  case "${_fw}" in
    ufw)      _fw="UFW (auto-configure)" ;;
    iptables) _fw="iptables (auto-configure)" ;;
    oci)      _fw="Oracle Cloud (UFW + REJECT fix)" ;;
    external) _fw="External firewall (manual)" ;;
  esac

  local _agent_label="No (skip)"
  [[ -n "${config[agent_url]:-}" ]] && _agent_label="${config[agent_url]}"

  _sum+="$(printf "%-12s %s\n" "Binaries:"   "${_bin}")\n"
  _sum+="$(printf "%-12s %s\n" "Version:"    "${config[install_version]}")\n"
  _sum+="$(printf "%-12s %s\n" "Blockchain:" "${_bc}")\n"
  _sum+="$(printf "%-12s %s\n" "Public IP:"  "${config[service_node_public_ip]}")\n"
  _sum+="$(printf "%-12s %s\n" "Firewall:"   "${_fw}")\n"
  _sum+="$(printf "%-12s %s\n" "Agent:"      "${_agent_label}")\n\n"

  _sum+="$(printf "%-5s %-14s %-7s %s\n" "Node" "Snode" "P2P" "Quorumnet")\n"
  _sum+="$(printf "%-5s %-14s %-7s %s\n" "────" "──────────────" "──────" "─────────")\n"
  local _i=1
  while [[ ${_i} -le ${config[nodes]} ]]; do
    _sum+="$(printf "%-5s %-14s %-7s %s\n" \
      "${_i}" \
      "snode$(( _start_slot + _i - 1 ))" \
      "${config["snode${_i}__p2p_bind_port"]}" \
      "${config["snode${_i}__quorumnet_port"]}")\n"
    _i=$((_i + 1))
  done
  _sum+="\nClick 'Install' to begin. Installation is not reversible."

  local _confirm_ht=$(( config[nodes] + 19 ))
  [[ "${_confirm_ht}" -lt 20 ]] && _confirm_ht=20
  [[ "${_confirm_ht}" -gt 36 ]] && _confirm_ht=36
  wt_yesno "Confirm Installation" "${_sum}" "${_confirm_ht}" 72 "Install" "Back"
  return $?
}

run_wizard() {
  local _steps=(wz_nodes wz_binary_source wz_blockchain wz_public_ip wz_firewall wz_detect wz_agent wz_confirm)
  local _step=0
  while [[ ${_step} -lt ${#_steps[@]} ]]; do
    local _rc=0
    "${_steps[${_step}]}" || _rc=$?
    if [[ ${_rc} -eq 0 ]]; then
      _step=$((_step + 1))
    else
      if [[ ${_step} -eq 0 ]]; then
        clear
        echo -e "\nInstallation cancelled."
        exit 0
      fi
      _step=$((_step - 1))
    fi
  done
  config[wizard_confirmed]=1
  return 0
}

install_finally() {
  result=$?
  echo ""
  exit ${result}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap install_finally EXIT ERR INT
  install_run "${@}"
fi
