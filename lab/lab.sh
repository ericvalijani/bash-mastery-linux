#!/usr/bin/env bash
#
# bash-mastery-linux — lab controller
#
# Stands up and tears down the practice environment. Nothing here is
# simulated: real kernels, real routing tables, real daemons, real SELinux.
#
#   ./lab/lab.sh check              verify this machine can run the lab
#   ./lab/lab.sh image              fetch the Rocky Linux 9 base image
#   ./lab/lab.sh up [vm...]         create VMs        (default: control node1)
#   ./lab/lab.sh status             list VMs and addresses
#   ./lab/lab.sh ssh <vm>           ssh into a VM
#   ./lab/lab.sh push <vm> [path]   copy repo files to ~/lab on a VM
#   ./lab/lab.sh add-disk <vm> [GB] attach a blank disk (Day 4 / LVM)
#   ./lab/lab.sh down [vm...]       delete VMs and their disks
#   ./lab/lab.sh netns-up           build the Day 6-10 network topology
#   ./lab/lab.sh netns-status       show and test the topology
#   ./lab/lab.sh netns-down         remove the topology
#   ./lab/lab.sh destroy            everything: VMs + namespaces
#
# Days 1-5 and 11-15 use VMs. Days 6-10 use network namespaces on this host,
# which cost no RAM at all.
#
# Memory budget on an 8 GB machine:
#   control  1024 MB
#   node1     768 MB
#   node2     768 MB   (only needed on Day 15)

set -euo pipefail

LAB_HOME="${LAB_HOME:-$HOME/.local/share/bash-mastery-linux}"
IMAGE_DIR="$LAB_HOME/images"
DISK_DIR="$LAB_HOME/disks"
SEED_DIR="$LAB_HOME/seed"

BASE_NAME="Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
BASE_URL="${LAB_BASE_URL:-https://dl.rockylinux.org/pub/rocky/9/images/x86_64/$BASE_NAME}"
BASE_IMAGE="$IMAGE_DIR/$BASE_NAME"

LAB_USER="${LAB_USER:-lab}"
LAB_NET="${LAB_NET:-default}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
DISK_SIZE="${LAB_DISK_SIZE:-10G}"

DEFAULT_VMS=(control node1)
ALL_VMS=(control node1 node2)

# --- output -----------------------------------------------------------------

_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
info() { _c '0;36'; printf '==> '; _c '0'; printf '%s\n' "$*"; }
ok()   { _c '0;32'; printf '  ok   '; _c '0'; printf '%s\n' "$*"; }
warn() { _c '0;33'; printf '  warn '; _c '0'; printf '%s\n' "$*"; }
bad()  { _c '0;31'; printf '  FAIL '; _c '0'; printf '%s\n' "$*"; }
die()  { bad "$*"; exit 1; }

# --- helpers ----------------------------------------------------------------

vm_mem() {
  case "$1" in
    control) echo 1024 ;;
    node1|node2) echo 768 ;;
    *) echo 768 ;;
  esac
}

is_known_vm() {
  local v
  for v in "${ALL_VMS[@]}"; do [[ "$v" == "$1" ]] && return 0; done
  return 1
}

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this subcommand needs root: sudo $0 $*"
}

pkg_hint() {
  if command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install -y libvirt virt-install qemu-kvm libvirt-daemon-config-network"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "sudo apt-get install -y libvirt-daemon-system virtinst qemu-kvm"
  elif command -v pacman >/dev/null 2>&1; then
    echo "sudo pacman -S --needed libvirt virt-install qemu-desktop"
  else
    echo "install: libvirt, virt-install, qemu-kvm"
  fi
}

libvirt_unit() {
  # Newer libvirt splits the monolithic daemon into virtqemud etc.
  local u
  for u in libvirtd virtqemud; do
    if systemctl list-unit-files "$u.service" >/dev/null 2>&1 &&
       systemctl is-active --quiet "$u"; then
      echo "$u"; return 0
    fi
  done
  return 1
}

osvariant() {
  local v
  if command -v osinfo-query >/dev/null 2>&1; then
    for v in rocky9 rhel9.0 rhel9-unknown; do
      if osinfo-query -f short-id os 2>/dev/null | tr -d ' ' | grep -qx "$v"; then
        echo "$v"; return 0
      fi
    done
  fi
  echo generic
}

vm_ip() {
  local vm="$1" ip=""
  ip=$(virsh -q domifaddr "$vm" 2>/dev/null \
        | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}') || true
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  # fall back to the libvirt DHCP lease table
  ip=$(virsh -q net-dhcp-leases "$LAB_NET" 2>/dev/null \
        | awk -v h="$vm" '$0 ~ h {split($5, a, "/"); print a[1]; exit}') || true
  [[ -n "$ip" ]] && echo "$ip"
  return 0   # never fail: callers use ip=$(vm_ip ...) under set -e
}

