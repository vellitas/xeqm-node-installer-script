[[ -n "${_XEQM_COMMON_LOADED:-}" ]] && return 0
readonly _XEQM_COMMON_LOADED=1

xeqmnode_installer_version='v6.2'
readonly xeqmnode_installer_version

# Ensure tput works when TERM is unset or set to an invalid value by sudo
[[ -z "${TERM:-}" || "${TERM:-}" = "unknown" || "${TERM:-}" = "dumb" ]] && export TERM=xterm

version_regex="^core-v[0-9]+\.[0-9]+\.[0-9]+$"
readonly version_regex

rev_hash_regex="^[0-9a-f]{5,40}$"
readonly rev_hash_regex

installer_session_state_file="${script_basedir}/.installsessionstate"
readonly installer_session_state_file

typeset -A config
config=(
  [nodes]=1
  [install_version]='auto'
  [running_user]='snode'
  [required_cmake_version]='3.28'
  [git_repository]='https://github.com/XEQMLabs/xeqm-core.git'
  [p2p_bind_port]=9230
  [rpc_bind_port]=9231
  [daemon_log_level]=
  [daemon_no_fluffy_blocks]=0
  [open_firewall]=0
  [firewall_mode]=
  [quiet_mode]=0
  [binary_source]='compile'
  [service_node_public_ip]=
)

typeset -A installer_state
installer_state=(
  [started]='started'
  [install_packages]='install_packages'
  [checkout_git]='checkout_git'
  [compile_move]='compile_move'
  [install_service]='install_service'
  [enable_service]='enable_service'
  [start_service]='start_service'
  [watch_daemon]='watch_daemon'
  [ask_prepare]='ask_prepare'
  [finished_xeqmnode_install]='finished_xeqmnode_install'
)
readonly installer_state

# ── Platform detection ────────────────────────────────────────────────────────
OS_TYPE="$(uname -s)"   # Linux | Darwin
OS_ARCH="$(uname -m)"   # x86_64 | arm64 | aarch64
readonly OS_TYPE OS_ARCH

if [[ "${OS_TYPE}" == "Darwin" ]]; then
    XEQM_BIN_DIR="${HOME}/xeqm-bin"
    XEQM_STATE_BASE="${HOME}/xeqm"
    XEQM_SVC_DIR="${HOME}/Library/LaunchAgents"
    XEQM_SVC_LABEL_PREFIX="com.xeqmlabs"
    XEQM_RUN_USER="${USER}"
    _SUDO=""
else
    XEQM_BIN_DIR="/opt/xeqm/bin"
    XEQM_STATE_BASE="/var/lib/xeqm"
    XEQM_SVC_DIR="/etc/systemd/system"
    XEQM_SVC_LABEL_PREFIX="xeqmnode"
    XEQM_RUN_USER="xeqm"
    _SUDO="sudo"
fi
readonly XEQM_BIN_DIR XEQM_STATE_BASE XEQM_SVC_DIR XEQM_SVC_LABEL_PREFIX XEQM_RUN_USER _SUDO

# On macOS, download is the only sane default (no release apt/deb packages)
[[ "${OS_TYPE}" == "Darwin" ]] && config[binary_source]='download'

# Provide natsort as a pure-python shell function when the command isn't installed.
# This covers macOS (pip broken on pre-release OS versions) and any Linux system
# where python3-natsort wasn't installed. Reads stdin, prints natural-sorted lines.
if ! command -v natsort >/dev/null 2>&1; then
  natsort() {
    # Use -c so the script is an argument, leaving stdin free for piped input.
    # python3 - <<'HEREDOC' replaces stdin with the heredoc, breaking pipelines.
    python3 -c '
import re, sys
def _k(s): return [int(c) if c.isdigit() else c.lower() for c in re.split(r"(\d+)", s)]
print("\n".join(sorted(sys.stdin.read().splitlines(), key=_k)))
'
  }
  export -f natsort
fi

typeset -A default_service_node_ports
default_service_node_ports=(
  [p2p_bind_port]=9230
  [rpc_bind_port]=9231
)
readonly default_service_node_ports

load_config() {
  local config_file="$1"
  local -n lc__config_ref="$2"
  if [[ -f "${config_file}" ]]; then
    while IFS= read -r line; do
      if echo "${line}" | grep -q "="; then
        varname=$(echo "${line}" | cut -d '=' -f 1)
        varvalue=$(echo "${line}" | cut -d '=' -f 2-)
        lc__config_ref[${varname}]=${varvalue}
      fi
    done < "${config_file}"
  fi
}

write_config() {
  local -n wc__node_config_ref="$1"
  local install_file_conf_path="$2"

  if [[ -f "${install_file_conf_path}" ]]; then
    sudo rm -Rf "${install_file_conf_path}"
  fi
  sudo touch "${install_file_conf_path}"

  for key in "${!wc__node_config_ref[@]}"
  do
    echo -e "${key}=${wc__node_config_ref[${key}]}" | sudo tee -a "${install_file_conf_path}" > /dev/null
  done
  sudo chown "${wc__node_config_ref[running_user]}":root "${install_file_conf_path}"
}

#### Common command line option handlers for upgrade.sh & install.sh ###
version_option_handler() {
  if [[ "$1" = "auto" ]]; then
    echo -e "\n\033[1mAuto-detecting latest XEQM version tag...\033[0m"
    config[install_version]="$(get_latest_xeqm_version_number)" || return 1
  elif [[ "$1" = "master" || "$1" =~ ${version_regex} || "$1" =~ ${rev_hash_regex} ]]; then
    echo -e "\n\033[1mUsing manually set XEQM branch/version/hash:\033[0m"
    config[install_version]="$1"
  else
    echo -e "\033[0;33merror: Invalid --version value '$1'\033[0m\n"
    usage
    return 1
  fi
  echo -e "-> ${config[install_version]}"
}

daemon_log_level_option_handler() {
  if [[ -n "$1" ]]; then
    config[daemon_log_level]="$1"
  fi
}

git_repository_option_handler() {
  if [[ -n "$1" ]]; then
    config[git_repository]="$1"
  fi
}

#### END Common command line option handlers
pre_install_checks () {
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && echo -e "\n\033[1mExecuting pre-install checks...\033[0m"
  inspect_time_services || return 1
  upgrade_cmake_if_needed || return 1
}

