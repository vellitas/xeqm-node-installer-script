#!/usr/bin/env bash
# firewall.sh — Reconfigure firewall rules for all installed XEQM service nodes

set -o errexit
set -o nounset
set -o pipefail

: "${script_basedir:=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")}"

source "${script_basedir}/common.sh"

firewall_version='v1.0'

# ── Port discovery ────────────────────────────────────────────────────────────
# Returns parallel arrays: _fw_names, _fw_p2p, _fw_qnet
_discover_ports() {
  _fw_names=()
  _fw_p2p=()
  _fw_qnet=()

  local -a unit_names=()
  mapfile -t unit_names < <(
    systemctl list-units 'xeqmnode_*.service' --all --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' | natsort
  )

  for unit_name in "${unit_names[@]}"; do
    [[ -z "${unit_name}" ]] && continue
    local snode_name="${unit_name%.service}"
    snode_name="${snode_name#xeqmnode_}"
    local unit_file="/etc/systemd/system/${unit_name}"
    [[ ! -f "${unit_file}" ]] && continue

    local exec_raw p2p qnet
    exec_raw=$(systemctl show "${unit_name}" -p ExecStart 2>/dev/null)
    p2p=$(echo "${exec_raw}"  | grep -o -- '--p2p-bind-port=[^ ;]*'  | cut -d= -f2 || true)
    qnet=$(echo "${exec_raw}" | grep -o -- '--quorumnet-port=[^ ;]*' | cut -d= -f2 || true)
    [[ -z "${qnet}" && -n "${p2p}" ]] && qnet=$(( p2p + 2 ))

    [[ -z "${p2p}" ]] && continue
    _fw_names+=( "${snode_name}" )
    _fw_p2p+=(   "${p2p}" )
    _fw_qnet+=(  "${qnet}" )
  done
}

# ── Current state banner ──────────────────────────────────────────────────────
_show_current_state() {
  echo ""
  local ufw_active=0 oci_reject=0

  if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw_active=1
  fi
  if sudo iptables -L INPUT -n 2>/dev/null | grep -qE '^REJECT.*all.*0\.0\.0\.0/0'; then
    oci_reject=1
  fi

  if [[ "${oci_reject}" -eq 1 ]]; then
    echo -e "  Current mode: \033[0;31mOracle Cloud — raw iptables REJECT present (all inbound blocked)\033[0m"
  elif [[ "${ufw_active}" -eq 1 ]]; then
    echo -e "  Current mode: \033[0;32mUFW active\033[0m"
  else
    echo -e "  Current mode: \033[0;33mNo active host firewall detected — external firewall assumed\033[0m"
  fi

  echo -e "  Nodes found:  ${#_fw_names[@]}"
  echo ""
}

# ── Apply UFW ─────────────────────────────────────────────────────────────────
_apply_ufw() {
  local oci="${1:-0}"

  if ! command -v ufw &>/dev/null; then
    echo -e "\n\033[1mInstalling UFW...\033[0m"
    sudo apt-get -y -q install ufw
  fi

  echo -e "\n\033[1mOpening SSH (safety net)...\033[0m"
  sudo ufw allow ssh

  echo -e "\n\033[1mOpening node ports...\033[0m"
  for i in "${!_fw_names[@]}"; do
    local p2p="${_fw_p2p[$i]}" qnet="${_fw_qnet[$i]}"
    sudo ufw allow "${p2p}/tcp"
    sudo ufw allow "${qnet}"
    printf "  %-12s p2p %s/tcp   qnet %s (tcp+udp)\n" "${_fw_names[$i]}" "${p2p}" "${qnet}"
  done

  echo -e "\n\033[1mEnabling UFW...\033[0m"
  sudo ufw --force enable

  if [[ "${oci}" -eq 1 ]]; then
    echo -e "\n\033[1mOracle Cloud: removing raw iptables REJECT rule...\033[0m"
    sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
    sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null 2>/dev/null || true
  fi

  echo -e "\n\033[0;32mDone.\033[0m"
}

