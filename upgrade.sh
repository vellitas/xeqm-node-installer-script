#!/usr/bin/env bash
# by Mister R

set -o errexit
set -o nounset
set -o pipefail

upgrade_session_token="$(echo $RANDOM | md5sum | head -c 8)"
readonly upgrade_session_token

: "${script_basedir:=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")}"

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

typeset -A command_options_set
command_options_set=(
  [help]=0
  [user]=0
  [version]=0
  [delete_key_file]=0
  [delete_p2pstate_file]=0
  [daemon_no_fluffy_blocks]=0
  [daemon_log_level]=0
  [git_repository]=0
  [open_firewall]=0
)
user_option_value=
version_option_value=
daemon_log_level_option_value=
git_repository_option_value=

declare -A system_info

upgrade_run() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Service Node Upgrade" "${xeqmnode_installer_version}"
  discover_system system_info
  process_command_line_args "$@"

  pre_install_checks
  upgrade_manager
}

process_command_line_args() {
  parse_command_line_args "$@"
  validate_parsed_command_line_args
  set_config_and_execute_info_commands
}

parse_command_line_args() {
  args="$(getopt -a -n installer -o "hv:u:" --long help,set-daemon-no-fluffy-blocks,set-daemon-log-level:,delete-key-file,delete-p2pstate-file,version:,user:,git-repository:,open-firewall -- "$@")"
  eval set -- "${args}"

  while :
  do
    case "$1" in
      -h | --help)                    command_options_set[help]=1 ; shift ;;
      -u | --user)                    command_options_set[user]=1; user_option_value="$2"; shift 2 ;;
      -v | --version)                 command_options_set[version]=1; version_option_value="$2"; shift 2 ;;
      --delete-key-file)              command_options_set[delete_key_file]=1; shift ;;
      --delete-p2pstate-file)         command_options_set[delete_p2pstate_file]=1; shift ;;
      --set-daemon-no-fluffy-blocks)  command_options_set[daemon_no_fluffy_blocks]=1; shift ;;
      --set-daemon-log-level)         command_options_set[daemon_log_level]=1; daemon_log_level_option_value="$2"; shift 2 ;;
      --git-repository)               command_options_set[git_repository]=1; git_repository_option_value="$2"; shift 2 ;;
      --open-firewall)                command_options_set[open_firewall]=1; shift ;;
      --)                             shift ; break ;;
      *)                              echo "Unexpected option: $1" ;
                                      upgrade_usage
                                      exit 0 ;;
    esac
  done
}

set_config_and_execute_info_commands() {
  [[ "${command_options_set[help]}" -eq 1 ]] && upgrade_usage && exit 0

  if [[ "${command_options_set[daemon_no_fluffy_blocks]}" -eq 1 ]]; then config[daemon_no_fluffy_blocks]=1; fi

  if [[ "${command_options_set[version]}" -eq 1 ]]; then version_option_handler "${version_option_value}"; else version_option_handler "auto"; fi
  if [[ "${command_options_set[user]}" -eq 1 ]]; then user_option_handler "${user_option_value}"; else user_option_handler "auto"; fi
  if [[ "${command_options_set[daemon_log_level]}" -eq 1 ]]; then daemon_log_level_option_handler "${daemon_log_level_option_value}"; fi
  if [[ "${command_options_set[git_repository]}" -eq 1 ]]; then git_repository_option_handler "${git_repository_option_value}"; fi
  if [[ "${command_options_set[open_firewall]}" -eq 1 ]]; then config[open_firewall]=1; fi

  return 0
}

validate_parsed_command_line_args() {
  local valid_option_combinations=(
    "user version delete_key_file delete_p2pstate_file daemon_no_fluffy_blocks daemon_log_level git_repository open_firewall"
    "help"
  )
  validate_command_line_option_combinations valid_option_combinations
}

detect_layout() {
  local has_canonical=0 has_installer=0
  while IFS= read -r unit_file; do
    if grep -q '^User=xeqm$' "${unit_file}" 2>/dev/null; then
      has_canonical=1
    else
      has_installer=1
    fi
  done < <(find /etc/systemd/system -maxdepth 1 -name 'xeqmnode_snode*.service' 2>/dev/null)
  if getent passwd | awk -F: '$6 ~ /^\/home\/snode/' | grep -q .; then
    has_installer=1
  fi
  if [[ "${has_canonical}" -eq 1 && "${has_installer}" -eq 1 ]]; then
    echo "mixed"
  elif [[ "${has_canonical}" -eq 1 ]]; then
    echo "canonical"
  elif [[ "${has_installer}" -eq 1 ]]; then
    echo "installer"
  else
    echo "none"
  fi
}

