#!/usr/bin/env bash
# wipe.sh — Remove XEQM service node installs

set -euo pipefail

: "${script_basedir:=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")}"

source "${script_basedir}/common.sh"

wipe_version='v3.0'

wipe_node() {
  local user="$1"
  local service="xeqmnode_${user}.service"
  local service_file="/etc/systemd/system/${service}"
  local sudoers_file="/etc/sudoers.d/xeqmnode-${user}"

  echo -e "\n  \033[1;33mWiping installer-layout node: ${user}\033[0m"

  if systemctl is-active --quiet "${service}" 2>/dev/null; then
    echo "    stopping ${service}..."
    sudo systemctl stop "${service}"
  fi
  if systemctl is-enabled --quiet "${service}" 2>/dev/null; then
    sudo systemctl disable "${service}" 2>/dev/null || true
  fi

  if [[ -f "${service_file}" ]]; then
    echo "    removing ${service_file}"
    sudo rm -f "${service_file}"
  fi

  local pids
  pids="$(sudo pgrep -u "${user}" xeqm-d 2>/dev/null || true)"
  if [[ -n "${pids}" ]]; then
    echo "    killing remaining xeqm-d pids: ${pids}"
    # shellcheck disable=SC2086
    sudo kill ${pids} 2>/dev/null || true
    sleep 2
    # shellcheck disable=SC2086
    sudo kill -9 ${pids} 2>/dev/null || true
  fi

  [[ -f "${sudoers_file}" ]] && sudo rm -f "${sudoers_file}" && echo "    removed ${sudoers_file}"

  if id -u "${user}" >/dev/null 2>&1; then
    echo "    deleting user ${user} and /home/${user}"
    sudo userdel -rf "${user}" 2>/dev/null || sudo userdel -f "${user}" 2>/dev/null || true
    [[ -d "/home/${user}" ]] && sudo rm -rf "/home/${user}"
  else
    echo "    user ${user} not found, skipping"
  fi

  echo -e "  \033[1;32m[done]\033[0m ${user}"
}

wipe_canonical_node() {
  local snode_name="$1"
  local service="xeqmnode_${snode_name}.service"
  local service_file="/etc/systemd/system/${service}"
  local data_dir="/var/lib/xeqm/${snode_name}"

  echo -e "\n  \033[1;33mWiping canonical node: ${snode_name}\033[0m"

  if systemctl is-active --quiet "${service}" 2>/dev/null; then
    echo "    stopping ${service}..."
    sudo systemctl stop "${service}"
  fi
  if systemctl is-enabled --quiet "${service}" 2>/dev/null; then
    sudo systemctl disable "${service}" 2>/dev/null || true
  fi

  if [[ -f "${service_file}" ]]; then
    echo "    removing ${service_file}"
    sudo rm -f "${service_file}"
  fi

  if [[ -d "${data_dir}" ]]; then
    echo "    removing ${data_dir}"
    sudo rm -rf "${data_dir}"
  fi

  echo -e "  \033[1;32m[done]\033[0m ${snode_name}"
}

discover_snode_users() {
  local -n _dsu_result="$1"
  _dsu_result=()
  local u
  while IFS= read -r u; do
    _dsu_result+=("${u}")
  done < <(getent passwd | awk -F: '$6 ~ /^\/home\/snode/ { print $1 }' | sort)
}

discover_canonical_snodes() {
  local -n _dcs_result="$1"
  _dcs_result=()
  local f
  while IFS= read -r f; do
    if grep -q '^User=xeqm$' "${f}" 2>/dev/null; then
      local sname
      sname="$(basename "${f}" .service)"
      sname="${sname#xeqmnode_}"
      _dcs_result+=("${sname}")
    fi
  done < <(find /etc/systemd/system -maxdepth 1 -name 'xeqmnode_snode*.service' 2>/dev/null | sort)
}

