#!/usr/bin/env bash
# Migrates running XEQM Docker service nodes to native systemd-managed services.

set -euo pipefail

script_basedir=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
readonly script_basedir

source "${script_basedir}/common.sh"
source "${script_basedir}/discovery.sh"

declare -A system_info
declare -A mdata

STAGING_DIR="/tmp/xeqm-migration-$$"
readonly STAGING_DIR

main() {
  install_migration_dependencies
  [[ "${XEQM_FROM_MENU:-0}" != "1" ]] && print_splash_screen "Docker Migration" "${xeqmnode_installer_version}"
  discover_system system_info

  local -a cids=()
  find_xeqm_docker_containers cids

  if [[ ${#cids[@]} -eq 0 ]]; then
    echo -e "\n\033[0;33mNo running XEQM Docker service node containers found on this host.\033[0m"
    echo -e "Ensure containers running xeqm-d --service-node are active and try again.\n"
    exit 0
  fi

  echo -e "\n\033[1mFound ${#cids[@]} running XEQM service node container(s). Collecting details...\033[0m"
  for cid in "${cids[@]}"; do
    collect_container_details "${cid}"
  done

  sort_containers_by_node_number cids
  resolve_target_usernames cids
  display_container_table cids

  local -a selected=()
  prompt_container_selection cids selected

  local dry_run=0
  prompt_dry_run_choice dry_run

  prompt_service_node_public_ip

  prompt_firewall_mode

  prompt_one_passwd_file

  if [[ "${dry_run}" -eq 1 ]]; then
    show_dry_run selected
    exit 0
  fi

  confirm_migration selected

  mkdir -p "${STAGING_DIR}"

  echo -e "\n\033[1mPhase 1 — Copying data from containers (nodes remain live)...\033[0m"
  for cid in "${selected[@]}"; do
    stage_container_data "${cid}"
  done

  local first_cid="${selected[0]}"
  install_shared_binaries "${first_cid}"

  echo -e "\n\033[1mPhase 3 — Cutover (brief downtime per node)...\033[0m"
  for cid in "${selected[@]}"; do
    cutover_node "${cid}" "${first_cid}"
  done

  rm -rf "${STAGING_DIR}"
  show_post_migration_steps selected
  echo -e "\n\033[1mMigration complete. Goodbye!\033[0m\n"
}

install_migration_dependencies() {
  if ! command -v docker &>/dev/null; then
    echo -e "\033[0;31mERROR: Docker is not installed or not in PATH.\033[0m"
    exit 1
  fi
  if ! docker info &>/dev/null; then
    echo -e "\033[0;31mERROR: Docker daemon is not running or you lack permission.\033[0m"
    exit 1
  fi
  local missing=()
  command -v curl   &>/dev/null || missing+=(curl)
  command -v wget   &>/dev/null || missing+=(wget)
  command -v file   &>/dev/null || missing+=(file)
  command -v unzip  &>/dev/null || missing+=(unzip)
  command -v natsort &>/dev/null || missing+=(python3-natsort)
  command -v gawk   &>/dev/null || missing+=(gawk)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "\n\033[1mInstalling required tools: ${missing[*]}...\033[0m"
    sudo apt-get -y install "${missing[@]}"
  fi
}

find_xeqm_docker_containers() {
  local -n fxdc__result="$1"
  local idx=0
  while IFS= read -r cid; do
    [[ -n "${cid}" ]] && fxdc__result[${idx}]="${cid}" && idx=$((idx + 1))
  done < <(docker ps -q 2>/dev/null | while read -r id; do
    if docker inspect "${id}" \
        --format '{{join .Config.Cmd " "}} {{join .Config.Entrypoint " "}}' 2>/dev/null \
        | grep -qE '\bxeqm-d\b'; then
      echo "${id}"
    fi
  done)
}

collect_container_details() {
  local cid="$1"

  local name
  name="$(docker inspect "${cid}" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')"
  mdata["${cid}__name"]="${name}"

  local cmd
  cmd="$(docker inspect "${cid}" \
    --format '{{join .Config.Cmd " "}} {{join .Config.Entrypoint " "}}' 2>/dev/null)"

  local p2p_int="" rpc_int="" quorum_int="" data_dir=""

  # If daemon uses a config file, read ports and data-dir from it
  local conf_file
  conf_file="$(echo "${cmd}" | grep -oP '(?<=--config-file=)\S+' || true)"
  if [[ -n "${conf_file}" ]]; then
    local conf_content
    conf_content="$(docker exec "${cid}" cat "${conf_file}" 2>/dev/null || true)"
    p2p_int="$(echo "${conf_content}"    | grep -oP '^p2p-bind-port=\K[0-9]+'  || true)"
    rpc_int="$(echo "${conf_content}"    | grep -oP '^rpc-admin=\S+:\K[0-9]+'  || true)"
    quorum_int="$(echo "${conf_content}" | grep -oP '^quorumnet-port=\K[0-9]+' || true)"
    data_dir="$(echo "${conf_content}"   | grep -oP '^data-dir=\K\S+'          || true)"
  fi

  # Fall back to command-line flags if config file didn't provide everything
  [[ -z "${p2p_int}" ]] && \
    p2p_int="$(echo "${cmd}"    | grep -oP '(?<=--p2p-bind-port[= ])[0-9]+'   || true)"
  [[ -z "${rpc_int}" ]] && \
    rpc_int="$(echo "${cmd}"    | grep -oP '(?<=--rpc-admin=\S+:)[0-9]+'      || true)"
  [[ -z "${rpc_int}" ]] && \
    rpc_int="$(echo "${cmd}"    | grep -oP '(?<=--rpc-bind-port[= ])[0-9]+'   || true)"
  [[ -z "${quorum_int}" ]] && \
    quorum_int="$(echo "${cmd}" | grep -oP '(?<=--quorumnet-port[= ])[0-9]+'  || true)"

  # Verify or discover data directory (config-derived takes priority)
  if [[ -z "${data_dir}" ]] || ! docker exec "${cid}" test -d "${data_dir}/lmdb" 2>/dev/null; then
    for candidate in /data /root/.xeqmlabs /home/snode/.xeqmlabs /home/xeqm/.xeqmlabs; do
      if docker exec "${cid}" test -d "${candidate}/lmdb" 2>/dev/null; then
        data_dir="${candidate}"
        break
      fi
    done
  fi
  mdata["${cid}__data_dir"]="${data_dir}"

  # Host path of the bind mount for the data directory (used in cleanup instructions)
  local mount_source=""
  if [[ -n "${data_dir}" ]]; then
    mount_source="$(docker inspect "${cid}" \
      --format "{{range .Mounts}}{{if eq .Destination \"${data_dir}\"}}{{.Source}}{{end}}{{end}}" \
      2>/dev/null || true)"
  fi
  mdata["${cid}__mount_source"]="${mount_source}"

  # With --network host, container ports == host ports; docker port returns nothing
  mdata["${cid}__p2p"]="${p2p_int:-?}"
  mdata["${cid}__rpc"]="${rpc_int:-?}"
  mdata["${cid}__quorum"]="${quorum_int:-?}"

  # Blockchain height from HTTP RPC (accessible on localhost with host networking)
  local height="?"
  if [[ "${rpc_int:-}" =~ ^[0-9]+$ ]]; then
    height="$(curl -s --connect-timeout 2 "http://127.0.0.1:${rpc_int}/get_info" 2>/dev/null \
      | grep -o '"height":[0-9]*' | head -1 | cut -d: -f2)" || height="?"
  fi
  mdata["${cid}__height"]="${height:-?}"

  # Derive target username from container name (e.g. xeqm-snode3 → snode3)
  local target_user
  target_user="$(echo "${name}" | grep -oiP 'snode[0-9]+' | head -1 || true)"
  [[ -z "${target_user}" ]] && target_user="__auto__"
  mdata["${cid}__target_user"]="${target_user}"
}

resolve_target_usernames() {
  local -n rtu__cids="$1"
  local auto_count=0
  for cid in "${rtu__cids[@]}"; do
    [[ "${mdata["${cid}__target_user"]}" = "__auto__" ]] && auto_count=$((auto_count + 1))
  done
  [[ "${auto_count}" -eq 0 ]] && return 0

  declare -A avail_names
  discover_available_usernames avail_names "${auto_count}" "${config[running_user]}"
  local avail_idx=1
  for cid in "${rtu__cids[@]}"; do
    if [[ "${mdata["${cid}__target_user"]}" = "__auto__" ]]; then
      mdata["${cid}__target_user"]="${avail_names[${avail_idx}]}"
      avail_idx=$((avail_idx + 1))
    fi
  done
}

sort_containers_by_node_number() {
  local -n scbn__cids="$1"
  local -a pairs=()
  for cid in "${scbn__cids[@]}"; do
    local num
    num="$(echo "${mdata["${cid}__name"]}" | grep -oP '[0-9]+$' || echo "999999")"
    pairs+=("${num} ${cid}")
  done
  local -a sorted=()
  while IFS= read -r line; do
    sorted+=("${line#* }")
  done < <(printf '%s\n' "${pairs[@]}" | sort -n)
  scbn__cids=("${sorted[@]}")
}

display_container_table() {
  local -n dct__cids="$1"
  echo ""
  printf "  \033[1m%-5s %-26s %-7s %-7s %-7s %-12s %-20s\033[0m\n" \
    "#" "Container" "P2P" "RPC" "Quorum" "Height" "Target User"
  printf "  %-5s %-26s %-7s %-7s %-7s %-12s %-20s\n" \
    "─────" "──────────────────────────" "───────" "───────" "───────" "────────────" "────────────────────"
  local idx=1
  for cid in "${dct__cids[@]}"; do
    printf "  %-5s %-26s %-7s %-7s %-7s %-12s %-20s\n" \
      "[${idx}]" \
      "${mdata["${cid}__name"]}" \
      "${mdata["${cid}__p2p"]}" \
      "${mdata["${cid}__rpc"]}" \
      "${mdata["${cid}__quorum"]}" \
      "${mdata["${cid}__height"]}" \
      "${mdata["${cid}__target_user"]}"
    idx=$((idx + 1))
  done
  echo ""
}

prompt_container_selection() {
  local -n pcs__all="$1"
  local -n pcs__sel="$2"
  local total="${#pcs__all[@]}"

  local choice
  prompt_menu "Which nodes would you like to migrate?" choice 1 \
    "All ${total} nodes" \
    "First N nodes (you specify how many)" \
    "Specific nodes (enter numbers)"

  case "${choice}" in
    1) pcs__sel=("${pcs__all[@]}") ;;
    2)
      local n
      while true; do
        read -rp $'\n\033[1mHow many (first N)?\e[0m [1]: ' n
        n="${n:-1}"
        if [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge 1 && "${n}" -le "${total}" ]]; then
          pcs__sel=("${pcs__all[@]:0:${n}}")
          break
        fi
        echo -e "  \033[0;33mEnter a number between 1 and ${total}\033[0m"
      done
      ;;
    3)
      echo -e "\n  Enter node numbers separated by spaces or commas (e.g.  1 2 3  or  1,3,5):"
      local raw
      read -rp "  Numbers: " raw
      local -a nums
      read -ra nums <<< "${raw//,/ }"
      for n in "${nums[@]}"; do
        if [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge 1 && "${n}" -le "${total}" ]]; then
          pcs__sel+=("${pcs__all[$((n-1))]}")
        fi
      done
      if [[ ${#pcs__sel[@]} -eq 0 ]]; then
        echo -e "  \033[0;33mNo valid nodes selected. Exiting.\033[0m"
        exit 1
      fi
      ;;
  esac
  echo -e "\n  \033[1mSelected ${#pcs__sel[@]} node(s) for migration.\033[0m"
}

prompt_dry_run_choice() {
  local -n pdr__result="$1"
  local choice
  prompt_menu "Would you like a dry run first?" choice 1 \
    "Yes — show migration plan, make no changes" \
    "No  — proceed with migration now"
  [[ "${choice}" -eq 1 ]] && pdr__result=1 || pdr__result=0
}


show_dry_run() {
  local -n sdr__sel="$1"
  echo -e "\n\033[1;33m  DRY RUN — no changes will be made\033[0m"
  printf "  %s\n\n" "$(printf '─%.0s' $(seq 1 60))"
  local idx=1
  for cid in "${sdr__sel[@]}"; do
    local name="${mdata["${cid}__name"]}"
    local user="${mdata["${cid}__target_user"]}"
    local p2p="${mdata["${cid}__p2p"]}"
    local rpc="${mdata["${cid}__rpc"]}"
    local quorum="${mdata["${cid}__quorum"]}"
    local data_dir="${mdata["${cid}__data_dir"]:-not found}"
    echo -e "  \033[1mNode ${idx}: ${name}\033[0m"
    printf "    %-28s %s\n"   "System user to create:"      "${user}"
    printf "    %-28s p2p=%s  rpc=%s  quorum=%s\n" "Ports (reused from Docker):" "${p2p}" "${rpc}" "${quorum}"
    printf "    %-28s container:%s/lmdb\n" "Blockchain source:"  "${data_dir}"
    printf "    %-28s container:%s/ (excl. lmdb)\n" "Keys/state source:" "${data_dir}"
    printf "    %-28s xeqmnode_%s.service\n" "Systemd service:"   "${user}"
    echo ""
    idx=$((idx + 1))
  done
  echo -e "  \033[1mSummary:\033[0m"
  echo -e "    - ${#sdr__sel[@]} system user(s) will be created"
  echo -e "    - Blockchain is copied before Docker stops (no re-sync needed)"
  echo -e "    - Containers stopped one at a time during cutover"
  echo -e "    - Estimated downtime per node: < 60 seconds"

  if [[ "${config[firewall_mode]:-}" = "external" ]]; then
    local -a entries=()
    for cid in "${sdr__sel[@]}"; do
      entries+=("${mdata["${cid}__target_user"]} ${mdata["${cid}__p2p"]} ${mdata["${cid}__quorum"]}")
    done
    print_external_firewall_guidance "${entries[@]}"
  else
    echo -e "\n  Firewall: ${config[firewall_mode]:-ufw} will be configured automatically.\n"
  fi
  show_docker_cleanup_instructions sdr__sel 1

  echo -e "  Run again and choose 'No' at the dry run prompt to execute.  bash migrate.sh\n"
}

show_docker_cleanup_instructions() {
  local -n sdci__sel="$1"
  local is_dry_run="${2:-0}"

  if [[ "${is_dry_run}" -eq 1 ]]; then
    echo -e "\n\033[1mPost-migration cleanup plan\033[0m (shown again after migration completes):"
  else
    tput rev 2>/dev/null || true; echo -e "\n\033[1m DOCKER CLEANUP — run after confirming systemd nodes are healthy \033[0m"; tput sgr0 2>/dev/null || true
  fi
  printf "  %s\n\n" "$(printf '─%.0s' $(seq 1 60))"

  echo -e "  \033[1mStep 1 — Verify each migrated service is running:\033[0m"
  for cid in "${sdci__sel[@]}"; do
    local user="${mdata["${cid}__target_user"]}"
    echo -e "    sudo systemctl status xeqmnode_${user}.service"
  done

  echo -e "\n  \033[1mStep 2 — Remove the stopped Docker containers:\033[0m"
  local names=()
  for cid in "${sdci__sel[@]}"; do
    names+=("${mdata["${cid}__name"]}")
  done
  echo -e "    docker rm ${names[*]}"

  echo -e "\n  \033[1mStep 3 — Remove Docker data directories:\033[0m"
  echo -e "  \033[0;33m  Blockchain data has been copied to /home/<user>/.xeqmlabs — originals are no longer needed.\033[0m"
  echo -e "  \033[0;33m  Only run after Step 1 confirms the systemd nodes are healthy.\033[0m"
  for cid in "${sdci__sel[@]}"; do
    local user="${mdata["${cid}__target_user"]}"
    local mount="${mdata["${cid}__mount_source"]:-}"
    if [[ -n "${mount}" ]]; then
      echo -e "    sudo rm -rf ${mount}"
    else
      echo -e "    # ${mdata["${cid}__name"]}: docker inspect ${mdata["${cid}__name"]} --format '{{range .Mounts}}{{.Source}} {{end}}'"
    fi
  done

  local image
  image="$(docker inspect "${sdci__sel[0]}" --format '{{.Config.Image}}' 2>/dev/null || true)"
  echo -e "\n  \033[1mStep 4 — Optional: remove the Docker image if no Docker nodes remain:\033[0m"
  echo -e "    docker rmi ${image:-<image-name>}"
  echo ""
}

confirm_migration() {
  local -n cm__sel="$1"
  echo -e "\n\033[1;33m  Ready to migrate ${#cm__sel[@]} node(s). Docker containers will be stopped.\033[0m"
  local yn
  while true; do
    read -rp $'\n\033[1mProceed?\e[0m [Y/n]: ' yn
    yn="${yn:-Y}"
    case "${yn}" in
      [Yy]*) break ;;
      [Nn]*) echo -e "\nMigration cancelled."; exit 0 ;;
      *) echo -e "  \033[0;33mPlease answer Y or N\033[0m" ;;
    esac
  done
}