inspect_time_services () {
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && echo -e "\n\033[1mChecking clock NTP synchronisation...\033[0m"

  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    # macOS: sntp is available; a non-zero offset >1s is a warning but not a hard stop
    local _offset
    _offset="$(sntp -t 2 time.apple.com 2>/dev/null | grep -o '[+-][0-9]*\.[0-9]*' | head -1 || true)"
    if [[ -z "${_offset}" ]]; then
      echo -e "  \033[0;33mWARNING:\033[0m Could not verify NTP offset — ensure system clock is synced in System Settings → General → Date & Time."
    else
      echo -e "  NTP offset: ${_offset}s — clock synced."
    fi
    return 0
  fi

  if [[ -x "$(command -v timedatectl)" ]]; then
    if [[ $(sudo timedatectl | grep -o -e 'synchronized: yes' -e 'service: active' | wc -l) -ne 2 ]]; then
      local _msg="Clock NTP synchronisation is not working correctly.\nThis is required for a stable service node.\nPlease fix 'timedatectl' before continuing."
      if wt_available; then
        whiptail --title "NTP Error" --msgbox "${_msg}" 10 64
      else
        echo -e "\n\033[0;33mERROR: ${_msg}\033[0m\n"
        timedatectl
      fi
      return 1
    fi
  else
    local _warn="Clock NTP synchronisation could not be verified.\nPlease check this is working before continuing."
    if wt_available; then
      whiptail --title "NTP Warning" --yesno "${_warn}\n\nContinue anyway?" 10 64 --yes-button "Continue" --no-button "Cancel" || return 1
    elif [[ "${config[quiet_mode]:-0}" -eq 1 ]]; then
      return 0
    else
      echo -e "\033[0;33mWARNING: ${_warn}\033[0m\n"
      while true; do
        read -p $'\033[1mAre you sure you want to continue?\e[0m (NOT RECOMMENDED) [Y/N]: ' yn
        yn=${yn:-N}
        case $yn in
          [Yy]* ) break ;;
          [Nn]* ) return 1 ;;
          * ) echo -e "(Please answer Y or N)" ;;
        esac
      done
    fi
  fi
}

upgrade_cmake_if_needed() {
  local current_cmake_version

  # skip cmake check when downloading or using pre-built binaries
  if [[ "${config[binary_source]:-}" = "download" ]] || \
     [[ ! -z "${command_options_set[copy_binaries]:-}" && "${command_options_set[copy_binaries]}" -eq 1 ]]; then
    [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && echo -e "\n\033[1mSkipping cmake check (not compiling)...\033[0m"
    return 0
  fi

  [[ -x "$(command -v cmake)" ]] && current_cmake_version="$(cmake --version | awk 'NR==1 { print $3  }')" || current_cmake_version='not installed'

  if [[ "${system_info[distro]}" = "ubuntu" && ( "${current_cmake_version}" = 'not installed' || "$(version2num "${current_cmake_version}")" -lt "$(version2num "${config[required_cmake_version]}")" ) ]]; then
    echo -e "\n\033[1mUpgrading cmake (${current_cmake_version}) to newest version...\033[0m"
    sudo apt-get update
    sudo apt-get -y install gpg wget
    wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${system_info[codename]} main" | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null
    sudo apt-get update
    sudo apt-get -y install cmake
  fi
}

validate_command_line_option_combinations() {
  local -n vcloc__valid_option_combination_ref=$1
  local group_option_count command_options_set_string unique_count valid_option_combi_found
  valid_option_combi_found=0

  command_options_set_string="$(generate_set_options_string)"
  [[ "${command_options_set_string}" = '' ]] && command_options_set_string='<no_options_set>'

  for option_string in "${vcloc__valid_option_combination_ref[@]}"
  do
    group_option_count="$(echo "${option_string}" | grep -Eo '[^ ]+' | wc -l)"
    unique_count="$(echo "${option_string} ${command_options_set_string}" | grep -Eo '[^ ]+' | natsort | uniq | wc -l)"

    [[ "${unique_count}" -le "${group_option_count}" ]] && valid_option_combi_found=1 && break
  done

  if [[ "${valid_option_combi_found}" -eq 0 && "${command_options_set_string}" != '<no_options_set>' ]]; then
    echo -e "\033[0;33merror: Invalid option combination\033[0m\n"
    usage
    exit 1
  fi
}

generate_set_options_string() {
  local result=''
  for option in "${!command_options_set[@]}"
  do
    [[ "${command_options_set[$option]}" -eq 1 ]] && result+="${option} "
  done
  echo "${result}"
}

copy_binaries_to_directory(){
  local source_dir="$1"
  local target_dir="$2"

  if [[ -d "${target_dir}" ]]; then
    # move existing bin directory just to be safe
    ${_SUDO} mv "${target_dir}" "${target_dir}_$(printf '%08x' $RANDOM)"
  fi
  echo -e "\n\033[1mCopying binaries from '${source_dir}' to '${target_dir}'.\033[0m"
  sudo cp -R "${source_dir}" "${target_dir}"
}

validate_manual_user_string_format() {
  [[ "$(echo "$1" | grep -oP -e "(?<=,|^)+[a-zA-Z][a-zA-Z0-9]+(?=,|$)+" | natsort | uniq | wc -l)" -gt 0 ]]
}

set_install_session_state() {
  local newstate="${1}"
  printf "%s" "${newstate}" > "${installer_session_state_file}"
}

read_install_session_state() {
  cat "${installer_session_state_file}"
}

default_ports_configured() {
  [[
    "${config[p2p_bind_port]}" -eq "${default_service_node_ports[p2p_bind_port]}" &&
    "${config[rpc_bind_port]}" -eq "${default_service_node_ports[rpc_bind_port]}"
  ]]
}

get_latest_xeqm_version_number() {
  local version
  version="$(git ls-remote --tags "${config[git_repository]}" 2>/dev/null \
    | awk -F'/' '{print $NF}' \
    | grep -E '^core-v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -1)"
  if [[ -z "${version}" ]]; then
    printf "\033[0;31mFATAL\033[0m: Could not retrieve latest version from '%s'. Check network connectivity.\n" "${config[git_repository]}" >&2
    return 1
  fi
  echo "${version}"
}

version2num() {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1, $2, $3, $4); }'
}

# prompt_menu <title> <nameref-result> <default-index> <option1> [option2 ...]
# In quiet mode uses the default without prompting.
prompt_menu() {
  local title="$1"
  local -n pm__result="$2"
  local default="${3:-1}"
  shift 3
  local options=("$@")

  if [[ "${config[quiet_mode]:-0}" -eq 1 ]]; then
    pm__result="${default}"
    return 0
  fi

  echo -e "\n\033[1m${title}\033[0m\n"
  local idx=1
  for option in "${options[@]}"; do
    printf "  \033[1;33m[%d]\033[0m %s\n" "${idx}" "${option}"
    idx=$((idx + 1))
  done
  echo ""

  local pm__input
  while true; do
    read -rp "  Choice [${default}]: " pm__input
    pm__input="${pm__input:-${default}}"
    if [[ "${pm__input}" =~ ^[0-9]+$ && "${pm__input}" -ge 1 && "${pm__input}" -le "${#options[@]}" ]]; then
      pm__result="${pm__input}"
      return 0
    fi
    echo -e "  \033[0;33mPlease enter a number between 1 and ${#options[@]}\033[0m"
  done
}

prompt_firewall_mode() {
  # macOS: no UFW/iptables; ports must be opened in the router or macOS firewall externally
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    config[firewall_mode]='external'
    config[open_firewall]=0
    echo -e "  macOS detected — firewall mode set to external. Open required ports in your router or macOS firewall manually."
    return 0
  fi

  # Auto-detect: if ufw is installed and active, skip the prompt entirely
  if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    config[firewall_mode]='ufw'
    config[open_firewall]=1
    echo -e "  UFW detected as active — firewall ports will be configured automatically."
    return 0
  fi

  local choice
  prompt_menu "How is the firewall managed on this server?" choice 1 \
    "UFW (Uncomplicated Firewall)  — configure automatically  (recommended for VPS)" \
    "iptables  — configure automatically" \
    "Oracle Cloud (OCI)  — UFW + remove raw iptables REJECT rule" \
    "OPNsense, pfSense, or other external firewall  — show required ports"

  case "${choice}" in
    1) config[firewall_mode]='ufw';      config[open_firewall]=1 ;;
    2) config[firewall_mode]='iptables'; config[open_firewall]=1 ;;
    3) config[firewall_mode]='oci';      config[open_firewall]=1 ;;
    4) config[firewall_mode]='external'; config[open_firewall]=0 ;;
  esac
}