ensure_ssh_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    info "no ssh key at $SSH_KEY — generating one"
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "bash-mastery-linux" >/dev/null
    ok "created $SSH_KEY"
  fi
  [[ -f "$SSH_KEY.pub" ]] || die "missing public key: $SSH_KEY.pub"
}

# --- check ------------------------------------------------------------------

cmd_check() {
  local fails=0 warns=0

  info "host"
  if [[ "$(uname -s)" == "Linux" ]]; then ok "Linux $(uname -r)"
  else bad "not Linux — this lab needs KVM"; fails=$((fails + 1)); fi

  info "cpu virtualization"
  if grep -qE '^flags.*(vmx|svm)' /proc/cpuinfo; then
    ok "hardware virtualization present"
  else
    bad "no vmx/svm in /proc/cpuinfo — enable virtualization in BIOS/UEFI"
    fails=$((fails + 1))
  fi
  if [[ -w /dev/kvm ]]; then
    ok "/dev/kvm writable"
  elif [[ -e /dev/kvm ]]; then
    bad "/dev/kvm exists but is not writable — add yourself to the kvm group:"
    printf '         sudo usermod -aG kvm,libvirt %s   # then log out and back in\n' "${USER:-$(id -un)}"
    fails=$((fails + 1))
  else
    bad "/dev/kvm missing — kvm module not loaded"
    fails=$((fails + 1))
  fi

  info "tools"
  local t
  for t in virsh virt-install qemu-img curl ssh; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"
    else bad "$t not found"; fails=$((fails + 1)); fi
  done
  for t in ip nft dig tcpdump; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"
    else warn "$t not found (needed from Day 6 on the host)"; warns=$((warns + 1)); fi
  done

  info "libvirt"
  local unit
  if unit=$(libvirt_unit); then
    ok "$unit active"
  else
    bad "neither libvirtd nor virtqemud is active"
    printf '         sudo systemctl enable --now libvirtd\n'
    fails=$((fails + 1))
  fi
  if virsh -q net-info "$LAB_NET" >/dev/null 2>&1; then
    if virsh -q net-info "$LAB_NET" | grep -qi 'active:.*yes'; then
      ok "network '$LAB_NET' active"
    else
      bad "network '$LAB_NET' is defined but inactive"
      printf '         sudo virsh net-start %s && sudo virsh net-autostart %s\n' "$LAB_NET" "$LAB_NET"
      fails=$((fails + 1))
    fi
  else
    bad "libvirt network '$LAB_NET' not defined"
    fails=$((fails + 1))
  fi

  info "memory"
  local avail
  avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
  printf '         %s MB available now\n' "$avail"
  if (( avail >= 2600 )); then
    ok "enough for control + node1 (1792 MB)"
  elif (( avail >= 1900 )); then
    warn "tight — run one VM at a time, or close your browser during labs"
    warns=$((warns + 1))
  else
    warn "under 1.9 GB available — close applications before 'lab.sh up'"
    warns=$((warns + 1))
  fi

  info "disk"
  mkdir -p "$LAB_HOME"
  local freeg
  freeg=$(df -BG --output=avail "$LAB_HOME" 2>/dev/null | tail -1 | tr -dc '0-9') || true
  printf '         %s GB free at %s\n' "${freeg:-?}" "$LAB_HOME"
  if [[ -n "${freeg:-}" ]] && (( freeg >= 12 )); then
    ok "enough for the base image plus thin overlays"
  else
    warn "want ~12 GB free; overlays grow as you use them"
    warns=$((warns + 1))
  fi

  echo
  if (( fails > 0 )); then
    bad "$fails blocking problem(s), $warns warning(s)"
    echo
    echo "Install what is missing with:"
    echo "  $(pkg_hint)"
    echo "  sudo systemctl enable --now libvirtd"
    echo "  sudo usermod -aG kvm,libvirt ${USER:-$(id -un)}   # log out and back in"
    return 1
  fi
  ok "ready — next: $0 image"
  (( warns > 0 )) && warn "$warns warning(s) above are not blocking"
  return 0
}

# --- image ------------------------------------------------------------------

