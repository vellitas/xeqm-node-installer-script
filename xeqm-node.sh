#!/usr/bin/env bash
# v1.0 developed by GreggyGB
# v2.0-v5.x by Mister R

set -o errexit
set -o nounset
set -o pipefail

script_basedir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
install_root_bin_dir=$HOME
install_root_service='/etc/systemd/system'
readonly script_basedir install_root_bin_dir install_root_service

source "${script_basedir}/common.sh"
load_config "${script_basedir}/install.conf" config

service_name="xeqmnode_${config[running_user]}.service"
service_file="${install_root_service}/${service_name}"
readonly service_name service_file

quorumnet_port="${config[quorumnet_port]:-$((config[p2p_bind_port] + 2))}"
port_params="--p2p-bind-port=${config[p2p_bind_port]} --rpc-admin=127.0.0.1:${config[rpc_bind_port]} --quorumnet-port=${quorumnet_port}"
readonly quorumnet_port port_params

active_user=${USER:=$(/usr/bin/id -run)}
readonly active_user

service_template="${script_basedir}/xeqmnode.service.template"
readonly service_template

daemon_start_time=

main() {
  case "$1" in
    install)            install_node ;;
    open_firewall)      open_firewall ;;
    prepare_sn)         prepare_sn ;;
    start)              start ;;
    stop)               stop_all_nodes ;;
    restart)            stop_all_nodes ; start ;;
    status)             status ;;
    log)                log ;;
    fakerun)            sleep 300 ;;
    setup_service)     build_and_install_service_file ;;
    fork_update)        fork_update ;;
    print_sn_key)       print_sn_key ;;
    print_sn_status)    print_sn_status ;;
    sync_scripts)       sync_scripts ;;
    * ) usage
  esac
}

install_node() {
  init
  install_manager
}

init() {
  if [ "${config[running_user]}" != "${active_user}" ]; then
    printf "\033[0;31mFATAL\033[0m: Wrong user running '%s'. Expected user: '%s'. Current user: '%s'!\n" "${BASH_SOURCE[0]}" "${config[running_user]}" "${active_user}"
    echo -e "Please run this script with the correct user or modify 'install.conf'.\n"

    if [ "${active_user}" = 'root' ]; then
      echo -e "\033[0;33mIn case you simply need to quickly install the XEQM service node. Please run below command as root user instead, especially if you have not used this command for this install before\033[0m:\n\tbash install.sh\n"
    fi
    exit 1
  fi

  if ! [[ -f "${installer_session_state_file}" ]]; then
    set_install_session_state "${installer_state[started]}"
  fi
}

install_manager() {
  local current_install_state="$(read_install_session_state)"

  if [ "${current_install_state}" != "${installer_state[started]}" ]; then
    echo -e "Skipping ahead to previous exit point...\n"
  fi

  # ';&' fall-through case, based on installer_session_state_file.
  case "${current_install_state}" in
    "${installer_state[started]}")            ;&
    "${installer_state[install_packages]}")   install_required_packages ;&
    "${installer_state[checkout_git]}")       checkout_git_repo ;&
    "${installer_state[compile_move]}")       compile_and_move_binaries ;&
    "${installer_state[install_service]}")    build_and_install_service_file ;&
    "${installer_state[enable_service]}")     enable_service_on_boot ;&
    "${installer_state[start_service]}")      start_service ;&
    "${installer_state[watch_daemon]}")       watch_daemon_status ;&
    "${installer_state[finished_xeqmnode_install]}")  finish_xeqmnode_install ;;
    *) printf "Unknown installer state '%s' found in '%s'. Aborting..." "${current_install_state}" "${installer_session_state_file}"
       exit 1 ;;
  esac
}

