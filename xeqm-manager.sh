#!/usr/bin/env bash
# XEQM Node Manager — main menu

set -o errexit
set -o nounset
set -o pipefail

script_basedir=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
readonly script_basedir

export XEQM_FROM_MENU=1

# Only source common.sh for wt_available / print_splash_screen helpers.
# Sub-scripts are run as isolated subprocesses to avoid function name collisions.
source "${script_basedir}/common.sh"

if ! command -v whiptail >/dev/null 2>&1; then
  echo "  Installing whiptail..."
  sudo apt-get -y -q install whiptail
fi

if ! [ -t 0 ] || ! [ -t 1 ]; then
  echo ""
  echo "  ERROR: This menu requires an interactive terminal."
  echo "  If connecting via SSH, use:  ssh -t user@host"
  echo ""
  exit 1
fi

menu_version='v1.2'

_run_tool() {
  local script="$1"; shift
  clear
  local _rc=0
  bash "${script_basedir}/${script}" "$@" || _rc=$?
  if [[ ${_rc} -ne 0 ]]; then
    echo ""
    read -rp $'\033[1;31mTool exited with error (code '"${_rc}"$'). Press Enter to return to menu.\033[0m '
  fi
  clear
}

main() {
  while true; do
    local choice=""

    if wt_available; then
      local _wt_choice
      _wt_choice="$(whiptail --title "XEQM Node Manager" \
        --ok-button "Run" --cancel-button "Exit" \
        --menu "Select a tool:" 20 80 7 \
        "Install"      "Set Up Service Nodes on This Server" \
        "Health Check" "Diagnose Nodes, Check Peers & Auto-Repair Issues" \
        "Register"     "Register Nodes on the XEQM Network" \
        "Migrate"      "Move a Node from Another Server to This One" \
        "Upgrade"      "Upgrade Node Software to the Latest Version" \
        "Unlock"       "Begin 14-Day Stake Unlock (Rewards Continue Until Release)" \
        "Remove Nodes" "Permanently Remove Node Installs from This Server" \
        3>&1 1>&2 2>&3)" || break
      choice="${_wt_choice}"
    else
      print_splash_screen "XEQM Node Manager" "${menu_version}"
      local _idx
      prompt_menu "Select a tool:" _idx 1 \
        "Install       — Set up service nodes on this server" \
        "Health Check  — Diagnose nodes, check peers & auto-repair issues" \
        "Register      — Register nodes on the XEQM network" \
        "Migrate       — Move a node from another server to this one" \
        "Upgrade       — Upgrade node software to the latest version" \
        "Unlock        — Begin 14-day stake unlock (rewards continue until release)" \
        "Remove Nodes  — Permanently remove node installs from this server" \
        "Exit"
      case "${_idx}" in
        1) choice="Install"       ;;
        2) choice="Health Check"  ;;
        3) choice="Register"      ;;
        4) choice="Migrate"       ;;
        5) choice="Upgrade"       ;;
        6) choice="Unlock"        ;;
        7) choice="Remove Nodes"  ;;
        8) break ;;
      esac
    fi

    case "${choice}" in
      Install)       _run_tool install.sh        ;;
      "Health Check") _run_tool doctor.sh        ;;
      Register)      _run_tool register.sh       ;;
      Migrate)       _run_tool server-migrate.sh ;;
      Upgrade)       _run_tool upgrade.sh        ;;
      Unlock)        _run_tool decommission.sh   ;;
      "Remove Nodes") _run_tool wipe.sh          ;;
    esac
  done
}

menu_finally() {
  echo ""
  exit "${?}"
}
trap menu_finally EXIT ERR INT

main "$@"