# print_external_firewall_guidance <"label p2p quorum"> [...]
# Each argument is a space-separated triple: node-label p2p-port quorum-port
print_external_firewall_guidance() {
  local server_ip
  server_ip="$(detect_public_ip)"
  [[ -n "${config[service_node_public_ip]:-}" ]] && server_ip="${config[service_node_public_ip]}"

  echo -e "\n\033[1mExternal Firewall Configuration Required\033[0m"
  echo -e "\033[0;33mOpen the following ports inbound to this server (${server_ip}):\033[0m\n"
  printf "  \033[1m%-18s %-14s %-8s %-8s\033[0m\n" "Node" "Service" "Port" "Protocol"
  printf "  %-18s %-14s %-8s %-8s\n" "──────────────────" "──────────────" "────────" "────────"
  local entry
  for entry in "$@"; do
    local label p2p quorum
    read -r label p2p quorum <<< "${entry}"
    printf "  %-18s %-14s %-8s %s\n" "${label}" "P2P"       "${p2p}"    "TCP"
    printf "  %-18s %-14s %-8s %s\n" ""          "Quorumnet" "${quorum}" "TCP"
    printf "  %-18s %-14s %-8s %s\n" ""          "Quorumnet" "${quorum}" "UDP"
  done
  echo -e "\n  \033[1mOPNsense:\033[0m  Firewall → NAT → Port Forward — add one rule per port above"
  echo -e "  \033[1mpfSense:\033[0m   Firewall → NAT → Port Forward — add one rule per port above"
  echo -e "  \033[1mOther:\033[0m     Add inbound TCP allow + forward rules for each port above,"
  echo -e "             pointing to this server's internal IP address."
  echo -e "  \033[1mOracle Cloud:\033[0m After adding Security List rules, also run:"
  echo -e "             sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited"
  echo -e "             (OCI ships a raw iptables REJECT that silently blocks externally-opened ports)"
  echo -e "\n  \033[0;33mNote:\033[0m The RPC port does not need to be opened — it is bound to 127.0.0.1 only.\n"
}

detect_public_ip() {
  local ip
  ip="$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null \
    || curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null \
    || dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1)"
  [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "${ip}" || echo ""
}

prompt_service_node_public_ip() {
  local detected_ip
  detected_ip="$(detect_public_ip)"

  echo -e "\n\033[1mService nodes must advertise their public IPv4 address to the network.\033[0m"

  local ip
  while true; do
    read -rp $'\n\033[1mPublic IPv4 address of this server\033[0m '"[${detected_ip}]: " ip
    ip="${ip:-${detected_ip}}"
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      config[service_node_public_ip]="${ip}"
      echo -e "  Using: ${ip}"
      return 0
    fi
    echo -e "  \033[0;33mPlease enter a valid IPv4 address\033[0m"
  done
}

create_user_if_needed() {
  [[ "${OS_TYPE}" == "Darwin" ]] && return 0   # macOS: nodes run as current user, no system user needed
  local user="$1"
  if ! id -u "${user}" >/dev/null 2>&1; then
    sudo adduser --disabled-password --gecos "${user}" "${user}"
    if [[ -f "${script_basedir}/.onepasswd" ]]; then
      sudo usermod -p "$(cat "${script_basedir}/.onepasswd")" "${user}"
    fi
    sudo usermod -aG sudo "${user}"
  fi
}

sudoers_user_nopasswd() {
  local action="$1"
  local user="$2"
  local sudoers_file="/etc/sudoers.d/xeqmnode-${user}"

  if [[ "${action}" = 'add' ]]; then
    echo "${user} ALL=(ALL) NOPASSWD:ALL" | sudo tee "${sudoers_file}" > /dev/null
    sudo chmod 440 "${sudoers_file}"
  else
    [[ -f "${sudoers_file}" ]] && sudo rm "${sudoers_file}"
  fi
}

setup_running_user() {
  local running_user="$1"
  create_user_if_needed "${running_user}"
  sudoers_user_nopasswd 'add' "${running_user}"
}

find_existing_binaries_on_server() {
  local -n febos__result="$1"
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    if [[ -x "${XEQM_BIN_DIR}/xeqm-d" ]]; then
      febos__result="${XEQM_BIN_DIR}"; return 0
    fi
  else
    if [[ -x "/opt/xeqm/bin/xeqm-d" ]]; then
      febos__result="/opt/xeqm/bin"; return 0
    fi
    local bin_dir
    for bin_dir in /home/snode*/bin; do
      [[ -x "${bin_dir}/xeqm-d" ]] && febos__result="${bin_dir}" && return 0
    done
  fi
  febos__result=""
  return 0
}

# ── Canonical layout helpers ─────────────────────────────────────────────────

next_snode_slot() {
  local n=1
  while [[ "${n}" -le 200 ]]; do
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
      if [[ ! -d "${XEQM_STATE_BASE}/snode${n}" ]] && \
         ! launchctl list 2>/dev/null | awk '{print $3}' | grep -qF "$(svc_label "snode${n}")"; then
        echo "${n}"; return 0
      fi
    else
      if [[ ! -d "/var/lib/xeqm/snode${n}" ]] && \
         ! systemctl cat "xeqmnode_snode${n}.service" >/dev/null 2>&1; then
        echo "${n}"; return 0
      fi
    fi
    n=$(( n + 1 ))
  done
  echo -e "\033[0;31merror\033[0m: Could not find a free snode slot (checked snode1–snode200). Check for corrupted state." >&2
  return 1
}

ensure_xeqm_user() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    return 0  # macOS: run as current user, no system user needed
  fi
  if ! id -u xeqm >/dev/null 2>&1; then
    echo -e "\n\033[1mCreating shared system user 'xeqm'...\033[0m"
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin xeqm
  fi
}

# ── Service management abstraction (Linux: systemd  macOS: launchd) ───────────

svc_label() {
  # Linux → "xeqmnode_snode1"   macOS → "com.xeqmlabs.snode1"
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    echo "${XEQM_SVC_LABEL_PREFIX}.${1}"
  else
    echo "xeqmnode_${1}"
  fi
}

svc_plist_path() { echo "${XEQM_SVC_DIR}/$(svc_label "${1}").plist"; }

clear_port_if_stale() {
  local port="$1"
  local pids
  pids="$(lsof -ti ":${port}" 2>/dev/null || true)"
  if [[ -n "${pids}" ]]; then
    echo -e "  Port ${port} is held by stale process(es) — clearing..."
    # shellcheck disable=SC2086
    kill ${pids} 2>/dev/null || true
    sleep 2
    pids="$(lsof -ti ":${port}" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    [[ -n "${pids}" ]] && kill -9 ${pids} 2>/dev/null || true
    sleep 1
  fi
}