install_required_packages() {
  set_install_session_state "${installer_state[install_packages]}"

  echo -e "\n\033[1mInstalling required packages...\033[0m"
  sudo apt update
  sudo apt -y install wget unzip git bc

  if [[ "${config[binary_source]:-compile}" = "compile" ]]; then
    echo -e "\n\033[1mInstalling build dependencies...\033[0m"
    sudo apt-get -y install build-essential cmake pkg-config libboost-all-dev libssl-dev libzmq3-dev libunbound-dev libsodium-dev libunwind8-dev liblzma-dev libreadline6-dev libldns-dev libexpat1-dev doxygen graphviz libpgm-dev qttools5-dev-tools libhidapi-dev libusb-dev libprotobuf-dev protobuf-compiler
  fi
}

checkout_git_repo() {
  set_install_session_state "${installer_state[checkout_git]}"

  if [[ -d "${install_root_bin_dir}/bin" ]]; then
    echo -e "\n\033[1mSkipped checking out XEQM git repo, using existing binaries...\033[0m"
    return 0
  fi

  if [ "${config[install_version]}" = 'auto' ]; then
    echo -e "\033[1mRetrieving latest version tag from Github...\033[0m"
    config[install_version]="$(get_latest_xeqm_version_number)"
  fi
  echo -e "\n\033[1mChecking Out XEQM Repository Files...\033[0m"
  git clone --recursive "${config[git_repository]}" xeqm-core && cd xeqm-core
  git submodule init && git submodule update
  git checkout "${config[install_version]}"
}

compile_and_move_binaries() {
  set_install_session_state "${installer_state[compile_move]}"

  if [[ -d "${install_root_bin_dir}/bin" ]]; then
    echo -e "\n\033[1mSkipped compiling XEQM binaries, using existing binaries...\033[0m"
    return 0
  fi

  local build_dir="${script_basedir}/xeqm-core/build/Linux/release"
  echo -e "\n\033[1mConfiguring build...\033[0m"
  mkdir -p "${build_dir}"
  cd "${build_dir}"
  cmake -D CMAKE_BUILD_TYPE=Release ../../..

  echo -e "\n\033[1mCompiling XEQM binaries...\033[0m"
  make -j$(nproc)

  echo -e "\n\033[1mMoving XEQM binaries to installation directory...\033[0m"
  mv bin "${install_root_bin_dir}"
}

get_make_release_base_dir() {
  echo "${script_basedir}/xeqm-core/build/Linux/release"
}

build_and_install_service_file() {
  set_install_session_state "${installer_state[install_service]}"

  if [[ -f "${service_file}" ]]; then
    echo -e "\n\033[1mRemoving existing '${service_file}' file...\033[0m"
    sudo rm "${service_file}"
  fi

  echo -e "\n\033[1mGenerating service file '${service_file}'...\033[0m"

  local opt_params=
  if [[ -n "${config[service_node_public_ip]}" ]]; then
    opt_params+=" --service-node-public-ip=${config[service_node_public_ip]}"
  fi
  if [[ "${config[daemon_no_fluffy_blocks]}" -eq 1 ]]; then
    opt_params+=" --no-fluffy-blocks"
  fi
  if [[ -n "${config[daemon_log_level]}" ]]; then
    opt_params+=" --log-level ${config[daemon_log_level]}"
  fi

  # shellcheck disable=SC2002
  cat "${service_template}" | sed -e "s/%INSTALL_USERNAME%/${config[running_user]}/g" -e "s#%INSTALL_ROOT%#${install_root_bin_dir}#g" -e "s/%PORT_PARAMS%/${port_params}/g"  -e "s/%OPT_PARAMS%/${opt_params}/g" | sudo tee "${service_file}"

  echo -e "\n\033[1mReloading service manager...\033[0m"
  sudo systemctl daemon-reload
}

enable_service_on_boot() {
  set_install_session_state "${installer_state[enable_service]}"

  echo -e "\n\033[1mEnabling service to start automatically upon boot...\033[0m"
  sudo systemctl enable "${service_name}"
}

start_service() {
  set_install_session_state "${installer_state[start_service]}"
  daemon_start_time=$(date +%s)
  start
}

