#!/usr/bin/env bash
# ==============================================================================
# Nextcloud LXC Creator for Proxmox VE
# Run this script in the Proxmox host shell.
# It creates an LXC container and installs Nextcloud inside it.
# ==============================================================================

# ------------------------------------------------------------------------------
# Colour & formatting helpers (same palette as community-scripts)
# ------------------------------------------------------------------------------
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BOLD=$(echo "\033[1m")
BFR="\\r\\033[K"
HOLD=" ⠋ "

msg_info()  { local m="$1"; echo -ne " ${HOLD} ${YW}${m}...${CL}"; }
msg_ok()    { local m="$1"; echo -e "${BFR} ${GN}✓${CL} ${m}"; }
msg_error() { local m="$1"; echo -e "${BFR} ${RD}✗ ERROR: ${m}${CL}"; exit 1; }
msg_warn()  { local m="$1"; echo -e " ${YW}⚠ ${m}${CL}"; }

header_info() {
cat <<'EOF'

    _   __           __           __________                __
   / | / /__  _  __ / /________  / ____/ __ \____  __  __ / /_
  /  |/ / _ \| |/_// __/ ___/ / / /   / / / / __ \/ / / / __/
 / /|  /  __/>  < / /_/ /__/ /_/ /___/ /_/ / /_/ / /_/ / /_
/_/ |_/\___/_/|_| \__/\___/\____/\____\____/\____/\__,_/\__/

                  LXC Creator for Proxmox VE
EOF
  echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
}

# ------------------------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------------------------
check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "This script must be run as root on the Proxmox host."
  fi
}

check_proxmox() {
  if ! command -v pct &>/dev/null; then
    msg_error "pct not found. Run this script on a Proxmox VE host shell."
  fi
}

# ------------------------------------------------------------------------------
# Template helpers
# ------------------------------------------------------------------------------
find_debian_template() {
  # Returns the most recent Debian 12 template path available on local storage
  local tpl
  tpl=$(find /var/lib/vz/template/cache /var/lib/pve/local-btrfs/template/cache \
        -maxdepth 1 -name "debian-12-standard*.tar.*" 2>/dev/null \
        | sort -V | tail -n1)
  echo "$tpl"
}

download_template() {
  msg_info "Downloading Debian 12 LXC template"
  pveam update &>/dev/null
  local tpl_name
  tpl_name=$(pveam available --section system 2>/dev/null \
             | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)
  if [[ -z "$tpl_name" ]]; then
    msg_error "Could not find a Debian 12 template in pveam. Check your repository settings."
  fi
  pveam download local "$tpl_name" &>/dev/null
  msg_ok "Template downloaded: $tpl_name"
  find_debian_template
}

get_template() {
  local tpl
  tpl=$(find_debian_template)
  if [[ -z "$tpl" ]]; then
    msg_warn "No Debian 12 template found locally."
    tpl=$(download_template)
  fi
  if [[ -z "$tpl" ]]; then
    msg_error "Could not obtain a Debian 12 template."
  fi
  echo "$tpl"
}