svc_start() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    launchctl start "$(svc_label "${1}")"
  else
    sudo systemctl start "xeqmnode_${1}"
  fi
}

svc_stop() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    launchctl stop "$(svc_label "${1}")"
  else
    sudo systemctl stop "xeqmnode_${1}"
  fi
}

svc_is_active() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    local _pid
    _pid="$(launchctl list 2>/dev/null | awk '$3 == "'"$(svc_label "${1}")"'" { print $1 }')"
    [[ -n "${_pid}" && "${_pid}" != "-" ]]
  else
    systemctl is-active --quiet "xeqmnode_${1}" 2>/dev/null
  fi
}

svc_status() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    local _pid
    _pid="$(launchctl list 2>/dev/null | awk '$3 == "'"$(svc_label "${1}")"'" { print $1 }')"
    if [[ -n "${_pid}" && "${_pid}" != "-" ]]; then echo "running"
    elif launchctl list 2>/dev/null | awk '{print $3}' | grep -qF "$(svc_label "${1}")"; then echo "stopped"
    else echo "inactive"
    fi
  else
    systemctl is-active "xeqmnode_${1}" 2>/dev/null || echo "inactive"
  fi
}

svc_enable() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    mkdir -p "${XEQM_SVC_DIR}"
    launchctl load "$(svc_plist_path "${1}")" 2>/dev/null || true
  else
    sudo systemctl enable "xeqmnode_${1}"
  fi
}

svc_disable() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    launchctl unload "$(svc_plist_path "${1}")" 2>/dev/null || true
  else
    sudo systemctl disable "xeqmnode_${1}"
  fi
}

svc_reload_daemon() {
  [[ "${OS_TYPE}" != "Darwin" ]] && sudo systemctl daemon-reload || true
}

svc_mainpid() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    launchctl list 2>/dev/null | awk '$3 == "'"$(svc_label "${1}")"'" { print $1 }' \
      | grep -v '^-$' || echo ""
  else
    systemctl show -p MainPID --value "xeqmnode_${1}" 2>/dev/null || echo ""
  fi
}

svc_logs() {
  local snode="$1"; shift
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    local _logfile="${XEQM_STATE_BASE}/${snode}/xeqm-d.log"
    # If -f is in args, follow the log file; otherwise tail static
    if [[ " $* " == *" -f "* ]]; then
      tail -f "${_logfile}"
    else
      tail -n 200 "${_logfile}" 2>/dev/null || true
    fi
  else
    sudo journalctl -u "xeqmnode_${snode}" "$@"
  fi
}