stage_container_data() {
  local cid="$1"
  local name="${mdata["${cid}__name"]}"
  local data_dir="${mdata["${cid}__data_dir"]}"
  local staging="${STAGING_DIR}/${cid}"

  if [[ -z "${data_dir}" ]]; then
    echo -e "  \033[0;31mERROR: Could not find .xeqmlabs data dir in '${name}'. Skipping.\033[0m"
    mdata["${cid}__staged"]="0"
    return 1
  fi

  echo -e "\n  \033[1mStaging '${name}'...\033[0m"
  mkdir -p "${staging}"

  echo -e "    Copying blockchain (lmdb)..."
  if ! docker cp "${cid}:${data_dir}/lmdb" "${staging}/"; then
    echo -e "    \033[0;31mFailed to copy blockchain. Skipping '${name}'.\033[0m"
    mdata["${cid}__staged"]="0"
    return 1
  fi

  echo -e "    Copying keys and state files..."
  local f
  while IFS= read -r f; do
    [[ "${f}" = "${data_dir}" ]] && continue
    local base
    base="$(basename "${f}")"
    # Skip lmdb (handled above), config files (Docker-specific paths would break systemd),
    # and log files (not needed and can be large)
    case "${base}" in
      lmdb|*.conf|*.log|*.log.*) continue ;;
    esac
    docker cp "${cid}:${f}" "${staging}/" 2>/dev/null || true
  done < <(docker exec "${cid}" find "${data_dir}" -maxdepth 1 2>/dev/null)

  mdata["${cid}__staged"]="1"
  echo -e "    \033[1;32mDone.\033[0m"
}