wipe_usage() {
  cat <<USAGEMSG

bash $0

  Interactively remove XEQM service node installs from this server.
  Supports both installer-layout (per-user) and canonical-layout nodes.

  WARNING: This permanently destroys keys and blockchain data.
  Export keys first with transfer.sh --export if the node is still registered.

USAGEMSG
}

wipe_run() {
  for arg in "$@"; do
    case "${arg}" in
      -h|--help) wipe_usage; exit 0 ;;
    esac
  done

  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Service Node Wipe" "${wipe_version}"

  local -a found_users=()
  discover_snode_users found_users

  local -a found_canonical=()
  discover_canonical_snodes found_canonical

  if [[ "${#found_users[@]}" -eq 0 && "${#found_canonical[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo service nodes found on this server — nothing to wipe.\033[0m\n"
    exit 0
  fi

  local warn_body
  warn_body="This permanently deletes all data for the selected nodes:\n\n"
  warn_body+="  \xe2\x80\xa2 Service node keys are destroyed\n"
  warn_body+="  \xe2\x80\xa2 Blockchain data is removed\n"
  warn_body+="  \xe2\x80\xa2 Installer-layout: user account and home directory deleted\n"
  warn_body+="  \xe2\x80\xa2 Canonical layout: /var/lib/xeqm/snodeN removed\n\n"
  warn_body+="If a node is REGISTERED on the network, migrate it first\n"
  warn_body+="using server-migrate.sh to preserve rewards and avoid lockout.\n\n"
  warn_body+="This operation CANNOT be undone."

  if wt_available; then
    whiptail --title "WARNING — Destructive Operation" \
      --yes-button "I understand — continue" \
      --no-button "Cancel" \
      --yesno "${warn_body}" 20 66
    local _wt_rc=$?
    if [[ "${_wt_rc}" -ne 0 ]]; then echo -e "\nAborted."; exit 0; fi
  else
    echo -e "\n\033[1;31m=== WARNING: DESTRUCTIVE OPERATION ===\033[0m"
    printf '%b\n' "${warn_body}" | sed 's/^/  /'
    echo ""
    read -rp $'\033[1mType YES to continue, anything else to abort:\e[0m ' _ack
    [[ "${_ack}" != "YES" ]] && { echo -e "\nAborted."; exit 0; }
  fi

  # Build combined node list with layout tags
  local -a all_nodes=()
  for u in "${found_users[@]}"; do all_nodes+=("installer:${u}"); done
  for s in "${found_canonical[@]}"; do all_nodes+=("canonical:${s}"); done

  local -a target_nodes=()

  if wt_available; then
    local -a checklist_args=()
    for entry in "${all_nodes[@]}"; do
      local layout="${entry%%:*}"
      local name="${entry##*:}"
      local _state="stopped"
      systemctl is-active --quiet "xeqmnode_${name}.service" 2>/dev/null && _state="running"
      checklist_args+=( "${entry}" "(${layout}, ${_state})" "OFF" )
    done

    local selected_raw=""
    selected_raw="$(whiptail --title "Select Nodes to Wipe" \
      --ok-button "Wipe Selected" \
      --cancel-button "Cancel" \
      --checklist "Space to toggle, Enter to confirm:" \
      $(( ${#all_nodes[@]} + 9 )) 60 "${#all_nodes[@]}" \
      "${checklist_args[@]}" 3>&1 1>&2 2>&3)" || { echo -e "\nAborted."; exit 0; }

    if [[ -z "${selected_raw}" ]]; then
      wt_msgbox "Nothing Selected" "No nodes were selected — nothing will be wiped." 8 52
      exit 0
    fi

    local _item
    read -ra _raw_arr <<< "${selected_raw}"
    for _item in "${_raw_arr[@]}"; do
      _item="${_item//\"/}"
      [[ -n "${_item}" ]] && target_nodes+=("${_item}")
    done
  else
    echo -e "\n\033[1mFound ${#all_nodes[@]} node(s):\033[0m"
    for entry in "${all_nodes[@]}"; do
      local layout="${entry%%:*}"
      local name="${entry##*:}"
      echo -e "  [${layout}] ${name}"
    done
    local _mode
    prompt_menu "Which nodes would you like to wipe?" _mode 1 \
      "All nodes" \
      "Select specific nodes"
    if [[ "${_mode}" -eq 1 ]]; then
      target_nodes=("${all_nodes[@]}")
    else
      read -rp $'\n\033[1mEnter node names (comma-separated, e.g. snode1,snode2 or snodeuser1):\e[0m ' _input
      IFS=',' read -ra _names <<< "${_input}"
      for _n in "${_names[@]}"; do
        _n="${_n// /}"
        for entry in "${all_nodes[@]}"; do
          local name="${entry##*:}"
          [[ "${name}" = "${_n}" ]] && target_nodes+=("${entry}") && break
        done
      done
    fi
  fi

  if [[ "${#target_nodes[@]}" -eq 0 ]]; then
    echo -e "\nNothing selected — aborted.\n"
    exit 0
  fi

  local node_list=""
  for entry in "${target_nodes[@]}"; do
    local layout="${entry%%:*}"
    local name="${entry##*:}"
    node_list+="  \xe2\x80\xa2 ${name} (${layout})\n"
  done

  if wt_available; then
    whiptail --title "Final Confirmation" \
      --ok-button "WIPE NOW" \
      --cancel-button "Cancel" \
      --yesno "Permanently wipe these ${#target_nodes[@]} node(s)?\n\n${node_list}\nThis CANNOT be undone." \
      $(( ${#target_nodes[@]} + 10 )) 58
    [[ $? -ne 0 ]] && { echo -e "\nAborted."; exit 0; }
  else
    echo -e "\n\033[1;31mAbout to permanently wipe:\033[0m"
    printf '%b' "${node_list}"
    read -rp $'\n\033[1;31mType YES to confirm (anything else aborts):\e[0m ' _final
    [[ "${_final}" != "YES" ]] && { echo -e "\nAborted."; exit 0; }
  fi

  echo ""
  tput rev 2>/dev/null || true; printf "\033[1m  Wiping %d node(s)  \033[0m\n" "${#target_nodes[@]}"; tput sgr0 2>/dev/null || true

  for entry in "${target_nodes[@]}"; do
    local layout="${entry%%:*}"
    local name="${entry##*:}"
    if [[ "${layout}" = "canonical" ]]; then
      wipe_canonical_node "${name}"
    else
      wipe_node "${name}"
    fi
  done

  echo -e "\n\033[1mReloading systemd daemon...\033[0m"
  sudo systemctl daemon-reload
  sudo systemctl reset-failed 2>/dev/null || true

  local -a remaining_canonical=()
  discover_canonical_snodes remaining_canonical
  if [[ "${#remaining_canonical[@]}" -eq 0 ]]; then
    local had_canonical=0
    for entry in "${target_nodes[@]}"; do
      [[ "${entry%%:*}" = "canonical" ]] && had_canonical=1 && break
    done
    if [[ "${had_canonical}" -eq 1 ]]; then
      echo ""
      local _yn
      read -rp $'\033[1mNo canonical nodes remain. Remove /opt/xeqm/bin/?\e[0m [y/N]: ' _yn
      if [[ "${_yn,,}" = "y" ]]; then
        sudo rm -rf /opt/xeqm/bin
        echo -e "  Removed /opt/xeqm/bin"
      fi
      read -rp $'\033[1mRemove shared xeqm system user?\e[0m [y/N]: ' _yn
      if [[ "${_yn,,}" = "y" ]]; then
        sudo userdel xeqm 2>/dev/null || true
        echo -e "  Removed user xeqm"
      fi
    fi
  fi

  echo -e "\n\033[1;32mWipe complete. Server is ready for a fresh install.\033[0m\n"

  [[ "${XEQM_FROM_MENU:-0}" = "1" ]] && read -rp $'  Press Enter to return to the menu...' _
}

wipe_finally() {
  result=$?
  echo ""
  exit ${result}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap wipe_finally EXIT ERR INT
  wipe_run "$@"
fi