install_binary_to_opt() {
  local binary_source="${config[binary_source]}"
  local version="${config[install_version]}"
  local opt_bin="${XEQM_BIN_DIR}"
  local versioned_bin="${opt_bin}/xeqm-d-${version}"
  local symlink="${opt_bin}/xeqm-d"

  ${_SUDO} mkdir -p "${opt_bin}"

  # When version=auto, reuse existing symlink rather than re-downloading/recompiling.
  # Do NOT skip when --copy-binaries was given (binary_source is a path, not download/compile).
  if [[ "${version}" = "auto" && -x "${symlink}" && "${config[force_install]:-0}" -ne 1 \
        && ( "${binary_source}" = "download" || "${binary_source}" = "compile" ) ]]; then
    local current_ver
    current_ver="$("${symlink}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'unknown')"
    echo -e "\n  Binary already installed: ${symlink} (v${current_ver}) — skipping install"
    return 0
  fi

  if [[ -f "${versioned_bin}" && "${config[force_install]:-0}" -ne 1 ]]; then
    local host_arch bin_arch arch_ok=0
    host_arch="$(uname -m)"
    bin_arch="$(file "${versioned_bin}" 2>/dev/null)"
    case "${host_arch}" in
      x86_64)  echo "${bin_arch}" | grep -qiE 'x86-64|x86_64' && arch_ok=1 ;;
      aarch64) echo "${bin_arch}" | grep -qiE 'aarch64|arm64'  && arch_ok=1 ;;
      *)       arch_ok=1 ;;
    esac
    if [[ "${arch_ok}" -eq 0 ]]; then
      echo -e "\n  \033[0;33mwarn\033[0m: Existing binary ${versioned_bin} is wrong architecture for ${host_arch} — removing and re-downloading." >&2
      ${_SUDO} rm -f "${versioned_bin}"
    else
      echo -e "\n  Binary ${versioned_bin} already installed — skipping download."
      ${_SUDO} ln -sf "${versioned_bin}" "${symlink}"
      return 0
    fi
  fi

  if [[ "${binary_source}" = "compile" ]]; then
    compile_binary_to_opt "${versioned_bin}"
  elif [[ "${binary_source}" = "download" ]]; then
    local bins_path _bin _bname
    bins_path="$(download_release_binaries)"
    ${_SUDO} cp "${bins_path}/xeqm-d" "${versioned_bin}"
    ${_SUDO} chmod 755 "${versioned_bin}"
    for _bin in "${bins_path}"/*; do
      _bname="$(basename "${_bin}")"
      if [[ -d "${_bin}" ]]; then
        ${_SUDO} cp -R "${_bin}" "${opt_bin}/${_bname}"
      elif [[ -f "${_bin}" && -x "${_bin}" && "${_bname}" != "xeqm-d" ]]; then
        ${_SUDO} cp "${_bin}" "${opt_bin}/${_bname}"
        ${_SUDO} chmod 755 "${opt_bin}/${_bname}"
      fi
    done
    rm -rf "$(dirname "${bins_path}")"
  elif [[ -n "${binary_source}" && -x "${binary_source}/xeqm-d" ]]; then
    local _bin _bname
    ${_SUDO} cp "${binary_source}/xeqm-d" "${versioned_bin}"
    ${_SUDO} chmod 755 "${versioned_bin}"
    for _bin in "${binary_source}"/*; do
      _bname="$(basename "${_bin}")"
      if [[ -d "${_bin}" ]]; then
        ${_SUDO} cp -R "${_bin}" "${opt_bin}/${_bname}"
      elif [[ -f "${_bin}" && -x "${_bin}" && "${_bname}" != "xeqm-d" ]]; then
        ${_SUDO} cp "${_bin}" "${opt_bin}/${_bname}"
        ${_SUDO} chmod 755 "${opt_bin}/${_bname}"
      fi
    done
  else
    echo -e "\033[0;31merror\033[0m: Binary source '${binary_source}' is not valid or xeqm-d not found."
    exit 1
  fi

  # Verify the binary matches the host architecture before overwriting the symlink
  local host_arch bin_arch
  host_arch="$(uname -m)"
  bin_arch="$(file "${versioned_bin}" 2>/dev/null)"
  local arch_ok=0
  case "${host_arch}" in
    x86_64)  echo "${bin_arch}" | grep -qiE 'x86-64|x86_64' && arch_ok=1 ;;
    aarch64|arm64) echo "${bin_arch}" | grep -qiE 'aarch64|arm64'  && arch_ok=1 ;;
    *)       arch_ok=1 ;;  # unknown host arch — skip check
  esac
  if [[ "${arch_ok}" -eq 0 ]]; then
    ${_SUDO} rm -f "${versioned_bin}"
    echo -e "\033[0;31merror\033[0m: Downloaded binary is not compatible with this host (${host_arch})." >&2
    echo -e "  file reports: ${bin_arch}" >&2
    echo -e "  The existing installation has NOT been modified." >&2
    exit 1
  fi

  ${_SUDO} ln -sf "${versioned_bin}" "${symlink}"

  # Verify binary executes on this CPU — catches SIGILL from AVX2/AVX-512 incompatibility
  # before any service nodes are installed.
  if [[ "${OS_TYPE}" != "Darwin" ]]; then
    local _test_rc=0
    timeout 5 "${symlink}" --version >/dev/null 2>&1 || _test_rc=$?
    if [[ "${_test_rc}" -eq 132 ]]; then
      ${_SUDO} rm -f "${versioned_bin}" 2>/dev/null || true
      ${_SUDO} rm -f "${symlink}" 2>/dev/null || true
      local _cpu_model
      _cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'unknown')"
      echo -e "\n\033[0;31merror\033[0m: The binary is not compatible with this CPU (SIGILL — illegal instruction)." >&2
      echo -e "  CPU: ${_cpu_model}" >&2
      echo -e "  The prebuilt release requires CPU extensions (e.g. AVX2) that this processor lacks." >&2
      echo -e "  Compile from source on this machine:" >&2
      echo -e "    sudo bash install.sh --binary-source compile" >&2
      exit 1
    fi
  fi

  echo -e "\n  \033[1;32mBinary installed:\033[0m ${versioned_bin}"
  echo -e "  \033[1;32mSymlink updated:\033[0m  ${symlink} -> ${versioned_bin}"
}

# Ensure xeqm-mdb_copy is installed alongside xeqm-d. Called proactively by to_canonical.sh
# before any migration begins — the script fixes the host rather than asking the user to.
# Falls back gracefully (with a warning) if the fetch fails; the migration then uses the
# stop-and-copy path instead of the zero-downtime path.
ensure_xeqm_mdb_copy() {
  local mdb_copy="/opt/xeqm/bin/xeqm-mdb_copy"
  [[ -x "${mdb_copy}" ]] && return 0

  echo -e "\n\033[1mxeqm-mdb_copy not found — fetching from latest release...\033[0m"

  local tmp_dir api_url release_info download_url tool_path
  tmp_dir="$(mktemp -d /tmp/xeqm-mdb-XXXXXX)"
  api_url="https://api.github.com/repos/XEQMLabs/xeqm-core/releases/latest"

  release_info="$(wget --quiet -O - "${api_url}" 2>/dev/null)" || {
    echo -e "  \033[0;33mWarning: Could not reach GitHub — migration will use stop-and-copy fallback\033[0m"
    rm -rf "${tmp_dir}"; return 0
  }

  download_url="$(echo "${release_info}" \
    | grep -o '"browser_download_url": "[^"]*"' \
    | grep -iv '\.sha256' \
    | grep -iE 'linux|ubuntu' \
    | grep -iE 'x86_64|amd64' \
    | head -1 | grep -o 'https://[^"]*')"

  if [[ -z "${download_url}" ]]; then
    echo -e "  \033[0;33mWarning: No Linux release asset found — migration will use stop-and-copy fallback\033[0m"
    rm -rf "${tmp_dir}"; return 0
  fi

  echo -e "  Downloading: ${download_url##*/}"
  wget --quiet -O "${tmp_dir}/release.archive" "${download_url}" 2>/dev/null || {
    echo -e "  \033[0;33mWarning: Download failed — migration will use stop-and-copy fallback\033[0m"
    rm -rf "${tmp_dir}"; return 0
  }

  case "${download_url}" in
    *.tar.gz|*.tgz) tar -xzf "${tmp_dir}/release.archive" -C "${tmp_dir}" 2>/dev/null ;;
    *.tar.bz2)      tar -xjf "${tmp_dir}/release.archive" -C "${tmp_dir}" 2>/dev/null ;;
    *.tar.xz)       tar -xJf "${tmp_dir}/release.archive" -C "${tmp_dir}" 2>/dev/null ;;
  esac

  tool_path="$(find "${tmp_dir}" -name "xeqm-mdb_copy" -type f | head -1)"
  if [[ -n "${tool_path}" ]]; then
    sudo cp "${tool_path}" "${mdb_copy}"
    sudo chmod 755 "${mdb_copy}"
    echo -e "  \033[1;32m[OK]\033[0m xeqm-mdb_copy installed at ${mdb_copy}"
  else
    echo -e "  \033[0;33mWarning: xeqm-mdb_copy not in release archive — migration will use stop-and-copy fallback\033[0m"
  fi

  rm -rf "${tmp_dir}"
}

compile_binary_to_opt() {
  local versioned_bin="$1"
  # Short path: cmake generates absolute paths in Makefiles; every char counts.
  local build_dir="/tmp/xb$$"

  echo -e "\n\033[1mCompiling XEQM from source...\033[0m"

  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo -e "\033[0;31merror\033[0m: Homebrew is required to compile on macOS. Install from https://brew.sh" >&2
      exit 1
    fi
    echo -e "  Installing build dependencies via Homebrew..."
    brew install cmake boost openssl@3 readline zeromq miniupnpc expat libsodium pkg-config gmp unbound binutils 2>/dev/null || true
    local _ossl_root; _ossl_root="$(brew --prefix openssl@3)"
    local _expat_root; _expat_root="$(brew --prefix expat)"
    # macOS BSD ar rejects archive member names > 15 chars (e.g. curlmultiholder.cpp.o).
    # GNU gar (binutils) handles any name length; ld64 can read SYSV archives.
    local _gar; _gar="$(brew --prefix binutils)/bin/gar"
    local _granlib; _granlib="$(brew --prefix binutils)/bin/granlib"
    local _cmake_extra="-DCMAKE_AR=${_gar} -DCMAKE_RANLIB=${_granlib} -DOPENSSL_ROOT_DIR=${_ossl_root} -DBOOST_ROOT=$(brew --prefix boost) -DCMAKE_PREFIX_PATH=${_expat_root};${_ossl_root} -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    local _nproc; _nproc="$(sysctl -n hw.logicalcpu)"
  else
    sudo apt-get -y install build-essential cmake pkg-config libboost-all-dev libssl-dev \
      libzmq3-dev libunbound-dev libsodium-dev libunwind8-dev liblzma-dev libreadline6-dev \
      libldns-dev libexpat1-dev doxygen graphviz libpgm-dev qttools5-dev-tools \
      libhidapi-dev libusb-dev libprotobuf-dev protobuf-compiler
    local _cmake_extra=""
    local _nproc; _nproc="$(nproc)"
  fi

  mkdir -p "${build_dir}"
  local _build_log="${build_dir}/build.log"

  # Use a plain subshell ( ) not $( ) so cmake/make output streams go straight
  # to the terminal (not captured), and we can tee make output to a log file.
  (
    set -euo pipefail
    cd "${build_dir}"
    git clone --recursive "${config[git_repository]}" xeqm-core
    cd xeqm-core
    git submodule init && git submodule update
    git checkout "${config[install_version]}"
    mkdir -p build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release ${_cmake_extra} ..
    echo "  cmake AR: $(grep '^CMAKE_AR:' CMakeCache.txt | cut -d= -f2 || echo unknown)" >&2
    echo "  cmake RANLIB: $(grep '^CMAKE_RANLIB:' CMakeCache.txt | cut -d= -f2 || echo unknown)" >&2
    make -j"${_nproc}" daemon 2>&1 | tee "${_build_log}"
  ) || {
    echo -e "\033[0;31merror\033[0m: compile failed." >&2
    if [[ -f "${_build_log}" ]]; then
      echo "--- build log (last 60 lines) ---" >&2
      tail -60 "${_build_log}" >&2
    fi
    rm -rf "${build_dir}"
    exit 1
  }

  local built_bin
  built_bin="$(find "${build_dir}" -name "xeqm-d" -type f | head -1)"
  if [[ -z "${built_bin}" ]]; then
    echo -e "\033[0;31merror\033[0m: xeqm-d binary not found after compile." >&2
    rm -rf "${build_dir}"
    exit 1
  fi
  ${_SUDO} cp "${built_bin}" "${versioned_bin}"
  ${_SUDO} chmod 755 "${versioned_bin}"
  rm -rf "${build_dir}"
}