user_option_handler() {
  if [[ "$1" = "auto" ]]; then
    local layout
    layout="$(detect_layout)"

    if [[ "${layout}" = "canonical" || "${layout}" = "mixed" ]]; then
      user_option_value="__canonical__"
      local -a _installer_users=()
      while IFS= read -r _u; do
        [[ -n "${_u}" ]] && _installer_users+=("${_u}")
      done < <(getent passwd | awk -F: '$6 ~ /^\/home\/snode/ { print $1 }' | sort)
      if [[ "${#_installer_users[@]}" -gt 0 ]]; then
        user_option_value="__canonical__,$(IFS=,; echo "${_installer_users[*]}")"
      fi
      return 0
    fi

    local -a _auto_users=()
    while IFS= read -r _u; do
      [[ -n "${_u}" ]] && _auto_users+=("${_u}")
    done < <(getent passwd | awk -F: '$6 ~ /^\/home\/snode/ { print $1 }' | sort)
    if [[ "${#_auto_users[@]}" -eq 0 ]]; then
      echo -e "\n\033[0;33merror: No snode* users or canonical units found. Use --user to specify usernames explicitly.\033[0m\n"
      upgrade_usage
      exit 1
    fi
    user_option_value="$(IFS=,; echo "${_auto_users[*]}")"
    echo -e "\n  Auto-discovered users: ${user_option_value}"
  elif validate_manual_user_string_format "$1"; then
    echo -e "\nBasic user string validation passed"
  else
    echo -e "\n\033[0;33merror: Invalid --user value '$1'\033[0m\n"
    upgrade_usage
    exit 1
  fi
}

upgrade_manager() {
  local layout
  layout="$(detect_layout)"

  echo -e "\n  Layout detected: \033[1m${layout}\033[0m"

  if [[ "${layout}" = "canonical" || "${layout}" = "mixed" ]]; then
    upgrade_canonical_nodes
  fi

  if [[ "${layout}" = "installer" || "${layout}" = "mixed" ]]; then
    upgrade_installer_nodes
  fi

  if [[ "${layout}" = "none" ]]; then
    echo -e "\n\033[0;33merror: No XEQM service nodes found on this server.\033[0m\n"
    exit 1
  fi

  rm -rf /tmp/xeqm-bins-* 2>/dev/null || true
  echo -e "\n\033[1;32mUpgrade complete.\033[0m\n"
  [[ "${XEQM_FROM_MENU:-0}" = "1" ]] && read -rp $'  Press Enter to return to the menu...' _
}