wait_daemon_start() {
   sleep 10
   local timeout_time=30
   local polling_time_passed=0

   while [ $polling_time_passed -lt $timeout_time ]; do
     sleep 1
     if ps aux | grep -q "[x]eqm-d --non-interactive --service-node" ; then
       break
     fi
     polling_time_passed=$((polling_time_passed + 1))

     if [[ $polling_time_passed -eq $timeout_time ]]; then
       echo -e "\033[0;31mOops, the XEQM daemon seems to be not started or crashed.\033[0m\nExiting service node installer\n"
       exit 1
     fi
   done
}

watch_daemon_status() {
  set_install_session_state "${installer_state[watch_daemon]}"

  if [[ "${XEQM_SKIP_SYNC_WATCH:-0}" == "1" ]]; then
    echo -e "\n\033[1mDaemon started — blockchain syncing in background.\033[0m"
    return 0
  fi

  echo -e "\n\033[1mWaiting till daemon is detected...\033[0m"
  wait_daemon_start

  echo -e "\n\033[1mMonitoring blockchain sync progress:\033[0m\n"
  printf "\t(waiting for first status...)\n"

  local rpc_url="http://127.0.0.1:${config[rpc_bind_port]}/get_info"
  local last_height=0
  local stall_count=0
  local max_stall=18  # 18 * 10s = 3 minutes with no new blocks → assume synced

  while true; do
    # primary: journal sync completion message
    if sudo journalctl -u "${service_name}" --no-pager -n 500 2>/dev/null \
        | grep -q "You are now synchronized with the network"; then
      tput cuu1
      printf "\r\t\033[1;32mBlockchain synchronized.\033[0m%-40s\n" ""
      break
    fi

    # secondary: HTTP RPC height query
    local info height target_height
    info="$(curl -s --connect-timeout 3 "${rpc_url}" 2>/dev/null)"
    height="$(echo "${info}"    | grep -o '"height":[0-9]*'        | head -1 | cut -d: -f2)"
    target_height="$(echo "${info}" | grep -o '"target_height":[0-9]*' | head -1 | cut -d: -f2)"

    if [[ "${target_height}" =~ ^[0-9]+$ && "${target_height}" -gt 1000 ]]; then
      local perc
      perc="$(bc -l <<< "scale=1; ${height} * 100 / ${target_height}" 2>/dev/null)"
      tput cuu1
      printf "\r\t(%.01f%%) - %d/%d%-40s\n" "${perc:-0}" "${height:-0}" "${target_height}" ""

      if [[ "${height}" -ge "${target_height}" ]]; then
        tput cuu1
        printf "\r\t\033[1;32mBlockchain synchronized.\033[0m%-40s\n" ""
        break
      fi

      if [[ "${height}" -eq "${last_height}" ]]; then
        stall_count=$((stall_count + 1))
        if [[ "${stall_count}" -ge "${max_stall}" ]]; then
          tput cuu1
          printf "\r\t\033[1;33mNo new blocks for 3 minutes — assuming synced.\033[0m%-20s\n" ""
          break
        fi
      else
        stall_count=0
        last_height="${height}"
      fi
    fi

    sleep 10
  done
}

finish_xeqmnode_install() {
  set_install_session_state "${installer_state[finished_xeqmnode_install]}"

  if [[ "${config[open_firewall]}" -eq 1 ]]; then
    open_firewall
  fi
}

open_firewall() {
  local p2p_port="${config[p2p_bind_port]}"
  local fw_quorumnet_port="${config[quorumnet_port]:-$((p2p_port + 2))}"
  local public_ports=("${p2p_port}" "${fw_quorumnet_port}")

  # Respect explicit config; fall back to detection
  local firewall_mode
  if [[ "${config[firewall_mode]:-}" = "ufw" ]]; then
    firewall_mode='ufw'
  elif [[ "${config[firewall_mode]:-}" = "iptables" ]]; then
    firewall_mode='iptables'
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
    # Quorumnet requires UDP as well as TCP
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
    # Quorumnet requires both TCP and UDP
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

      # make sure ssh port is open
      sudo iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
      sudo iptables -A OUTPUT -p tcp --sport 22 -m conntrack --ctstate ESTABLISHED -j ACCEPT
      sudo iptables-save | uniq | sudo tee /etc/iptables/rules.v4 | sudo iptables-restore
      sudo ip6tables-save | uniq | sudo tee /etc/iptables/rules.v6 | sudo ip6tables-restore
    fi
}