install_shared_binaries() {
  local first_cid="$1"
  local first_user="${mdata["${first_cid}__target_user"]}"

  echo -e "\n\033[1mPhase 2 — Installing native binaries...\033[0m"
  create_user_if_needed "${first_user}"
  sudoers_user_nopasswd 'add' "${first_user}"

  local existing_bins=""
  find_existing_binaries_on_server existing_bins

  local pm_choice=1
  if [[ -n "${existing_bins}" ]]; then
    prompt_menu "How would you like to get the XEQM binaries?" pm_choice 1 \
      "Download latest release from GitHub  (recommended)" \
      "Use existing binaries on this server  (${existing_bins})"
  fi

  local bin_target="/home/${first_user}/bin"
  case "${pm_choice}" in
    1)
      config[install_version]="auto"
      version_option_handler "auto"
      local bins_path
      bins_path="$(download_release_binaries)"
      copy_binaries_to_directory "${bins_path}" "${bin_target}"
      rm -rf "$(dirname "${bins_path}")"
      ;;
    2)
      copy_binaries_to_directory "${existing_bins}" "${bin_target}"
      ;;
  esac
  sudo chown -R "${first_user}:${first_user}" "${bin_target}"
}

cutover_node() {
  local cid="$1"
  local first_cid="$2"
  local name="${mdata["${cid}__name"]}"
  local user="${mdata["${cid}__target_user"]}"
  local p2p="${mdata["${cid}__p2p"]}"
  local rpc="${mdata["${cid}__rpc"]}"
  local quorum="${mdata["${cid}__quorum"]}"
  local staging="${STAGING_DIR}/${cid}"
  local first_user="${mdata["${first_cid}__target_user"]}"

  if [[ "${mdata["${cid}__staged"]:-0}" != "1" ]]; then
    echo -e "  \033[0;33mSkipping '${name}' — staging failed.\033[0m"
    return 1
  fi

  echo -e "\n  \033[1mCutover: ${name} → ${user}\033[0m"

  create_user_if_needed "${user}"
  sudoers_user_nopasswd 'add' "${user}"

  # Move staged blockchain and state into user's home
  local data_home="/home/${user}/.xeqmlabs"
  sudo mkdir -p "${data_home}"
  sudo cp -r "${staging}/lmdb" "${data_home}/"
  local f
  while IFS= read -r f; do
    [[ "$(basename "${f}")" = "lmdb" ]] && continue
    sudo cp -r "${f}" "${data_home}/" 2>/dev/null || true
  done < <(find "${staging}" -maxdepth 1 -mindepth 1)
  sudo chown -R "${user}:${user}" "${data_home}"

  # Copy binaries from the first node (already downloaded/installed)
  if [[ "${cid}" != "${first_cid}" ]]; then
    local bin_source="/home/${first_user}/bin"
    local bin_target="/home/${user}/bin"
    copy_binaries_to_directory "${bin_source}" "${bin_target}"
    sudo chown -R "${user}:${user}" "${bin_target}"
  fi

  # Write installer config
  local installer_home="/home/${user}/xeqm-installer"
  [[ -d "${installer_home}" ]] && sudo rm -rf "${installer_home}"
  sudo mkdir "${installer_home}"
  sudo cp "${script_basedir}/xeqm-node.sh" \
          "${script_basedir}/xeqmnode.service.template" \
          "${script_basedir}/common.sh" \
          "${installer_home}/"

  declare -A node_conf
  node_conf=(
    [node_id]=1
    [install_version]="${config[install_version]:-auto}"
    [git_repository]="${config[git_repository]}"
    [running_user]="${user}"
    [p2p_bind_port]="${p2p}"
    [rpc_bind_port]="${rpc}"
    [quorumnet_port]="${quorum}"
    [oxenmq_port]="$((p2p + 3))"
    [copy_blockchain]="no"
    [copy_binaries]="/home/${user}/bin"
    [binary_source]="/home/${user}/bin"
    [daemon_no_fluffy_blocks]=0
    [daemon_log_level]=""
    [service_node_public_ip]="${config[service_node_public_ip]}"
    [open_firewall]="${config[open_firewall]:-0}"
    [firewall_mode]="${config[firewall_mode]:-}"
    [installer_home]="${installer_home}"
  )
  write_config node_conf "${installer_home}/install.conf"
  sudo chown -R "${user}:root" "${installer_home}"

  # Stop Docker — downtime begins
  echo -e "    Stopping Docker container '${name}'..."
  docker stop "${name}" 2>/dev/null || docker stop "${cid}" 2>/dev/null || true

  # Build and install systemd service file, then start.
  # migrate.sh already runs as root, so run xeqm-node.sh directly as root
  # with HOME set to the node user's home — no sudo escalation needed inside.
  echo -e "    Installing systemd service..."
  HOME="/home/${user}" bash "${installer_home}/xeqm-node.sh" setup_service

  local service_name="xeqmnode_${user}.service"
  sudo systemctl enable "${service_name}"
  sudo systemctl start "${service_name}"

  sudoers_user_nopasswd 'remove' "${user}"

  if [[ "${config[open_firewall]:-0}" -eq 1 ]]; then
    echo -e "    Configuring firewall [${config[firewall_mode]:-auto}]..."
    HOME="/home/${user}" bash "${installer_home}/xeqm-node.sh" open_firewall
  fi

  echo -e "    \033[1;32m'${name}' → ${service_name} running.\033[0m"
}