upgrade_canonical_nodes() {
  local -a canonical_units=()
  while IFS= read -r u; do
    [[ -n "${u}" ]] && canonical_units+=("${u}")
  done < <(find /etc/systemd/system -maxdepth 1 -name 'xeqmnode_snode*.service' \
    -exec grep -l '^User=xeqm$' {} \; 2>/dev/null | sort)

  if [[ "${#canonical_units[@]}" -eq 0 ]]; then
    return 0
  fi

  local installed_ver=""
  if [[ -x "/opt/xeqm/bin/xeqm-d" ]]; then
    installed_ver="$(/opt/xeqm/bin/xeqm-d --version 2>/dev/null \
      | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi

  local latest_ver=""
  latest_ver="$(echo "${config[install_version]}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)"

  echo ""
  [[ -n "${installed_ver}" ]] && echo -e "  Installed: \033[1m${installed_ver}\033[0m" || echo -e "  Installed: \033[0;33munknown\033[0m"
  [[ -n "${latest_ver}" ]] && echo -e "  Latest:    \033[1m${latest_ver}\033[0m"

  if [[ -n "${installed_ver}" && -n "${latest_ver}" && "${installed_ver}" = "${latest_ver}" ]]; then
    echo -e "\n  \033[0;32mCanonical nodes already up to date.\033[0m"
    if wt_available; then
      if ! wt_yesno "Already Up To Date" \
        "Installed version ${installed_ver} matches the latest release.\n\nDownload and reinstall anyway?" \
        10 62 "Reinstall" "Skip"; then
        echo -e "  Skipping canonical upgrade.\n"; return 0
      fi
    else
      local _yn
      read -rp $'\n\033[1mAlready up to date. Reinstall anyway?\e[0m [y/N]: ' _yn
      [[ "${_yn,,}" != "y" ]] && { echo -e "  Skipping.\n"; return 0; }
    fi
  fi

  echo -e "\n\033[1mDownloading latest XEQM binary from GitHub...\033[0m"
  local bin_dir
  bin_dir="$(download_release_binaries)"

  local new_version=""
  new_version="$("${bin_dir}/xeqm-d" --version 2>/dev/null | head -1 || true)"
  [[ -n "${new_version}" ]] && echo -e "  Downloaded: ${new_version}"

  local version="${config[install_version]}"
  local versioned_bin="/opt/xeqm/bin/xeqm-d-${version}"
  sudo mkdir -p /opt/xeqm/bin
  sudo cp "${bin_dir}/xeqm-d" "${versioned_bin}"
  sudo chmod 755 "${versioned_bin}"
  sudo ln -sf "${versioned_bin}" /opt/xeqm/bin/xeqm-d
  echo -e "  \033[1;32mBinary updated:\033[0m /opt/xeqm/bin/xeqm-d -> ${versioned_bin}"
  local _bin _bname
  for _bin in "${bin_dir}"/*; do
    [[ -f "${_bin}" && -x "${_bin}" ]] || continue
    _bname="$(basename "${_bin}")"
    [[ "${_bname}" = "xeqm-d" ]] && continue
    sudo cp "${_bin}" "/opt/xeqm/bin/${_bname}"
    sudo chmod 755 "/opt/xeqm/bin/${_bname}"
    echo -e "  \033[1;32mInstalled:\033[0m /opt/xeqm/bin/${_bname}"
  done

  echo -e "\n\033[1mRestarting canonical service nodes...\033[0m"
  for unit_file in "${canonical_units[@]}"; do
    local unit_name
    unit_name="$(basename "${unit_file}")"
    tput rev 2>/dev/null || true; echo -e "\n\033[1m ${unit_name} \033[0m"; tput sgr0 2>/dev/null || true
    sudo systemctl stop "${unit_name}" || true
    sleep 2
    sudo systemctl start "${unit_name}"
    echo -e "  \033[1;32mRestarted\033[0m ${unit_name}"
  done

  sudo systemctl daemon-reload
}

upgrade_installer_nodes() {
  local usernames_str="${user_option_value}"
  usernames_str="${usernames_str/__canonical__,/}"
  usernames_str="${usernames_str/__canonical__/}"
  [[ -z "${usernames_str}" ]] && return 0

  local -a usernames
  IFS=',' read -ra usernames <<< "${usernames_str}"

  local first_user="${usernames[0]}"
  local installed_ver=""
  if [[ -x "/home/${first_user}/bin/xeqm-d" ]]; then
    installed_ver="$(/home/${first_user}/bin/xeqm-d --version 2>/dev/null \
      | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi

  local latest_ver=""
  latest_ver="$(echo "${config[install_version]}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)"

  echo ""
  [[ -n "${installed_ver}" ]] && echo -e "  Installed (installer layout): \033[1m${installed_ver}\033[0m" || echo -e "  Installed: \033[0;33munknown\033[0m"
  [[ -n "${latest_ver}" ]] && echo -e "  Latest:    \033[1m${latest_ver}\033[0m"

  if [[ -n "${installed_ver}" && -n "${latest_ver}" && "${installed_ver}" = "${latest_ver}" ]]; then
    echo -e "\n  \033[0;32mInstaller-layout nodes already up to date.\033[0m"
    if wt_available; then
      if ! wt_yesno "Already Up To Date" \
        "Installed version ${installed_ver} matches the latest release.\n\nDownload and reinstall anyway?" \
        10 62 "Reinstall" "Skip"; then
        echo -e "  Skipping installer-layout upgrade.\n"; return 0
      fi
    else
      local _yn
      read -rp $'\n\033[1mReinstall anyway?\e[0m [y/N]: ' _yn
      [[ "${_yn,,}" != "y" ]] && return 0
    fi
  fi

  echo -e "\n\033[1mDownloading latest XEQM binary from GitHub...\033[0m"
  local bin_dir
  bin_dir="$(download_release_binaries)"

  local new_version=""
  new_version="$("${bin_dir}/xeqm-d" --version 2>/dev/null | head -1 || true)"
  [[ -n "${new_version}" ]] && echo -e "  Downloaded: ${new_version}"

  for username in "${usernames[@]}"; do
    tput rev 2>/dev/null || true; echo -e "\n\033[1m ${username} \033[0m"; tput sgr0 2>/dev/null || true
    if ! id -u "${username}" >/dev/null 2>&1; then
      echo -e "\033[0;33merror: Invalid username '${username}'. Skipping!\033[0m\n"
      continue
    fi

    local cur_version=""
    cur_version="$(/home/${username}/bin/xeqm-d --version 2>/dev/null | head -1 || true)"
    [[ -n "${cur_version}" ]] && echo -e "  Current: ${cur_version}"

    upgrade_installer_in_installer_home "/home/${username}/xeqm-installer" "${username}"

    sudo -H -u "${username}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop' || true

    local target_dir="/home/${username}/bin"
    copy_binaries_to_directory "${bin_dir}" "${target_dir}"
    sudo chown -R "${username}:${username}" "${target_dir}"

    sudo -H -u "${username}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh setup_service'
    sudo -H -u "${username}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'

    if [[ "${config[open_firewall]:-0}" -eq 1 ]]; then
      sudo -H -u "${username}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh open_firewall'
    fi
    if [[ "${command_options_set[delete_key_file]}" -eq 1 ]]; then
      delete_key_file_handler "${username}"
    fi
    if [[ "${command_options_set[delete_p2pstate_file]}" -eq 1 ]]; then
      delete_p2pstate_file_handler "${username}"
    fi
  done
}

update_install_config() {
  local install_config_file_path="$1"
  declare -A node_config

  if [[ -f "${install_config_file_path}" ]]; then
    load_config "${install_config_file_path}" node_config
    node_config[install_version]="${config[install_version]}"
    node_config[daemon_log_level]="${config[daemon_log_level]}"
    node_config[daemon_no_fluffy_blocks]="${config[daemon_no_fluffy_blocks]}"
    node_config[git_repository]="${config[git_repository]}"
    node_config[open_firewall]="${config[open_firewall]}"
  fi

  echo -e "\n\033[1mUpdating install.conf in '${install_config_file_path}'...\033[0m"
  write_config node_config "${install_config_file_path}"
}

delete_key_file_handler() {
  local username="$1"
  local data_dir="/home/${username}/.xeqmlabs"

  for _kf in key_bls key_ed25519; do
    if [[ -f "${data_dir}/${_kf}" ]]; then
      echo -e "Removing file '${data_dir}/${_kf}'..."
      sudo mv "${data_dir}/${_kf}" ./"${upgrade_session_token}-${username}--${_kf}"
    fi
  done
}

delete_p2pstate_file_handler() {
  local username="$1"
  local p2pstate_file_path="/home/${username}/.xeqmlabs/p2pstate.bin"

  if [[ -f "${p2pstate_file_path}" ]]; then
    echo -e "Removing file '${p2pstate_file_path}'..."
    sudo mv "${p2pstate_file_path}" ./"${upgrade_session_token}-${username}--p2pstate.bin"
  fi
}

backup_key_before_upgrade() {
  local username="$1"
  local data_dir="/home/${username}/.xeqmlabs"
  local timestamp
  timestamp="$(date +%Y%m%d%H%M%S)"

  for _kf in key_bls key_ed25519; do
    if [[ -f "${data_dir}/${_kf}" ]]; then
      local backup="${data_dir}/${_kf}.bak.${timestamp}"
      sudo cp "${data_dir}/${_kf}" "${backup}"
      echo -e "  Key backed up to: ${backup}"
    fi
  done
}

upgrade_installer_in_installer_home() {
  local installer_home="$1"
  local username="$2"

  echo -e "\n\033[1mBacking up service node key for '${username}'...\033[0m"
  backup_key_before_upgrade "${username}"

  echo -e "\n\033[1mUpdating installer in '${installer_home}'...\033[0m"
  sudo cp -f xeqm-node.sh xeqmnode.service.template common.sh "${installer_home}"

  update_install_config "${installer_home}/install.conf"

  sudo chown -R "${username}":root "${installer_home}"
}

upgrade_usage() {
  cat <<USAGEMSG

bash $0 [OPTIONS...]

Options:
  -u --user [name,...]                  Set username(s) to upgrade (installer layout only).
                                        Canonical layout nodes are discovered automatically.

                                        Examples:   --user snode2
                                                    --user snode,snode2

  -v --version [auto|[version/hash]]    Set XEQM version tag with format 'v0.0.0'
                                        or 'master' or git hash. Use 'auto' to upgrade
                                        to the latest version tag.

                                        Examples:   --version auto
                                                    --version master
                                                    --version v20.0.0
                                                    --version 122d5f6a6

  --set-daemon-log-level                Add --log-level parameter to daemon command in
                                        service file.

                                        Example:   --set-daemon-log-level 0,stacktrace:FATAL

  --delete-key-file                     Removes the '.xeqmlabs/key_bls' and '.xeqmlabs/key_ed25519' files.
                                        (installer layout only)

                                        WARNING: Only use this option when the service
                                        node is deregistered!

  --delete-p2pstate-file                Removes the '.xeqmlabs/p2pstate.bin' file.
                                        (installer layout only)

  --open-firewall                       Open firewall for p2p in/out ports. Default: no.

  -h  --help                            Show this help text

USAGEMSG
}

upgrade_finally() {
  result=$?
  echo ""
  exit ${result}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap upgrade_finally EXIT ERR INT
  upgrade_run "${@}"
fi