prepare_sn() {
  local rpc_port="${config[rpc_bind_port]}"

  echo -e "\n\033[1mService Node Registration\033[0m"

  local node_type
  prompt_menu "How would you like to stake this node?" node_type 1 \
    "Solo node  — stake the full 200,000 XEQM yourself" \
    "Pool node  — stake a portion and open to contributors  (minimum 100,000 XEQM)"

  local contribution_xeqm=200000
  local operator_cut=0

  if [[ "${node_type}" -eq 2 ]]; then
    while true; do
      read -rp $'\n\033[1mHow much XEQM will you contribute?\e[0m (100000–200000) [100000]: ' contribution_xeqm
      contribution_xeqm="${contribution_xeqm:-100000}"
      if [[ "${contribution_xeqm}" =~ ^[0-9]+$ && "${contribution_xeqm}" -ge 100000 && "${contribution_xeqm}" -le 200000 ]]; then
        break
      fi
      echo -e "  \033[0;33mPlease enter a number between 100000 and 200000.\033[0m"
    done

    while true; do
      read -rp $'\n\033[1mOperator cut\e[0m — your % of rewards before distribution to contributors (0–10) [0]: ' operator_cut
      operator_cut="${operator_cut:-0}"
      if [[ "${operator_cut}" =~ ^[0-9]+$ && "${operator_cut}" -ge 0 && "${operator_cut}" -le 10 ]]; then
        break
      fi
      echo -e "  \033[0;33mPlease enter a number between 0 and 10.\033[0m"
    done
  fi

  local wallet_address
  while true; do
    read -rp $'\n\033[1mEnter your XEQM wallet address:\e[0m ' wallet_address
    wallet_address="${wallet_address//[[:space:]]/}"
    if [[ -z "${wallet_address}" ]]; then
      echo -e "  \033[0;33mWallet address cannot be empty.\033[0m"
    elif [[ ! "${wallet_address}" =~ ^XEQM ]]; then
      echo -e "  \033[0;33mXEQM addresses start with 'XEQM'. Please check and re-enter.\033[0m"
    elif [[ "${#wallet_address}" -lt 90 || "${#wallet_address}" -gt 110 ]]; then
      echo -e "  \033[0;33mAddress length looks wrong (${#wallet_address} chars). Expected ~97 chars. Please re-enter.\033[0m"
    else
      break
    fi
  done

  local contribution_atomic=$(( contribution_xeqm * 1000000000 ))

  echo -e "\n\033[1mFetching registration command from daemon...\033[0m"
  local staking_requirement
  staking_requirement="$(curl -s -m 5 "http://127.0.0.1:${rpc_port}/json_rpc" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"0","method":"get_staking_requirement"}' \
    2>/dev/null | grep -o '"staking_requirement":[0-9]*' | cut -d: -f2)"
  : "${staking_requirement:=200000000000000}"

  local reg_cmd
  reg_cmd="$(curl -s "http://127.0.0.1:${rpc_port}/json_rpc" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_service_node_registration_cmd\",\"params\":{\"operator_cut\":\"$(( operator_cut * 100 ))\",\"contributor_addresses\":[\"${wallet_address}\"],\"contributor_amounts\":[${contribution_atomic}],\"staking_requirement\":${staking_requirement}}}" \
    2>/dev/null | grep -o '"registration_cmd":"[^"]*"' | cut -d'"' -f4)"

  if [[ -z "${reg_cmd}" ]]; then
    echo -e "\n\033[0;31mError: Could not get registration command. Is the daemon running on port ${rpc_port}?\033[0m\n"
    exit 1
  fi

  echo -e "\n\033[1;32m$(printf '═%.0s' $(seq 1 60))\033[0m"
  echo -e "\033[1m  Submit this command in your XEQM wallet:\033[0m"
  echo -e "\033[1;32m$(printf '═%.0s' $(seq 1 60))\033[0m\n"
  echo -e "  \033[1m${reg_cmd}\033[0m\n"
  echo -e "\033[1;32m$(printf '═%.0s' $(seq 1 60))\033[0m\n"

  echo -e "\033[1m  Important: back up your service node key\033[0m"
  echo -e "  Run this command to display it (store it somewhere safe):\n"
  echo -e "    bash xeqm-node.sh print_sn_key\n"
}