# Every step below needs the virtualization tools. Fail loudly and early rather
# than half-way through a 1 GB download or a virt-install.
require_lab_tools() {
  local missing=()
  local c
  for c in qemu-img virsh virt-install; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    bad "missing tool(s): ${missing[*]}"
    echo "  $(pkg_hint)"
    echo "  sudo systemctl enable --now libvirtd"
    die "run '$0 check' first and fix everything it reports"
  fi
}

cmd_image() {
  require_lab_tools
  mkdir -p "$IMAGE_DIR"
  if [[ -f "$BASE_IMAGE" ]] && qemu-img info "$BASE_IMAGE" >/dev/null 2>&1; then
    ok "base image already present: $BASE_IMAGE"
    return 0
  fi
  info "downloading Rocky Linux 9 cloud image (about 1 GB)"
  curl -fL --progress-bar -C - -o "$BASE_IMAGE.part" "$BASE_URL"
  mv "$BASE_IMAGE.part" "$BASE_IMAGE"
  if ! qemu-img info "$BASE_IMAGE" >/dev/null 2>&1; then
    rm -f "$BASE_IMAGE"
    die "downloaded file is not a valid qcow2 - deleted it, run '$0 image' again"
  fi
  ok "base image ready"
}

# --- up ---------------------------------------------------------------------

write_seed() {
  local vm="$1"
  local ud="$SEED_DIR/$vm-user-data"
  mkdir -p "$SEED_DIR"
  {
    echo "#cloud-config"
    echo "hostname: $vm"
    echo "fqdn: $vm.lab"
    echo "preserve_hostname: false"
    echo "users:"
    echo "  - name: $LAB_USER"
    echo "    groups: [wheel]"
    echo "    sudo: 'ALL=(ALL) NOPASSWD:ALL'"
    echo "    shell: /bin/bash"
    echo "    lock_passwd: false"
    echo "    ssh_authorized_keys:"
    echo "      - $(cat "$SSH_KEY.pub")"
    echo "ssh_pwauth: false"
    # SELinux is left enforcing on purpose. Day 13 depends on it.
    echo "runcmd:"
    echo "  - [ systemctl, enable, --now, sshd ]"
  } >"$ud"
  echo "$ud"
}

create_vm() {
  local vm="$1" mem disk ud osv
  mem=$(vm_mem "$vm")
  disk="$DISK_DIR/$vm.qcow2"

  if virsh -q dominfo "$vm" >/dev/null 2>&1; then
    warn "$vm already exists — skipping (use '$0 down $vm' first to recreate)"
    return 0
  fi

  mkdir -p "$DISK_DIR"
  info "creating $vm (${mem} MB, thin overlay on the base image)"
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "$DISK_SIZE"

  ud=$(write_seed "$vm")
  osv=$(osvariant)

  virt-install \
    --name "$vm" \
    --memory "$mem" \
    --vcpus 1 \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --import \
    --os-variant "$osv" \
    --network "network=$LAB_NET,model=virtio" \
    --graphics none \
    --noautoconsole \
    --cloud-init "user-data=$ud,disable=on"

  ok "$vm defined and booting"
}

wait_for_ip() {
  local vm="$1" ip
  info "waiting for $vm to get an address (up to 120s)"
  for _ in $(seq 1 60); do
    ip=$(vm_ip "$vm")
    if [[ -n "$ip" ]]; then ok "$vm is $ip"; return 0; fi
    sleep 2
  done
  warn "$vm has no address yet — check '$0 status' or 'virsh console $vm'"
  return 0
}