show_post_migration_steps() {
  local -n spms__sel="$1"
  tput rev 2>/dev/null || true; echo -e "\n\033[1m IMPORTANT: COMPLETE THESE STEPS TO FINISH SERVICE NODE SETUP \033[0m"; tput sgr0 2>/dev/null || true
  echo -e "\nIf these nodes were already registered and staked, no further action is needed."
  echo -e "For nodes NOT yet registered, run register.sh to generate the registration command:"
  echo -e "\n  \033[1msudo bash ${script_basedir}/register.sh\033[0m"

  if [[ "${config[firewall_mode]:-}" = "external" ]]; then
    local -a entries=()
    for cid in "${spms__sel[@]}"; do
      entries+=("${mdata["${cid}__target_user"]} ${mdata["${cid}__p2p"]} ${mdata["${cid}__quorum"]}")
    done
    print_external_firewall_guidance "${entries[@]}"
  fi

  show_docker_cleanup_instructions spms__sel 0
}

usage() {
  cat <<USAGEMSG

bash $0

Interactively migrates running XEQM Docker service nodes to native
systemd-managed services on this host.

  - Copies blockchain and keys from containers before stopping them
  - Reuses the same ports as the Docker containers
  - Preserves service node identity (keys)
  - Supports dry run to preview the migration plan

Options:
  -h  --help    Show this help text

USAGEMSG
}

finally() {
  local result=$?
  [[ -d "${STAGING_DIR:-}" ]] && rm -rf "${STAGING_DIR}"
  echo ""
  exit "${result}"
}
trap finally EXIT ERR INT

if [[ "${#}" -ge 1 && ( "$1" = '-h' || "$1" = '--help' ) ]]; then
  usage; exit 0
fi

main "${@}"
exit 0