start() {
  echo "Starting XEQ node"
  sudo systemctl start "${service_name}"
  echo "Service node started. To view logs run: bash xeqm-node.sh log"
}

status() {
  ~/bin/xeqm-d status ${port_params}
  #systemctl status "${service_name}"
}

stop_all_nodes() {
  echo "Stopping XEQ node"
  sudo systemctl stop "${service_name}"
}

log() {
  sudo journalctl -u "${service_name}" -af
}

print_sn_key() {
  ~/bin/xeqm-d print_sn_key ${port_params}
}

print_sn_status() {
  ~/bin/xeqm-d print_sn_status ${port_params}
}

sync_scripts() {
  local src="${script_basedir}"
  local updated=0
  for dest in /home/snode*/xeqm-installer/; do
    [[ -d "${dest}" ]] || continue
    sudo cp "${src}/xeqm-node.sh" "${src}/common.sh" "${src}/xeqmnode.service.template" "${dest}"
    # Rebuild the systemd service file from the updated template
    local node_user
    node_user="$(stat -c '%U' "${dest}")"
    sudo -H -u "${node_user}" bash -c "cd ~/xeqm-installer/ && bash xeqm-node.sh setup_service" 2>/dev/null || true
    echo "  Updated ${dest}  (user: ${node_user})"
    updated=$((updated + 1))
  done
  [[ "${updated}" -gt 0 ]] && sudo systemctl daemon-reload
  echo -e "\n\033[1;32mSynced scripts to ${updated} node(s).\033[0m"
  [[ "${updated}" -gt 0 ]] && echo -e "  Service files rebuilt. Changes take effect on next node restart."
}

fork_update() {
  echo -e "\033[1mUpgrading to ${config[install_version]}...\033[0m"

  rm -Rf "${script_basedir}/xeqm-core"
  git clone --recursive "${config[git_repository]}" xeqm-core && cd xeqm-core
  git submodule init && git submodule update
  git checkout "${config[install_version]}"

  local build_dir="${script_basedir}/xeqm-core/build/Linux/release"
  mkdir -p "${build_dir}"
  cd "${build_dir}"
  cmake -D CMAKE_BUILD_TYPE=Release ../../..
  make -j$(nproc)

  stop_all_nodes
  sudo rm -Rf ~/bin
  cd "$(get_make_release_base_dir)"
  sudo mv bin ~/

  build_and_install_service_file
  start

  if [[ "${config[open_firewall]}" -eq 1 ]]; then
    open_firewall
  fi
}

usage() {
  cat <<USAGEMSG
bash $0 [COMMAND...] [OPTION...]

Commands:
  install                         Install of XEQM service node
  open_firewall [iptables|ufw]    Open firewall for p2p in/out ports
  start                           Start XEQM service node
  stop                            Stop XEQM service node
  prepare_sn                      Prepare XEQM service node for staking
  print_sn_key                    Print service node key
  setup_service                   Generate and install new service file based on install.conf
  print_sn_status                 Print service node registered status
  status                          Check service status
  log                             View service log

Options:
  -h  --help                      Show this help text

USAGEMSG
}

usage_help_is_needed() {
  [[ ( "${#}" -ge "1" && ( "$1" = '-h' || "$1" = '--help' )) || "${#}" -eq "0" ]]
}

if usage_help_is_needed "$@"; then
  usage
  exit 0
fi

main "${@}"
