#!/usr/bin/env bash
# XEQM Labs — Service Node Key Transfer Tool
# Exports, imports, and transfers service node keys between users or servers.

set -euo pipefail

script_basedir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_basedir

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

transfer_version='v1.0'
readonly transfer_version

typeset -A command_options_set
command_options_set=(
  [help]=0
  [list]=0
  [export]=0
  [import]=0
  [transfer]=0
  [user]=0
  [from_user]=0
  [to_user]=0
  [key_file]=0
  [output_dir]=0
  [quiet]=0
)

user_option_value=
from_user_option_value=
to_user_option_value=
key_file_option_value=
output_dir_option_value=.

main() {
  install_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Service Node Transfer" "${transfer_version}"
  process_command_line_args "$@"
  execute_command
}

install_dependencies() {
  if ! [[ -x "$(command -v ss)" && -x "$(command -v natsort)" && -x "$(command -v gawk)" ]]; then
    echo -e "\n\033[1mFixing required dependencies...\033[0m"
    sudo apt -y install iproute2 python3-natsort gawk
  fi
}

process_command_line_args() {
  parse_command_line_args "$@"
  validate_parsed_command_line_args
  set_config_options
}

parse_command_line_args() {
  args="$(getopt -a -n transfer -o "hqf:t:u:k:o:" \
    --long help,quiet,list,export,import,transfer,from:,to:,user:,key-file:,output-dir: -- "$@")"
  eval set -- "${args}"

  while :; do
    case "$1" in
      -h | --help)        command_options_set[help]=1; shift ;;
      -q | --quiet)       command_options_set[quiet]=1; shift ;;
      --list)             command_options_set[list]=1; shift ;;
      --export)           command_options_set[export]=1; shift ;;
      --import)           command_options_set[import]=1; shift ;;
      --transfer)         command_options_set[transfer]=1; shift ;;
      -f | --from)        command_options_set[from_user]=1; from_user_option_value="$2"; shift 2 ;;
      -t | --to)          command_options_set[to_user]=1; to_user_option_value="$2"; shift 2 ;;
      -u | --user)        command_options_set[user]=1; user_option_value="$2"; shift 2 ;;
      -k | --key-file)    command_options_set[key_file]=1; key_file_option_value="$2"; shift 2 ;;
      -o | --output-dir)  command_options_set[output_dir]=1; output_dir_option_value="$2"; shift 2 ;;
      --)                 shift; break ;;
      *)                  echo "Unexpected option: $1"; usage; exit 1 ;;
    esac
  done
}

validate_parsed_command_line_args() {
  local ops_set=0
  for op in list export import transfer; do
    [[ "${command_options_set[${op}]}" -eq 1 ]] && ops_set=$((ops_set + 1))
  done

  if [[ "${command_options_set[help]}" -eq 1 ]]; then usage; exit 0; fi

  if [[ "${ops_set}" -eq 0 ]]; then
    echo -e "\033[0;33merror: specify one of --list, --export, --import, or --transfer\033[0m\n"
    usage
    exit 1
  fi

  if [[ "${ops_set}" -gt 1 ]]; then
    echo -e "\033[0;33merror: only one of --list, --export, --import, --transfer may be used at a time\033[0m\n"
    exit 1
  fi
}

set_config_options() {
  if [[ "${command_options_set[quiet]}" -eq 1 ]]; then
    config[quiet_mode]=1
  fi
}

execute_command() {
  if   [[ "${command_options_set[list]}"     -eq 1 ]]; then list_nodes
  elif [[ "${command_options_set[export]}"   -eq 1 ]]; then export_key
  elif [[ "${command_options_set[import]}"   -eq 1 ]]; then import_key
  elif [[ "${command_options_set[transfer]}" -eq 1 ]]; then local_transfer
  fi
}

# ── layout detection helpers ──────────────────────────────────────────────────

# Resolve data directory and layout for a node name (snode1, snode2, …).
# Sets: _node_layout ("canonical"|"installer"), _node_data_dir
resolve_node() {
  local node_name="$1"
  local unit_file="/etc/systemd/system/xeqmnode_${node_name}.service"

  if [[ ! -f "${unit_file}" ]]; then
    echo -e "\033[0;31merror\033[0m: No systemd unit found for '${node_name}'."
    return 1
  fi

  if grep -q '^User=xeqm$' "${unit_file}" 2>/dev/null; then
    _node_layout="canonical"
    _node_data_dir="/var/lib/xeqm/${node_name}"
  else
    _node_layout="installer"
    _node_data_dir="/home/${node_name}/.xeqmlabs"
    if ! id -u "${node_name}" >/dev/null 2>&1; then
      echo -e "\033[0;31merror\033[0m: Installer-layout node '${node_name}' has no OS user."
      return 1
    fi
  fi
}