cmd_up() {
  require_lab_tools
  [[ -f "$BASE_IMAGE" ]] || die "no base image — run '$0 image' first"
  ensure_ssh_key

  local vms=("$@")
  [[ ${#vms[@]} -eq 0 ]] && vms=("${DEFAULT_VMS[@]}")

  local vm
  for vm in "${vms[@]}"; do
    is_known_vm "$vm" || die "unknown vm '$vm' (known: ${ALL_VMS[*]})"
  done
  for vm in "${vms[@]}"; do create_vm "$vm"; done
  for vm in "${vms[@]}"; do wait_for_ip "$vm"; done

  echo
  ok "log in with: $0 ssh ${vms[0]}"
}

# --- status / ssh / disks ---------------------------------------------------

cmd_status() {
  info "virtual machines"
  local vm state ip found=0
  for vm in "${ALL_VMS[@]}"; do
    if virsh -q dominfo "$vm" >/dev/null 2>&1; then
      found=1
      state=$(virsh -q domstate "$vm" 2>/dev/null || echo unknown)
      ip=$(vm_ip "$vm")
      printf '  %-9s %-10s %s\n' "$vm" "$state" "${ip:--}"
    fi
  done
  (( found == 0 )) && printf '  none defined — run: %s up\n' "$0"

  echo
  info "network namespaces"
  if ip netns list 2>/dev/null | grep -q .; then
    ip netns list | sed 's/^/  /'
  else
    printf '  none — run: sudo %s netns-up\n' "$0"
  fi
}

cmd_ssh() {
  local vm="${1:-}"
  [[ -n "$vm" ]] || die "usage: $0 ssh <vm>"
  is_known_vm "$vm" || die "unknown vm '$vm' (known: ${ALL_VMS[*]})"
  local ip
  ip=$(vm_ip "$vm")
  [[ -n "$ip" ]] || die "no address for $vm — is it running? try '$0 status'"
  exec ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$LAB_USER@$ip"
}

cmd_add_disk() {
  local vm="${1:-}" size="${2:-2}"
  [[ -n "$vm" ]] || die "usage: $0 add-disk <vm> [size-in-GB]"
  virsh -q dominfo "$vm" >/dev/null 2>&1 || die "no such vm: $vm"

  mkdir -p "$DISK_DIR"
  local n=1 path target
  while :; do
    path="$DISK_DIR/$vm-extra$n.qcow2"
    target="vd$(printf "\\$(printf '%03o' $((98 + n)))")"   # vdb, vdc, ...
    [[ -e "$path" ]] || break
    n=$((n + 1))
  done

  info "creating ${size}G disk for $vm as /dev/$target"
  qemu-img create -q -f qcow2 "$path" "${size}G"
  virsh attach-disk "$vm" "$path" "$target" \
    --driver qemu --subdriver qcow2 --targetbus virtio --persistent
  ok "attached — inside the VM it appears as /dev/$target"
}

cmd_down() {
  local vms=("$@")
  [[ ${#vms[@]} -eq 0 ]] && vms=("${ALL_VMS[@]}")
  local vm
  for vm in "${vms[@]}"; do
    if virsh -q dominfo "$vm" >/dev/null 2>&1; then
      info "removing $vm"
      virsh -q destroy "$vm" >/dev/null 2>&1 || true
      virsh -q undefine "$vm" --remove-all-storage >/dev/null 2>&1 \
        || virsh -q undefine "$vm" >/dev/null 2>&1 || true
      rm -f "$DISK_DIR/$vm.qcow2" "$DISK_DIR/$vm-extra"*.qcow2
      ok "$vm gone"
    fi
  done
}

# --- network namespaces (Days 6-10) ----------------------------------------
#
#   client 10.10.0.2  ---  10.10.0.1 router 10.10.1.1  ---  10.10.1.2 resolver
#                                     router 10.10.2.1  ---  10.10.2.2 auth
#
# Real network stacks in the kernel. Real routing, real packets, real
# tcpdump captures. Costs no memory.

NS_LIST=(client router resolver auth)

link_pair() {
  # link_pair <ns-a> <if-a> <addr-a> <ns-b> <if-b> <addr-b>
  local nsa="$1" ifa="$2" aa="$3" nsb="$4" ifb="$5" ab="$6"
  ip link add "$ifa" type veth peer name "$ifb"
  ip link set "$ifa" netns "$nsa"
  ip link set "$ifb" netns "$nsb"
  ip -n "$nsa" addr add "$aa" dev "$ifa"
  ip -n "$nsb" addr add "$ab" dev "$ifb"
  ip -n "$nsa" link set "$ifa" up
  ip -n "$nsb" link set "$ifb" up
}

cmd_netns_up() {
  need_root netns-up
  local ns
  for ns in "${NS_LIST[@]}"; do
    if ip netns list | grep -qw "$ns"; then
      die "namespace '$ns' already exists — run 'sudo $0 netns-down' first"
    fi
  done

  info "creating namespaces: ${NS_LIST[*]}"
  for ns in "${NS_LIST[@]}"; do
    ip netns add "$ns"
    ip -n "$ns" link set lo up
  done

  info "wiring veth pairs"
  link_pair client   veth-cl 10.10.0.2/24  router veth-rcl 10.10.0.1/24
  link_pair resolver veth-rs 10.10.1.2/24  router veth-rrs 10.10.1.1/24
  link_pair auth     veth-au 10.10.2.2/24  router veth-rau 10.10.2.1/24

  info "enabling forwarding on router"
  ip netns exec router sysctl -qw net.ipv4.ip_forward=1

  info "adding default routes"
  ip -n client   route add default via 10.10.0.1
  ip -n resolver route add default via 10.10.1.1
  ip -n auth     route add default via 10.10.2.1

  echo
  if ip netns exec client ping -c1 -W2 10.10.2.2 >/dev/null 2>&1; then
    ok "client can reach auth through router — topology works"
  else
    warn "client cannot reach auth yet; inspect with 'sudo $0 netns-status'"
  fi
  echo
  echo "  client   10.10.0.2  --."
  echo "                        router  10.10.0.1 / 10.10.1.1 / 10.10.2.1"
  echo "  resolver 10.10.1.2  --'"
  echo "  auth     10.10.2.2  --'"
  echo
  echo "Run a command inside a namespace:"
  echo "  sudo ip netns exec client dig @10.10.2.2 lab.test"
  echo "  sudo ip netns exec router tcpdump -ni veth-rau"
}

cmd_netns_status() {
  if ! ip netns list 2>/dev/null | grep -q .; then
    printf 'no namespaces — run: sudo %s netns-up\n' "$0"
    return 0
  fi
  local ns
  for ns in "${NS_LIST[@]}"; do
    ip netns list | grep -qw "$ns" || continue
    info "$ns"
    ip -n "$ns" -brief addr show | sed 's/^/    /'
    ip -n "$ns" route show | sed 's/^/    route: /'
  done
  echo
  info "reachability"
  if ip netns list | grep -qw client; then
    local dst
    for dst in 10.10.0.1 10.10.1.2 10.10.2.2; do
      if ip netns exec client ping -c1 -W2 "$dst" >/dev/null 2>&1; then
        ok "client -> $dst"
      else
        bad "client -> $dst unreachable"
      fi
    done
  fi
}

cmd_netns_down() {
  need_root netns-down
  local ns removed=0
  for ns in "${NS_LIST[@]}"; do
    if ip netns list | grep -qw "$ns"; then
      ip netns delete "$ns"
      ok "removed $ns"
      removed=1
    fi
  done
  (( removed == 0 )) && printf 'nothing to remove\n'
  return 0
}

# --- dispatch ---------------------------------------------------------------

cmd_push() {
  local vm="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  [[ -n "$vm" ]] || die "usage: $0 push <vm> [path...]   (default: days lab)"
  is_known_vm "$vm" || die "unknown vm '$vm' (known: ${ALL_VMS[*]})"

  local ip
  ip=$(vm_ip "$vm")
  [[ -n "$ip" ]] || die "no address for $vm — is it running? try '$0 status'"

  # Default to the whole curriculum plus the lab helpers. Pass explicit paths
  # when you only want one day: ./lab/lab.sh push control days/day01
  local -a paths=("$@")
  if [[ ${#paths[@]} -eq 0 ]]; then
    paths=(days lab)
  fi

  local pth
  for pth in "${paths[@]}"; do
    [[ -e "$pth" ]] || die "no such path: $pth (run this from the repo root)"
  done

  local -a sshopts=(-i "$SSH_KEY"
                    -o StrictHostKeyChecking=no
                    -o UserKnownHostsFile=/dev/null
                    -o LogLevel=ERROR)

  info "copying ${paths[*]} to $LAB_USER@$ip:~/lab/"
  ssh "${sshopts[@]}" "$LAB_USER@$ip" "mkdir -p ~/lab"
  # -p keeps the execute bits; we re-chmod anyway because some scp builds drop
  # them, and a day whose scripts are not executable is a confusing first run.
  scp -q -p -r "${sshopts[@]}" "${paths[@]}" "$LAB_USER@$ip:lab/"
  ssh "${sshopts[@]}" "$LAB_USER@$ip" \
    "chmod +x ~/lab/days/*/scripts/*.sh ~/lab/days/*/verify.sh 2>/dev/null || true"

  ok "copied to $vm:~/lab — now: $0 ssh $vm, then cd ~/lab/days/day01"
}

usage() {
  # Print the header comment block: from line 3 until the first non-comment line.
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "$cmd" in
    check)         cmd_check "$@" ;;
    image)         cmd_image "$@" ;;
    up)            cmd_up "$@" ;;
    status)        cmd_status "$@" ;;
    ssh)           cmd_ssh "$@" ;;
    push)          cmd_push "$@" ;;
    add-disk)      cmd_add_disk "$@" ;;
    down)          cmd_down "$@" ;;
    netns-up)      cmd_netns_up "$@" ;;
    netns-status)  cmd_netns_status "$@" ;;
    netns-down)    cmd_netns_down "$@" ;;
    destroy)       cmd_down; ip netns list 2>/dev/null | grep -q . && cmd_netns_down || true ;;
    -h|--help|help|"") usage ;;
    *)             die "unknown subcommand '$cmd' — try '$0 --help'" ;;
  esac
}

main "$@"