# ── Apply iptables ────────────────────────────────────────────────────────────
_apply_iptables() {
  check_iptables_dependencies

  echo -e "\n\033[1mOpening node ports [iptables]...\033[0m"
  for i in "${!_fw_names[@]}"; do
    local p2p="${_fw_p2p[$i]}" qnet="${_fw_qnet[$i]}"
    sudo iptables -A INPUT  -p tcp --dport "${p2p}"  -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --sport "${p2p}"  -m conntrack --ctstate ESTABLISHED     -j ACCEPT
    sudo iptables -A INPUT  -p tcp --dport "${qnet}" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --sport "${qnet}" -m conntrack --ctstate ESTABLISHED     -j ACCEPT
    sudo iptables -A INPUT  -p udp --dport "${qnet}" -j ACCEPT
    sudo iptables -A OUTPUT -p udp --sport "${qnet}" -j ACCEPT
    printf "  %-12s p2p %s/tcp   qnet %s (tcp+udp)\n" "${_fw_names[$i]}" "${p2p}" "${qnet}"
  done

  sudo iptables-save  | uniq | sudo tee /etc/iptables/rules.v4 | sudo iptables-restore
  sudo ip6tables-save | uniq | sudo tee /etc/iptables/rules.v6 | sudo ip6tables-restore

  echo -e "\n\033[0;32mDone. Rules saved to /etc/iptables/rules.v4\033[0m"
}

# ── Show external port list ───────────────────────────────────────────────────
_show_external() {
  local entries=()
  for i in "${!_fw_names[@]}"; do
    entries+=( "${_fw_names[$i]} ${_fw_p2p[$i]} ${_fw_qnet[$i]}" )
  done
  print_external_firewall_guidance "${entries[@]}"
}

# ── Remove UFW rules for all node ports ───────────────────────────────────────
_remove_ufw_rules() {
  if ! command -v ufw &>/dev/null; then
    echo -e "\n  UFW is not installed — nothing to remove."
    return 0
  fi

  echo -e "\n\033[1mRemoving node UFW rules...\033[0m"
  for i in "${!_fw_names[@]}"; do
    local p2p="${_fw_p2p[$i]}" qnet="${_fw_qnet[$i]}"
    sudo ufw delete allow "${p2p}/tcp"  2>/dev/null || true
    sudo ufw delete allow "${qnet}/tcp" 2>/dev/null || true
    sudo ufw delete allow "${qnet}/udp" 2>/dev/null || true
    sudo ufw delete allow "${qnet}"     2>/dev/null || true
    printf "  %-12s removed p2p %s   qnet %s\n" "${_fw_names[$i]}" "${p2p}" "${qnet}"
  done
  echo -e "\n\033[0;32mDone. UFW rules for node ports removed.\033[0m"
  echo -e "  \033[0;33mNote: UFW itself is still enabled — disable manually if no longer needed:\033[0m"
  echo -e "        sudo ufw disable"
}

# ── Main ──────────────────────────────────────────────────────────────────────
firewall_run() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Firewall Configuration" "${firewall_version}"

  _discover_ports

  if [[ "${#_fw_names[@]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mNo XEQM service node units found on this server.\033[0m"
    exit 0
  fi

  _show_current_state

  local choice
  if wt_available; then
    local _wt_choice
    _wt_choice="$(whiptail --title "Firewall Configuration" \
      --ok-button "Apply" --cancel-button "Cancel" \
      --menu "Select firewall mode for ${#_fw_names[@]} node(s):" 18 72 5 \
      "ufw"      "UFW — open all node ports (recommended for VPS)" \
      "oci"      "Oracle Cloud — UFW + remove raw iptables REJECT rule" \
      "iptables" "iptables — open ports directly (no UFW)" \
      "external" "External firewall — show port list for OPNSense / pfSense" \
      "remove"   "Remove UFW rules — switching to external firewall" \
      3>&1 1>&2 2>&3)" || { echo "Cancelled."; exit 0; }
    choice="${_wt_choice}"
  else
    local _idx
    prompt_menu "Select firewall mode:" _idx 1 \
      "UFW — open all node ports (recommended for VPS)" \
      "Oracle Cloud (OCI) — UFW + remove raw iptables REJECT rule" \
      "iptables — open ports directly (no UFW)" \
      "External firewall — show port list for OPNSense / pfSense" \
      "Remove UFW rules — switching to external firewall"
    case "${_idx}" in
      1) choice="ufw"      ;;
      2) choice="oci"      ;;
      3) choice="iptables" ;;
      4) choice="external" ;;
      5) choice="remove"   ;;
    esac
  fi

  case "${choice}" in
    ufw)      _apply_ufw 0 ;;
    oci)      _apply_ufw 1 ;;
    iptables) _apply_iptables ;;
    external) _show_external ;;
    remove)   _remove_ufw_rules ;;
  esac

  if [[ "${XEQM_FROM_MENU:-0}" = "1" ]]; then
    echo ""
    read -rp $'  Press Enter to return to the menu...' _
  fi
}

firewall_finally() {
  result=$?
  echo ""
  exit "${result}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap firewall_finally EXIT ERR INT
  firewall_run "$@"
fi