# ------------------------------------------------------------------------------
# Next available CT ID
# ------------------------------------------------------------------------------
next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null || \
    awk '/^\[/ {id=substr($0,2,length($0)-2)} END{print id+1}' \
      /etc/pve/lxc/*.conf 2>/dev/null || echo 100
}

# ------------------------------------------------------------------------------
# Available storages for rootfs
# ------------------------------------------------------------------------------
list_storages() {
  pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $2=="active" {print $1}'
}

# ------------------------------------------------------------------------------
# Interactive setup
# ------------------------------------------------------------------------------
simple_setup() {
  echo
  echo -e "${BOLD}  Quick Setup — press Enter to accept defaults${CL}"
  echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo

  DEFAULT_CTID=$(next_ctid)
  read -p "  Container ID [$DEFAULT_CTID]: " CTID
  CTID=${CTID:-$DEFAULT_CTID}

  read -p "  Hostname [nextcloud]: " CT_HOSTNAME
  CT_HOSTNAME=${CT_HOSTNAME:-nextcloud}

  read -s -p "  Root password [random]: " CT_PASSWORD; echo
  if [[ -z "$CT_PASSWORD" ]]; then
    CT_PASSWORD=$(tr -dc 'A-Za-z0-9!@#' </dev/urandom | head -c 16)
    echo -e "  ${YW}Generated root password: ${BOLD}${CT_PASSWORD}${CL}"
  fi

  read -p "  Disk size in GB [20]: " DISK_SIZE
  DISK_SIZE=${DISK_SIZE:-20}

  read -p "  CPU cores [2]: " CT_CPU
  CT_CPU=${CT_CPU:-2}

  read -p "  RAM in MB [2048]: " CT_RAM
  CT_RAM=${CT_RAM:-2048}

  # Storage selection
  local storages
  storages=$(list_storages)
  if [[ -z "$storages" ]]; then
    msg_error "No active storages with rootdir content found."
  fi
  local default_storage
  default_storage=$(echo "$storages" | head -n1)
  echo "  Available storages: $(echo $storages | tr '\n' ' ')"
  read -p "  Storage [$default_storage]: " CT_STORAGE
  CT_STORAGE=${CT_STORAGE:-$default_storage}

  read -p "  Network bridge [vmbr0]: " CT_BRIDGE
  CT_BRIDGE=${CT_BRIDGE:-vmbr0}

  read -p "  IP config — type 'dhcp' or e.g. 192.168.1.50/24 [dhcp]: " CT_IP
  CT_IP=${CT_IP:-dhcp}

  if [[ "$CT_IP" != "dhcp" ]]; then
    read -p "  Gateway (required for static IP): " CT_GW
  fi

  read -p "  Unprivileged container? (yes/no) [yes]: " CT_UNPRIV
  CT_UNPRIV=${CT_UNPRIV:-yes}
  [[ "$CT_UNPRIV" == "yes" ]] && UNPRIV_FLAG=1 || UNPRIV_FLAG=0
}

advanced_setup() {
  simple_setup  # start with the basic questions, then add extras below
  echo
  echo -e "${BOLD}  Advanced Options${CL}"
  echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"

  read -p "  VLAN tag (leave blank for none): " CT_VLAN

  read -p "  DNS server (leave blank for host default): " CT_DNS

  read -p "  Mount extra storage into /mnt/extra? (yes/no) [no]: " EXTRA_MNT
  if [[ "${EXTRA_MNT:-no}" == "yes" ]]; then
    local ext_storages
    ext_storages=$(list_storages)
    echo "  Available storages: $(echo $ext_storages | tr '\n' ' ')"
    read -p "  Storage name for /mnt/extra: " EXTRA_STORAGE
    read -p "  Size in GB for /mnt/extra [50]: " EXTRA_SIZE
    EXTRA_SIZE=${EXTRA_SIZE:-50}
  fi
}

# ------------------------------------------------------------------------------
# Build network string for pct create
# ------------------------------------------------------------------------------
build_net_string() {
  local net="name=eth0,bridge=${CT_BRIDGE}"
  if [[ "$CT_IP" == "dhcp" ]]; then
    net+=",ip=dhcp"
  else
    net+=",ip=${CT_IP}"
    [[ -n "${CT_GW:-}" ]] && net+=",gw=${CT_GW}"
  fi
  [[ -n "${CT_VLAN:-}" ]] && net+=",tag=${CT_VLAN}"
  echo "$net"
}

# ------------------------------------------------------------------------------
# Create the container
# ------------------------------------------------------------------------------
create_container() {
  local template
  template=$(get_template)

  msg_info "Creating LXC container ${CTID}"

  local net_str
  net_str=$(build_net_string)

  local pct_args=(
    "$CTID" "$template"
    --hostname    "$CT_HOSTNAME"
    --password    "$CT_PASSWORD"
    --cores       "$CT_CPU"
    --memory      "$CT_RAM"
    --swap        512
    --rootfs      "${CT_STORAGE}:${DISK_SIZE}"
    --net0        "$net_str"
    --unprivileged "$UNPRIV_FLAG"
    --features    nesting=1
    --onboot      1
    --start       0
  )

  [[ -n "${CT_DNS:-}" ]] && pct_args+=(--nameserver "$CT_DNS")

  pct create "${pct_args[@]}" &>/dev/null
  msg_ok "Container ${CTID} created"

  # Optional extra mount point
  if [[ "${EXTRA_MNT:-no}" == "yes" && -n "${EXTRA_STORAGE:-}" ]]; then
    msg_info "Adding extra storage mount"
    pct set "$CTID" --mp0 "${EXTRA_STORAGE}:${EXTRA_SIZE},mp=/mnt/extra" &>/dev/null
    msg_ok "Extra storage mounted at /mnt/extra"
  fi
}

# ------------------------------------------------------------------------------
# Start container and copy installer inside
# ------------------------------------------------------------------------------
start_and_provision() {
  msg_info "Starting container ${CTID}"
  pct start "$CTID"
  sleep 5  # give networking a moment

  # Wait for the container to be fully up (max 30s)
  local retries=0
  until pct exec "$CTID" -- true &>/dev/null || (( retries++ > 29 )); do sleep 1; done
  msg_ok "Container ${CTID} is running"

  # Push the installer script into the container
  local installer_src
  # Look for the installer next to this script, then fall back to /tmp
  installer_src="$(dirname "$(realpath "$0")")/nextcloud_installer_en.sh"
  if [[ ! -f "$installer_src" ]]; then
    installer_src="/tmp/nextcloud_installer_en.sh"
  fi

  if [[ -f "$installer_src" ]]; then
    msg_info "Copying Nextcloud installer into container"
    pct push "$CTID" "$installer_src" /root/nextcloud_installer.sh
    pct exec "$CTID" -- chmod +x /root/nextcloud_installer.sh
    msg_ok "Installer copied to /root/nextcloud_installer.sh"
    INSTALLER_READY=true
  else
    msg_warn "nextcloud_installer_en.sh not found alongside this script or in /tmp."
    msg_warn "You will need to copy it into the container manually."
    INSTALLER_READY=false
  fi
}

# ------------------------------------------------------------------------------
# Print summary
# ------------------------------------------------------------------------------
print_summary() {
  echo
  echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "${GN}${BOLD}  ✓ LXC Container created and started${CL}"
  echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo
  echo -e "  ${BOLD}Container ID:${CL}   ${CTID}"
  echo -e "  ${BOLD}Hostname:${CL}       ${CT_HOSTNAME}"
  echo -e "  ${BOLD}CPU / RAM:${CL}      ${CT_CPU} cores / ${CT_RAM} MB"
  echo -e "  ${BOLD}Disk:${CL}           ${DISK_SIZE} GB on ${CT_STORAGE}"
  echo -e "  ${BOLD}Network:${CL}        ${CT_BRIDGE} — IP: ${CT_IP}"
  echo -e "  ${BOLD}Unprivileged:${CL}   $([[ $UNPRIV_FLAG -eq 1 ]] && echo Yes || echo No)"
  echo
  if [[ "${INSTALLER_READY:-false}" == "true" ]]; then
    echo -e "  ${BOLD}Next step — run Nextcloud installer inside the container:${CL}"
    echo
    echo -e "    ${YW}pct enter ${CTID}${CL}"
    echo -e "    ${YW}bash /root/nextcloud_installer.sh${CL}"
  else
    echo -e "  ${BOLD}Next step:${CL}"
    echo -e "    Copy nextcloud_installer_en.sh into the container, then:"
    echo -e "    ${YW}pct enter ${CTID}${CL}"
    echo -e "    ${YW}bash /root/nextcloud_installer.sh${CL}"
  fi
  echo
  echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  header_info
  check_root
  check_proxmox

  echo
  echo -e "  ${BOLD}This script will create a Debian 12 LXC container${CL}"
  echo -e "  ${BOLD}and prepare it for Nextcloud installation.${CL}"
  echo
  echo -e "  ${YW}1)${CL} Quick setup  (sensible defaults, minimal questions)"
  echo -e "  ${YW}2)${CL} Advanced setup  (VLAN, extra storage, DNS, etc.)"
  echo -e "  ${YW}3)${CL} Exit"
  echo
  read -p "  Choose [1]: " MODE
  MODE=${MODE:-1}

  case "$MODE" in
    1) simple_setup ;;
    2) advanced_setup ;;
    3) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac

  echo
  echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "  ${BOLD}Summary of container to be created:${CL}"
  echo
  echo -e "    CT ID:      ${CTID}"
  echo -e "    Hostname:   ${CT_HOSTNAME}"
  echo -e "    Disk:       ${DISK_SIZE} GB on ${CT_STORAGE}"
  echo -e "    CPU:        ${CT_CPU} cores"
  echo -e "    RAM:        ${CT_RAM} MB"
  echo -e "    Network:    ${CT_BRIDGE} — ${CT_IP}"
  echo -e "    Privilege:  $([[ $UNPRIV_FLAG -eq 1 ]] && echo Unprivileged || echo Privileged)"
  echo
  read -p "  Press Enter to create the container, or Ctrl+C to cancel."

  create_container
  start_and_provision
  print_summary
}

main "$@"