stop_node() {
  local node_name="$1" layout="$2"
  if [[ "${layout}" = "canonical" ]]; then
    sudo systemctl stop "xeqmnode_${node_name}" 2>/dev/null || true
  else
    sudo -H -u "${node_name}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh stop' 2>/dev/null || true
  fi
}

start_node() {
  local node_name="$1" layout="$2"
  if [[ "${layout}" = "canonical" ]]; then
    sudo systemctl start "xeqmnode_${node_name}"
  else
    sudo -H -u "${node_name}" bash -c 'cd ~/xeqm-installer/ && bash xeqm-node.sh start'
  fi
}

get_node_pubkey() {
  local node_name="$1" layout="$2" data_dir="$3"
  local rpc_port pubkey=""

  # Try RPC first (works for both layouts when daemon is up)
  local unit_file="/etc/systemd/system/xeqmnode_${node_name}.service"
  rpc_port="$(grep -oP '(?<=--rpc-admin=127\.0\.0\.1:)\d+' "${unit_file}" 2>/dev/null || true)"
  if [[ -n "${rpc_port}" ]]; then
    pubkey="$(curl -s -m 3 "http://127.0.0.1:${rpc_port}/json_rpc" \
      -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_service_node_status"}' 2>/dev/null \
      | grep -o '"service_node_pubkey":"[^"]*"' | cut -d'"' -f4 || true)"
  fi
  echo "${pubkey:-unavailable}"
}

# ── list ──────────────────────────────────────────────────────────────────────

list_nodes() {
  local -a unit_names=()
  mapfile -t unit_names < <(systemctl list-units 'xeqmnode_*.service' \
    --no-pager --no-legend 2>/dev/null | awk '{print $1}' | natsort)

  if [[ "${#unit_names[@]}" -eq 0 ]]; then
    echo -e "\nNo active XEQM service node daemons found on this server."
    exit 0
  fi

  echo ""
  printf "  %-16s %-12s %s\n" "Node" "Layout" "Public Key"
  printf "  %-16s %-12s %s\n" "────────────────" "────────────" "$(printf '─%.0s' {1..64})"

  local _node_layout _node_data_dir
  for unit in "${unit_names[@]}"; do
    local snode_name="${unit%.service}"
    snode_name="${snode_name#xeqmnode_}"
    resolve_node "${snode_name}" 2>/dev/null || continue
    local pubkey
    pubkey="$(get_node_pubkey "${snode_name}" "${_node_layout}" "${_node_data_dir}")"
    printf "  %-16s %-12s %s\n" "${snode_name}" "${_node_layout}" "${pubkey}"
  done
  echo ""
}

# ── export ────────────────────────────────────────────────────────────────────

export_key() {
  local node_name="${user_option_value}"
  local output_dir="${output_dir_option_value}"

  if [[ -z "${node_name}" ]]; then
    echo -e "\033[0;33merror: --user <node-name> is required for --export\033[0m\n"
    usage; exit 1
  fi

  local _node_layout _node_data_dir
  resolve_node "${node_name}" || exit 1

  local -a key_files=()
  if [[ -f "${_node_data_dir}/key_bls" ]];     then key_files+=("key_bls");     fi
  if [[ -f "${_node_data_dir}/key_ed25519" ]]; then key_files+=("key_ed25519"); fi

  if [[ "${#key_files[@]}" -eq 0 ]]; then
    echo -e "\033[0;31merror\033[0m: No key files (key_bls, key_ed25519) found in '${_node_data_dir}'."
    exit 1
  fi

  local timestamp; timestamp="$(date +%Y%m%d%H%M%S)"
  local archive="${output_dir}/xeqm-key-${node_name}-${timestamp}.tar.gz"

  echo -e "\n\033[1mExporting key for '${node_name}' (${_node_layout} layout)...\033[0m"
  echo -e "  Data dir:  ${_node_data_dir}"
  echo -e "  Key files: ${key_files[*]}"

  local pubkey
  pubkey="$(get_node_pubkey "${node_name}" "${_node_layout}" "${_node_data_dir}")"

  sudo tar -czf "${archive}" -C "${_node_data_dir}" "${key_files[@]}"
  sudo chmod 600 "${archive}"
  sudo chown "$(id -un):$(id -gn)" "${archive}"

  echo -e "\n\033[1;32mKey exported successfully.\033[0m"
  echo -e "  Archive:    ${archive}"
  echo -e "  Public Key: ${pubkey}"
  echo -e "\n\033[0;33mWARNING: This archive controls the service node. Keep it secure.\033[0m"
  echo -e "\nTo import on another server:"
  echo -e "  1. Copy '${archive##*/}' to the target server"
  echo -e "  2. bash transfer.sh --import --user <target-node> --key-file /path/to/${archive##*/}"
}

# ── import ────────────────────────────────────────────────────────────────────

import_key() {
  local node_name="${user_option_value}"
  local archive="${key_file_option_value}"

  if [[ -z "${node_name}" || -z "${archive}" ]]; then
    echo -e "\033[0;33merror: --user and --key-file are both required for --import\033[0m\n"
    usage; exit 1
  fi

  if [[ ! -f "${archive}" ]]; then
    echo -e "\033[0;31merror\033[0m: Key archive '${archive}' not found."
    exit 1
  fi

  local _node_layout _node_data_dir
  resolve_node "${node_name}" || exit 1

  if [[ "${config[quiet_mode]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mWARNING: This will replace the current key for '${node_name}' (${_node_layout} layout).\033[0m"
    if [[ ! -t 0 ]]; then
      echo -e "No TTY detected — use --quiet (-q) to skip confirmation in non-interactive mode."
      exit 1
    fi
    while true; do
      read -rp $'\nProceed? [y/N]: ' yn || { echo "Aborted."; exit 0; }
      yn="${yn:-N}"
      case "${yn}" in
        [Yy]*) break ;;
        [Nn]*) echo "Aborted."; exit 0 ;;
        *) echo "(Please answer Y or N)" ;;
      esac
    done
  fi

  local timestamp; timestamp="$(date +%Y%m%d%H%M%S)"

  echo -e "\n\033[1mStopping '${node_name}'...\033[0m"
  stop_node "${node_name}" "${_node_layout}"

  for _kf in key_bls key_ed25519; do
    if [[ -f "${_node_data_dir}/${_kf}" ]]; then
      sudo mv "${_node_data_dir}/${_kf}" "${_node_data_dir}/${_kf}.bak.${timestamp}"
      echo -e "  Existing ${_kf} backed up"
    fi
  done

  echo -e "\033[1mImporting key...\033[0m"
  sudo mkdir -p "${_node_data_dir}"
  sudo tar -xzf "${archive}" -C "${_node_data_dir}"

  local owner
  if [[ "${_node_layout}" = "canonical" ]]; then
    owner="xeqm:xeqm"
  else
    owner="${node_name}:${node_name}"
  fi
  for _kf in key_bls key_ed25519; do
    if [[ -f "${_node_data_dir}/${_kf}" ]]; then
      sudo chown "${owner}" "${_node_data_dir}/${_kf}"
      sudo chmod 600 "${_node_data_dir}/${_kf}"
    fi
  done

  echo -e "\n\033[1;32mKey imported successfully.\033[0m"
  echo -e "\nStarting '${node_name}'..."
  start_node "${node_name}" "${_node_layout}"

  echo -e "\n\033[1mNext step:\033[0m The daemon is running with the imported key."
  echo -e "If this is a new server, re-register the node with:"
  echo -e "  sudo bash ${script_basedir}/register.sh"
}