write_canonical_plist() {
  local snode_name="$1"
  local p2p="$2"
  local rpc="$3"
  local qnet="$4"
  local public_ip="$5"
  local log_level="${6:-}"
  local data_dir="${XEQM_STATE_BASE}/${snode_name}"
  local label="${XEQM_SVC_LABEL_PREFIX}.${snode_name}"
  local plist_path="${XEQM_SVC_DIR}/${label}.plist"
  local bin="${XEQM_BIN_DIR}/xeqm-d"
  local log_file="${data_dir}/xeqm-d.log"

  mkdir -p "${data_dir}"

  local log_level_arg=""
  [[ -n "${log_level}" ]] && log_level_arg="
		<string>--log-level</string>
		<string>${log_level}</string>"

  cat > "${plist_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${bin}</string>
		<string>--non-interactive</string>
		<string>--data-dir=${data_dir}</string>
		<string>--service-node</string>
		<string>--p2p-bind-ip=0.0.0.0</string>
		<string>--p2p-bind-port=${p2p}</string>
		<string>--rpc-admin=127.0.0.1:${rpc}</string>
		<string>--quorumnet-port=${qnet}</string>
		<string>--service-node-public-ip=${public_ip}</string>
		<string>--seed-node=seeds.xeqmlabs.com:9230</string>
		<string>--add-priority-node=seeds.xeqmlabs.com:9230</string>${log_level_arg}
	</array>
	<key>WorkingDirectory</key>
	<string>${data_dir}</string>
	<key>StandardOutPath</key>
	<string>${log_file}</string>
	<key>StandardErrorPath</key>
	<string>${log_file}</string>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
EOF

  echo -e "  Plist written: ${plist_path}"
}

