
[[ -n "${_XEQM_DISCOVERY_LOADED:-}" ]] && return 0
readonly _XEQM_DISCOVERY_LOADED=1

discover_system() {
  declare -n ds__result="$1"
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    ds__result[distro]="macos"
    ds__result[release]="$(sw_vers -productVersion 2>/dev/null || true)"
    ds__result[codename]=""
    # sysctl hw.memsize returns bytes; convert to kB to match Linux /proc/meminfo units
    ds__result[memory]="$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024)}' || echo 0)"
    ds__result[free_space_root_mount]="$(df / | awk 'END{ print $4 }')"
    ds__result[free_space_home_mount]="$(df ~ | awk 'END{ print $4 }')"
    ds__result[free_space_var_lib]="$(df ~ | awk 'END{ print $4 }')"
  else
    ds__result[distro]="$(lsb_release -a 2> /dev/null | grep -oP 'Distributor ID:\t+\K[a-zA-Z0-9-_\s]+' | awk '{ print tolower($1) }')"
    ds__result[release]="$(lsb_release -a 2>/dev/null | grep 'Release:' | awk '{ print $2 }')"
    ds__result[codename]="$(lsb_release -a 2>/dev/null | grep -oP 'Codename:\t+\K[a-zA-Z0-9-_\s]+')"
    ds__result[memory]="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{ print $2 }')"
    ds__result[free_space_root_mount]="$(df /root | awk 'END{ print $4 }')"
    ds__result[free_space_home_mount]="$(df /home | awk 'END{ print $4 }')"
    ds__result[free_space_var_lib]="$(df /var/lib 2>/dev/null | awk 'END{ print $4 }' || df / | awk 'END{ print $4 }')"
  fi
  return 0
}

discover_daemons() {
  declare -n dd__result="$1"
  local output_column="$2"
  local idx=0

  while read -r line; do
    dd__result[${idx}]="${line}"
    idx=$((idx + 1))
  done <<< "$(ps -f -o "${output_column}" -o args -ax 2>/dev/null | grep -e '[b]in/xeqm-d.*--service-node' | awk '{ print $1 }' | natsort | uniq )"

  return 0
}

_stat_size() { # cross-platform file size in bytes
  if [[ "${OS_TYPE}" == "Darwin" ]]; then stat -f %z "$1" 2>/dev/null || echo 0
  else stat -c %s "$1" 2>/dev/null || echo 0; fi
}

discover_biggest_blockchain() {
  local biggest_blockchain="" biggest_blockchain_size=0
  local blockchain_root blockchain_file blockchain_size

  # On macOS nodes live in ~/xeqm/snodeN/; on Linux in /var/lib/xeqm/snodeN/
  local _search_root="${XEQM_STATE_BASE}"

  while IFS= read -r mdb_file; do
    local sz; sz="$(_stat_size "${mdb_file}")"
    if [[ "${sz}" -gt "${biggest_blockchain_size}" ]]; then
      biggest_blockchain_size="${sz}"
      biggest_blockchain="$(dirname "$(dirname "${mdb_file}")")"
    fi
  done < <(find "${_search_root}" -maxdepth 3 -name 'data.mdb' 2>/dev/null)

  # Also check old installer layout on Linux
  if [[ "${OS_TYPE}" != "Darwin" ]]; then
    declare -A daemon_users
    discover_daemons daemon_users 'user'
    for username in "${daemon_users[@]}"; do
      [[ -d "/home/${username}/.xeqmlabs" ]] || continue
      blockchain_file="/home/${username}/.xeqmlabs/lmdb/data.mdb"
      [[ -f "${blockchain_file}" ]] || continue
      blockchain_size="$(_stat_size "${blockchain_file}")"
      if [[ "${blockchain_size}" -gt "${biggest_blockchain_size}" ]]; then
        biggest_blockchain="/home/${username}/.xeqmlabs"
        biggest_blockchain_size="${blockchain_size}"
      fi
    done
  fi

  echo "${biggest_blockchain}"
}

discover_free_port_sets() {
  declare -n result="$1"
  local number_of_sets="$2"
  local sets_counter=0

  local port_increment=100
  local p2p_port rpc_port quorumnet_port oxenmq_port validation_result
  p2p_port=${default_service_node_ports[p2p_bind_port]}

  while true; do
    rpc_port=$((p2p_port + 1))
    quorumnet_port=$((p2p_port + 2))
    oxenmq_port=$((p2p_port + 3))
    validation_result="$(validate_port "${p2p_port}") $(validate_port "${rpc_port}") $(validate_port "${quorumnet_port}") $(validate_port "${oxenmq_port}")"

    if [[ $(echo "${validation_result}" | grep -o -e 'free_port' | wc -l) -eq 4 ]]; then
      sets_counter=$((sets_counter + 1))
      result["set${sets_counter}__p2p_bind_port"]="${p2p_port}"
      result["set${sets_counter}__rpc_bind_port"]="${rpc_port}"
      result["set${sets_counter}__quorumnet_port"]="${quorumnet_port}"
      result["set${sets_counter}__oxenmq_port"]="${oxenmq_port}"

      [[ "${sets_counter}" -eq "${number_of_sets}" ]] && break

    elif [[ $(echo "${validation_result}" | grep -c 'outside_port_range') -ge 1 ]]; then
      return 1
    fi
    p2p_port=$((p2p_port + port_increment))
  done

  return 0
}

validate_port() {
  local port="$1"

  if [ "${port}" -lt 5000 ] || [ "${port}" -gt 49151 ]; then
    echo "outside_port_range"
  elif [[ "${OS_TYPE}" == "Darwin" ]] && lsof -nP -iTCP:"${port}" -iUDP:"${port}" 2>/dev/null | grep -q LISTEN; then
    echo "port_used"
  elif [[ "${OS_TYPE}" != "Darwin" ]] && [[ "$(sudo ss -lnp 2>/dev/null | grep -c ":${port}[^0-9]")" -gt 0 ]]; then
    echo "port_used"
  else
    echo "free_port"
  fi
}

discover_available_usernames() {
    declare -n result="$1"
    local number_of_usernames="$2"
    local username_base="$3"
    local idx=1
    local suffix=1

    while true; do
      local candidate_username="${username_base}${suffix}"
      if ! id -u "${candidate_username}" >/dev/null 2>&1; then
        result["${idx}"]="${candidate_username}"
        idx=$((idx + 1))
        [[ "${idx}" -gt "${number_of_usernames}" ]] && break
      fi
      suffix=$((suffix + 1))
    done
}