# ── local transfer ────────────────────────────────────────────────────────────

local_transfer() {
  local from_node="${from_user_option_value}"
  local to_node="${to_user_option_value}"

  if [[ -z "${from_node}" || -z "${to_node}" ]]; then
    echo -e "\033[0;33merror: --from and --to are both required for --transfer\033[0m\n"
    usage; exit 1
  fi

  local _node_layout _node_data_dir
  resolve_node "${from_node}" || exit 1
  local from_layout="${_node_layout}" from_dir="${_node_data_dir}"

  resolve_node "${to_node}" || exit 1
  local to_layout="${_node_layout}" to_dir="${_node_data_dir}"

  local -a key_files=()
  if [[ -f "${from_dir}/key_bls" ]];     then key_files+=("key_bls");     fi
  if [[ -f "${from_dir}/key_ed25519" ]]; then key_files+=("key_ed25519"); fi

  if [[ "${#key_files[@]}" -eq 0 ]]; then
    echo -e "\033[0;31merror\033[0m: No key files (key_bls, key_ed25519) found for '${from_node}'."
    exit 1
  fi

  if [[ "${config[quiet_mode]}" -eq 0 ]]; then
    echo -e "\n\033[0;33mThis will transfer the key from '${from_node}' to '${to_node}'.\033[0m"
    echo -e "The '${to_node}' node will be stopped during the transfer.\n"
    if [[ ! -t 0 ]]; then
      echo -e "No TTY detected — use --quiet (-q) to skip confirmation in non-interactive mode."
      exit 1
    fi
    while true; do
      read -rp "Proceed? [y/N]: " yn || { echo "Aborted."; exit 0; }
      yn="${yn:-N}"
      case "${yn}" in
        [Yy]*) break ;;
        [Nn]*) echo "Aborted."; exit 0 ;;
        *) echo "(Please answer Y or N)" ;;
      esac
    done
  fi

  echo -e "\n\033[1mTransferring key from '${from_node}' to '${to_node}'...\033[0m"
  echo -e "  Key files: ${key_files[*]}"

  local tmp_archive; tmp_archive="$(mktemp /tmp/xeqm-transfer-XXXXXX.tar.gz)"
  sudo tar -czf "${tmp_archive}" -C "${from_dir}" "${key_files[@]}"

  echo -e "  Stopping '${to_node}' daemon..."
  stop_node "${to_node}" "${to_layout}"

  local timestamp; timestamp="$(date +%Y%m%d%H%M%S)"

  for _kf in key_bls key_ed25519; do
    if [[ -f "${to_dir}/${_kf}" ]]; then
      sudo mv "${to_dir}/${_kf}" "${to_dir}/${_kf}.bak.${timestamp}"
      echo -e "  Existing ${_kf} backed up"
    fi
  done

  sudo mkdir -p "${to_dir}"
  sudo tar -xzf "${tmp_archive}" -C "${to_dir}"

  local to_owner
  if [[ "${to_layout}" = "canonical" ]]; then
    to_owner="xeqm:xeqm"
  else
    to_owner="${to_node}:${to_node}"
  fi
  for _kf in key_bls key_ed25519; do
    if [[ -f "${to_dir}/${_kf}" ]]; then
      sudo chown "${to_owner}" "${to_dir}/${_kf}"
      sudo chmod 600 "${to_dir}/${_kf}"
    fi
  done

  sudo rm -f "${tmp_archive}"

  echo -e "\n\033[1;32mKey transferred successfully.\033[0m"
  echo -e "\nStarting '${to_node}' daemon..."
  start_node "${to_node}" "${to_layout}"
}

# ── usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<USAGEMSG

bash $0 [COMMAND] [OPTIONS...]

Commands:
  --list                          List all active service nodes and their public keys.

  --export                        Export a node's key to a portable archive.
    -u --user [node]              Node name to export (e.g. snode1).
    -o --output-dir [path]        Directory to write the archive (default: current dir).

  --import                        Import a key archive into a node.
    -u --user [node]              Target node to receive the key (e.g. snode2).
    -k --key-file [path]          Path to the .tar.gz archive produced by --export.

  --transfer                      Transfer a key between two nodes on this server.
    -f --from [node]              Source node (e.g. snode1).
    -t --to   [node]              Destination node (e.g. snode2).

Global Options:
  -q --quiet                      Non-interactive: skip confirmation prompts.
  -h --help                       Show this help text.

Examples:
  # See all nodes and keys
  bash $0 --list

  # Export snode1's key for migration to another server
  bash $0 --export --user snode1 --output-dir /tmp

  # Import on the new server
  bash $0 --import --user snode2 --key-file /tmp/xeqm-key-snode1-20260513120000.tar.gz

  # Move key from snode1 to snode3 on the same server
  bash $0 --transfer --from snode1 --to snode3

USAGEMSG
}

finally() {
  result=$?
  echo ""
  exit "${result}"
}
trap finally EXIT ERR INT

main "${@}"
exit 0