write_canonical_unit() {
  local snode_name="$1"
  local p2p="$2"
  local rpc="$3"
  local qnet="$4"
  local public_ip="$5"
  local log_level="${6:-}"

  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    write_canonical_plist "${snode_name}" "${p2p}" "${rpc}" "${qnet}" "${public_ip}" "${log_level}"
    return
  fi

  local data_dir="/var/lib/xeqm/${snode_name}"
  local unit_file="/etc/systemd/system/xeqmnode_${snode_name}.service"

  local opt_log_level_arg=""
  [[ -n "${log_level}" ]] && opt_log_level_arg=" --log-level ${log_level}"

  sudo tee "${unit_file}" > /dev/null <<EOF
[Unit]
Description=XEQMLabs Service Node (${snode_name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xeqm
Group=xeqm
StateDirectory=xeqm/${snode_name}
StateDirectoryMode=0700
WorkingDirectory=${data_dir}
ExecStart=/opt/xeqm/bin/xeqm-d --non-interactive --data-dir=${data_dir} --service-node --p2p-bind-ip=0.0.0.0 --p2p-bind-port=${p2p} --rpc-admin=127.0.0.1:${rpc} --quorumnet-port=${qnet} --service-node-public-ip=${public_ip} --seed-node=seeds.xeqmlabs.com:9230 --add-priority-node=seeds.xeqmlabs.com:9230${opt_log_level_arg}
Restart=on-failure
RestartSec=15s
TimeoutStartSec=300s
TimeoutStopSec=60s
LimitNOFILE=65536
NoNewPrivileges=true
ReadWritePaths=${data_dir}
ProtectSystem=strict
PrivateTmp=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

  echo -e "  Unit written: ${unit_file}"
}

download_release_binaries() {
  local version="${config[install_version]}"
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/xeqm-bins-XXXXXX)"
  local api_url="https://api.github.com/repos/XEQMLabs/xeqm-core/releases"

  [[ "${version}" = "auto" ]] && api_url="${api_url}/latest" || api_url="${api_url}/tags/${version}"

  echo -e "\n\033[1mFetching XEQM release information from GitHub...\033[0m" >&2
  local release_info
  release_info="$(wget --quiet -O - "${api_url}" 2>/dev/null)" || {
    echo -e "\033[0;31merror\033[0m: Could not fetch release info. Check network connectivity." >&2
    rm -rf "${tmp_dir}"; exit 1
  }

  local host_arch
  host_arch="$(uname -m)"

  local arch_pattern
  case "${host_arch}" in
    x86_64|amd64) arch_pattern='x86_64|amd64' ;;
    aarch64|arm64) arch_pattern='aarch64|arm64' ;;
    *)             arch_pattern="${host_arch}" ;;
  esac

  # Platform filter: macOS assets are named "macos-*", Linux assets are "linux|ubuntu"
  local os_pattern
  [[ "${OS_TYPE}" == "Darwin" ]] && os_pattern='macos|darwin' || os_pattern='linux|ubuntu'

  _extract_url() {
    local _info="$1"
    echo "${_info}" \
      | grep -o '"browser_download_url": "[^"]*"' \
      | grep -iv '\.sha256' \
      | grep -iE "${os_pattern}" \
      | grep -iE "${arch_pattern}" \
      | head -1 | grep -o 'https://[^"]*'
  }

  local download_url
  download_url="$(_extract_url "${release_info}")"

  # Latest release may not have a macOS build (alphas sometimes skip it).
  # Fall back to scanning all releases for the most recent one with a matching asset.
  if [[ -z "${download_url}" && "${version}" = "auto" ]]; then
    echo -e "  Latest release has no ${OS_TYPE}/${host_arch} binary — scanning older releases..." >&2
    local all_releases
    all_releases="$(wget --quiet -O - "https://api.github.com/repos/XEQMLabs/xeqm-core/releases" 2>/dev/null)" || true
    download_url="$(echo "${all_releases}" \
      | grep -o '"browser_download_url": "[^"]*"' \
      | grep -iv '\.sha256' \
      | grep -iE "${os_pattern}" \
      | grep -iE "${arch_pattern}" \
      | head -1 | grep -o 'https://[^"]*')"
  fi

  if [[ -z "${download_url}" ]]; then
    echo -e "\033[0;31merror\033[0m: No ${OS_TYPE}/${host_arch} binary found in GitHub release assets." >&2
    echo -e "  Available assets:" >&2
    echo "${release_info}" | grep -o '"browser_download_url": "[^"]*"' | grep -o 'https://[^"]*' | sed 's/^/    /' >&2
    echo -e "  Use 'Compile from source' or place a compatible binary at ${XEQM_BIN_DIR}/xeqm-d." >&2
    rm -rf "${tmp_dir}"; exit 1
  fi

  # Derive the .sha256 sidecar URL (same name + .sha256)
  local sha256_url="${download_url}.sha256"

  echo -e "  Downloading: ${download_url##*/}" >&2
  wget --progress=bar:force:noscroll -O "${tmp_dir}/release.archive" "${download_url}" || {
    echo -e "\033[0;31merror\033[0m: Download failed." >&2
    rm -rf "${tmp_dir}"; exit 1
  }

  # Verify SHA256 if the sidecar is available
  echo -e "  Verifying SHA256..." >&2
  local expected_sha256
  expected_sha256="$(wget --quiet -O - "${sha256_url}" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${expected_sha256}" ]]; then
    local actual_sha256
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
      actual_sha256="$(shasum -a 256 "${tmp_dir}/release.archive" | awk '{print $1}')"
    else
      actual_sha256="$(sha256sum "${tmp_dir}/release.archive" | awk '{print $1}')"
    fi
    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
      echo -e "\033[0;31merror\033[0m: SHA256 mismatch — archive may be corrupted or tampered with." >&2
      echo -e "  Expected: ${expected_sha256}" >&2
      echo -e "  Got:      ${actual_sha256}" >&2
      rm -rf "${tmp_dir}"; exit 1
    fi
    echo -e "  \033[1;32mSHA256 OK\033[0m  (${actual_sha256:0:16}...)" >&2
  else
    echo -e "  \033[0;33mWarning:\033[0m No SHA256 sidecar found — skipping integrity check." >&2
  fi

  echo -e "\n\033[1mExtracting binaries...\033[0m" >&2
  case "${download_url}" in
    *.tar.gz|*.tgz) tar -xzf "${tmp_dir}/release.archive" -C "${tmp_dir}" ;;
    *.tar.bz2)      tar -xjf "${tmp_dir}/release.archive" -C "${tmp_dir}" ;;
    *.tar.xz)       tar -xJf "${tmp_dir}/release.archive" -C "${tmp_dir}" ;;
    *.zip)          unzip -q "${tmp_dir}/release.archive" -d "${tmp_dir}" ;;
    *)              echo -e "\033[0;31merror\033[0m: Unknown archive format." >&2; rm -rf "${tmp_dir}"; exit 1 ;;
  esac
  rm -f "${tmp_dir}/release.archive"

  local daemon_path
  daemon_path="$(find "${tmp_dir}" -name "xeqm-d" -type f | head -1)"
  if [[ -z "${daemon_path}" ]]; then
    echo -e "\033[0;31merror\033[0m: xeqm-d binary not found in downloaded release." >&2
    rm -rf "${tmp_dir}"; exit 1
  fi

  local bin_dir
  bin_dir="$(dirname "${daemon_path}")"
  chmod +x "${bin_dir}"/*
  echo "${bin_dir}"
}

prompt_one_passwd_file() {
  if [[ -f "${script_basedir}/.onepasswd" ]]; then
    echo -e "\n\033[1mShared password file detected — all new users will use the existing password.\033[0m"
    return 0
  fi

  local yn
  while true; do
    read -rp $'\n\033[1mSet a shared password for all service node users?\e[0m (recommended for multi-node installs) [Y/n]: ' yn
    yn="${yn:-Y}"
    case "${yn}" in
      [Yy]*) one_password_file_option_handler; break ;;
      [Nn]*)
        echo -e "\n  You can set this up later by running:"
        echo -e "    bash install.sh --one-passwd-file"
        break ;;
      *) echo -e "  \033[0;33mPlease answer Y or N\033[0m" ;;
    esac
  done
}

one_password_file_option_handler() {
  echo -e "\n\033[1mSet one password for all new service node users. Will be stored encrypted!\033[0m"
  while true; do read -sp $'\rPassword: ' pwd; read -sp $'\rRe-passwd: ' re_pwd; [[ "${pwd}" = "${re_pwd}" ]] && echo "${pwd}" && break; done | openssl passwd -6 -stdin > "${script_basedir}/.onepasswd"

  if [[ -f "${script_basedir}/.onepasswd" ]]; then
    echo -e "\n\nsucces: .onepasswd file created. Remove this file to enable manual password input again."
  else
    echo -e "\n\nerror: .onepasswd file could not be created"
  fi
}

print_splash_screen() {
  local subtitle="${1:-Service Node Installer}"
  local ver="${2:-${xeqmnode_installer_version}}"
  local inner="XEQM Labs  ·  ${subtitle}  ·  ${ver}"
  local inner_len=${#inner}
  local box_inner_width=54
  local pad_left=$(( (box_inner_width - inner_len) / 2 ))
  local pad_right=$(( box_inner_width - inner_len - pad_left ))
  local border
  border="$(printf '═%.0s' $(seq 1 ${box_inner_width}))"
  echo ""
  echo -e "\033[1;36m  ╔${border}╗\033[0m"
  echo -e "\033[1;36m  ║\033[0m$(printf ' %.0s' $(seq 1 ${box_inner_width}))\033[1;36m║\033[0m"
  printf "\033[1;36m  ║\033[0m%*s\033[1m%s\033[0m%*s\033[1;36m║\033[0m\n" \
    "${pad_left}" "" "${inner}" "${pad_right}" ""
  echo -e "\033[1;36m  ║\033[0m$(printf ' %.0s' $(seq 1 ${box_inner_width}))\033[1;36m║\033[0m"
  echo -e "\033[1;36m  ╚${border}╝\033[0m"
  echo ""
}

# ── Whiptail wizard helpers ──────────────────────────────────────────────────
# All wt_* functions: 0=OK/Next  non-0=Back/Cancel

wt_available() {
  command -v whiptail >/dev/null 2>&1
}

# wt_menu <title> <body> <h> <w> <list-h> <nameref-result> tag1 item1 [tag2 item2 ...]
wt_menu() {
  local _wm_title="$1" _wm_body="$2" _wm_h="$3" _wm_w="$4" _wm_lh="$5"
  local -n _wm_result="$6"
  shift 6
  local _wm_choice
  _wm_choice="$(whiptail --title "${_wm_title}" --cancel-button "Back" \
    --menu "${_wm_body}" "${_wm_h}" "${_wm_w}" "${_wm_lh}" "$@" 3>&1 1>&2 2>&3)"
  local _wm_rc=$?
  [[ ${_wm_rc} -eq 0 ]] && _wm_result="${_wm_choice}"
  return ${_wm_rc}
}

# wt_inputbox <title> <body> <h> <w> <nameref-result> [default]
wt_inputbox() {
  local _wi_title="$1" _wi_body="$2" _wi_h="$3" _wi_w="$4"
  local -n _wi_result="$5"
  local _wi_default="${6:-}"
  local _wi_val
  _wi_val="$(whiptail --title "${_wi_title}" --cancel-button "Back" \
    --inputbox "${_wi_body}" "${_wi_h}" "${_wi_w}" "${_wi_default}" 3>&1 1>&2 2>&3)"
  local _wi_rc=$?
  [[ ${_wi_rc} -eq 0 ]] && _wi_result="${_wi_val}"
  return ${_wi_rc}
}

# wt_yesno <title> <body> <h> <w> [yes-label] [no-label]  → 0=Yes 1=No/Back
wt_yesno() {
  local _wy_yes="${5:-Yes}" _wy_no="${6:-No}"
  whiptail --title "$1" --yes-button "${_wy_yes}" --no-button "${_wy_no}" \
    --yesno "$2" "$3" "$4"
}

# wt_msgbox <title> <body> <h> <w>
wt_msgbox() {
  whiptail --title "$1" --msgbox "$2" "$3" "$4"
}

# wt_scrolltext <title> <text> <h> <w>  → 0=OK 1=Back(Esc)
# Uses --msgbox so Enter always confirms — --yesno+--scrolltext consumes Enter for scrolling
wt_scrolltext() {
  local _rc
  whiptail --title "$1" --ok-button "OK" --scrolltext --msgbox "$2" "$3" "$4"
  _rc=$?
  [[ "${_rc}" -eq 255 ]] && return 1   # Esc = Back
  return "${_rc}"
}

# ── Dependency installer ──────────────────────────────────────────────────────
install_dependencies() {
  if [[ "${OS_TYPE}" == "Darwin" ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo -e "\n\033[0;31merror\033[0m: Homebrew is required. Install from https://brew.sh" >&2
      exit 1
    fi
    local _missing=()
    command -v openssl  >/dev/null 2>&1 || _missing+=(openssl)
    command -v rsync    >/dev/null 2>&1 || _missing+=(rsync)
    command -v wget     >/dev/null 2>&1 || _missing+=(wget)
    # newt provides whiptail; grep provides GNU grep with -P/PCRE support
    command -v whiptail >/dev/null 2>&1 || _missing+=(newt)
    # BSD grep lacks -P (PCRE); install GNU grep which the scripts use heavily
    grep -P '' /dev/null 2>/dev/null || _missing+=(grep)
    # BSD getopt lacks --long; install GNU getopt (gnu-getopt formula)
    getopt --test 2>/dev/null; [[ $? -ne 4 ]] && _missing+=(gnu-getopt)
    if [[ ${#_missing[@]} -gt 0 ]]; then
      echo -e "\n\033[1mInstalling missing dependencies via Homebrew: ${_missing[*]}\033[0m"
      HOMEBREW_NO_REQUIRE_TAP_TRUST=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        brew install --quiet "${_missing[@]}" <<< "y"
    fi
    # Add GNU tools to front of PATH immediately after install
    local _hb; _hb="$(brew --prefix)/opt"
    [[ -d "${_hb}/grep/libexec/gnubin"      ]] && export PATH="${_hb}/grep/libexec/gnubin:${PATH}"
    [[ -d "${_hb}/gnu-getopt/bin"            ]] && export PATH="${_hb}/gnu-getopt/bin:${PATH}"
    return 0
  fi

  if ! [[ -x "$(command -v ss)" && -x "$(command -v openssl)" && -x "$(command -v natsort)" && \
          -x "$(command -v grep)" && -x "$(command -v getopt)" && -x "$(command -v gawk)" && \
          -x "$(command -v whiptail)" && -x "$(command -v rsync)" ]]; then
    echo -e "\n\033[1mFixing required dependencies....\033[0m"
    sudo apt -y install iproute2 openssl python3-natsort grep util-linux gawk whiptail rsync
  fi
}

# ── Bootstrap download (cached) ───────────────────────────────────────────────
_BOOTSTRAP_CACHE="/tmp/xeqm-bootstrap-cache.tar.gz"

# download_bootstrap <target_dir> <username>
# Downloads (or reuses cache of) the XEQM bootstrap archive and extracts it.
download_bootstrap() {
  local target_dir="$1"
  local username="$2"
  local bootstrap_url="https://bootstrap.xeqmlabs.com/lmdb.tar.gz"

  local _need_download=1

  if [[ -f "${_BOOTSTRAP_CACHE}" ]]; then
    echo -e "\n\033[1mChecking bootstrap freshness...\033[0m"
    local _remote_date _remote_epoch _local_epoch
    _remote_date="$(wget --server-response --spider "${bootstrap_url}" 2>&1 \
      | grep -i 'Last-Modified:' | tail -1 | sed 's/.*Last-Modified: //' | tr -d '\r')" || true
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
      _local_epoch="$(stat -f %m "${_BOOTSTRAP_CACHE}" 2>/dev/null || echo 0)"
    else
      _local_epoch="$(stat -c %Y "${_BOOTSTRAP_CACHE}" 2>/dev/null || echo 0)"
    fi

    if [[ -n "${_remote_date}" ]]; then
      if [[ "${OS_TYPE}" == "Darwin" ]]; then
        _remote_epoch="$(date -j -f "%a, %d %b %Y %T %Z" "${_remote_date}" +%s 2>/dev/null || echo 0)"
      else
        _remote_epoch="$(date -d "${_remote_date}" +%s 2>/dev/null || echo 0)"
      fi
      if [[ "${_local_epoch}" -ge "${_remote_epoch}" ]]; then
        echo -e "  \033[1;32mCached bootstrap is current\033[0m (server: ${_remote_date})"
        _need_download=0
      else
        echo -e "  Newer bootstrap available (server: ${_remote_date}) — re-downloading..."
      fi
    else
      local _age=$(( $(date +%s) - _local_epoch ))
      if [[ "${_age}" -lt 86400 ]]; then
        echo -e "  \033[1;33mCould not check server — using cached file ($(( _age / 3600 ))h old)\033[0m"
        _need_download=0
      else
        echo -e "  Cached file is >24h old and server unreachable — re-downloading..."
      fi
    fi
  fi

  if [[ "${_need_download}" -eq 1 ]]; then
    echo -e "\n\033[1mDownloading XEQM bootstrap blockchain...\033[0m"
    echo -e "  Source: ${bootstrap_url}\n"
    wget --progress=bar:force:noscroll -O "${_BOOTSTRAP_CACHE}" "${bootstrap_url}"
  fi

  echo -e "\n\033[1mExtracting bootstrap to '${target_dir}'...\033[0m"

  if [[ -d "${target_dir}/lmdb" ]]; then
    local _suffix; _suffix="$(printf '%08x' $RANDOM)"
    ${_SUDO} mv "${target_dir}/lmdb" "${target_dir}/lmdb_${_suffix}"
  fi
  ${_SUDO} mkdir -p "${target_dir}"
  ${_SUDO} tar -xzf "${_BOOTSTRAP_CACHE}" -C "${target_dir}"
  [[ -n "${username}" && "${OS_TYPE}" != "Darwin" ]] && ${_SUDO} chown -R "${username}:${username}" "${target_dir}"

  echo -e "\033[1;32mBootstrap extracted successfully.\033[0m"
}
