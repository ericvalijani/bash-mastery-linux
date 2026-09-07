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
#   ./lab/lab.sh console <vm>       attach to a VM console (Ctrl+] to exit)
#                       --restart   power-cycle first and watch it boot
#   ./lab/lab.sh diagnose <vm>      collect every clue about a stuck VM
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

# Where the lab keeps its images and disks. $HOME is the intuitive choice and
# the wrong one. Under qemu:///system the VM process runs as libvirt-qemu, and
# on Ubuntu AppArmor confines that process to a fixed list of paths which does
# not include home directories. File permissions are then beside the point: the
# ACLs can be correct, libvirt's own accessibility test can pass, and qemu still
# gets "Permission denied" opening the disk. libvirt's own image directory is on
# that list, so use it whenever we are allowed to write there.
LAB_LIBVIRT_HOME="/var/lib/libvirt/images/bash-mastery-linux"
lab_home_default() {
  if [[ -d "$LAB_LIBVIRT_HOME" && -w "$LAB_LIBVIRT_HOME" ]]; then
    echo "$LAB_LIBVIRT_HOME"
  else
    echo "$HOME/.local/share/bash-mastery-linux"
  fi
}
LAB_HOME="${LAB_HOME:-$(lab_home_default)}"
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
# Every VM gets a VNC screen on 127.0.0.1 by default. This is not a debugging
# nicety: on this hardware, guests created with --graphics none burned a full
# core, read gigabytes, never reached the network and never wrote one byte to
# the serial port. Adding a display device made the identical image boot in
# under a minute. A guest with no console you can look at is not debuggable,
# so the display stays. Set LAB_GRAPHICS=none for headless behaviour.
LAB_GRAPHICS="${LAB_GRAPHICS:-vnc}"

# virsh talks to a different daemon depending on who runs it: root gets
# qemu:///system, while an unprivileged user can silently fall back to
# qemu:///session, which contains none of our VMs and none of our networks.
# That is why "sudo virsh net-list" and a plain "virsh net-list" can disagree.
# Pin it so this script, your shell and sudo all see the same libvirt.
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

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
    echo "sudo dnf install -y libvirt virt-install qemu-kvm libvirt-daemon-config-network acl cloud-utils"
  elif command -v apt-get >/dev/null 2>&1; then
    # Debian and Ubuntu dropped the qemu-kvm package; it is now a virtual
    # package with no installation candidate. Plain qemu-system would pull in
    # every CPU architecture. qemu-system-x86 is the only one KVM needs here.
    echo "sudo apt-get install -y qemu-system-x86 libvirt-daemon-system libvirt-clients libvirt-daemon-config-network virtinst acl cloud-image-utils"
  elif command -v pacman >/dev/null 2>&1; then
    echo "sudo pacman -S --needed libvirt virt-install qemu-desktop acl cloud-image-utils"
  else
    echo "install: libvirt, virt-install, and qemu system emulation for x86"
  fi
}

# cloud-localds (cloud-image-utils / cloud-utils) is the tidiest way to build a
# NoCloud seed ISO; genisoimage and xorriso are accepted stand-ins.
graphics_arg() {
  if [[ "$LAB_GRAPHICS" == none ]]; then
    echo none
  else
    # 127.0.0.1 only: this is a throwaway lab guest with no password on
    # its console, and it must not be reachable from the network.
    echo "$LAB_GRAPHICS,listen=127.0.0.1"
  fi
}

iso_pkg_hint() {
  if command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install -y cloud-utils genisoimage"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "sudo apt-get install -y cloud-image-utils"
  elif command -v pacman >/dev/null 2>&1; then
    echo "sudo pacman -S --needed cloud-image-utils"
  else
    echo "install: cloud-image-utils (for cloud-localds), or genisoimage"
  fi
}

# Printed whenever the lab still lives under $HOME. One sudo, once, and the
# lab sits in the directory libvirt and AppArmor already expect.
relocate_hint() {
  echo "  sudo install -d -o \"$(id -un)\" -g \"$(id -gn)\" $LAB_LIBVIRT_HOME"
  if [[ -d "$IMAGE_DIR" ]]; then
    echo "  mv $IMAGE_DIR $LAB_LIBVIRT_HOME/    # keep the downloaded base image"
  fi
}

# Recent libvirt replaces the monolithic libvirtd with modular daemons and
# ships no libvirtd.service at all, so the hint has to cover both layouts.
enable_hint() {
  if systemctl list-unit-files libvirtd.service 2>/dev/null | grep -q libvirtd; then
    echo "sudo systemctl enable --now libvirtd"
  else
    echo "sudo systemctl enable --now libvirtd.service 2>/dev/null || sudo systemctl enable --now virtqemud.socket virtnetworkd.socket"
  fi
}

# Prints one of: missing, inactive, active. Reads the Active field by name
# rather than pattern-matching the whole block, so Autostart cannot be mistaken
# for Active.
net_state() {
  local out
  out=$(virsh -q net-info "$LAB_NET" 2>/dev/null) || { echo missing; return 0; }
  if printf '%s\n' "$out" \
    | awk -F: 'tolower($1) == "active" { gsub(/[ \t]/, "", $2); print tolower($2) }' \
    | grep -qx yes; then
    echo active
  else
    echo inactive
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

# qemu does not run as you. On Debian and Ubuntu it runs as libvirt-qemu, on
# Rocky as qemu. Your $HOME is mode 0700, so that user cannot even traverse
# into it, which is the "Cannot access storage file ... (as uid:64055):
# Permission denied" error. The fix is one ACL entry per directory on the path:
# search (x) only, granted to that one user. No chmod 755 on your home.
qemu_user() {
  local u
  for u in libvirt-qemu qemu; do
    if id -u "$u" >/dev/null 2>&1; then echo "$u"; return 0; fi
  done
  return 1
}

grant_path() {
  local perms="$1"
  shift
  local qu
  qu=$(qemu_user) || return 0
  command -v setfacl >/dev/null 2>&1 || return 0
  local p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    setfacl -m "u:$qu:$perms" "$p" 2>/dev/null || true
  done
}

grant_hypervisor_access() {
  local qu
  if ! qu=$(qemu_user); then
    warn "no libvirt-qemu or qemu user on this system - skipping access grant"
    return 0
  fi
  if ! command -v setfacl >/dev/null 2>&1; then
    warn "setfacl not found: install the 'acl' package, or qemu cannot read $LAB_HOME"
    return 0
  fi
  # Walk up from the lab directory to $HOME, granting search only.
  local dir="$LAB_HOME"
  while :; do
    grant_path x "$dir"
    [[ "$dir" == "$HOME" || "$dir" == "/" ]] && break
    dir=$(dirname "$dir")
  done
  grant_path x "$HOME"
  grant_path rx "$IMAGE_DIR" "$SEED_DIR"
  grant_path r  "$BASE_IMAGE"
  grant_path rwx "$DISK_DIR"
}

osvariant() {
  local list=""
  if command -v osinfo-query >/dev/null 2>&1; then
    list=$(osinfo-query -f short-id os 2>/dev/null | tr -d ' ') || true
  fi
  if [[ -z "$list" ]] && command -v virt-install >/dev/null 2>&1; then
    list=$(virt-install --osinfo list 2>/dev/null | tr -d ' ') || true
  fi
  local v
  if [[ -n "$list" ]]; then
    # Nearest match first. A wrong-but-close RHEL 9 profile still gives virtio
    # and a sane clock; "generic" gives neither, which is what the
    # "--osinfo generic, VM performance may suffer" warning is about.
    for v in rocky9 rocky9.0 rhel9.6 rhel9.5 rhel9.4 rhel9.3 rhel9.2 rhel9.1 \
             rhel9.0 rhel9-unknown centos-stream9 linux2022; do
      if grep -qx "$v" <<<"$list"; then echo "$v"; return 0; fi
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
    printf '         %s\n' "$(enable_hint)"
    fails=$((fails + 1))
  fi
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx libvirt; then
    ok "you are in the libvirt group"
  else
    warn "not in the libvirt group yet - log out and back in, or every libvirt"
    printf '         command here will need sudo and may read the wrong daemon\n'
    warns=$((warns + 1))
  fi

  if [[ "$LAB_HOME" == "$HOME"/* ]]; then
    warn "lab lives under your home directory - AppArmor will deny qemu access to it"
    echo "         move it out of $HOME once:"
    relocate_hint
    warns=$((warns + 1))
  else
    ok "lab directory is outside your home directory"
  fi

  local qu
  if qu=$(qemu_user); then
    if ! command -v setfacl >/dev/null 2>&1; then
      warn "setfacl not found - install the 'acl' package or qemu cannot reach $LAB_HOME"
      warns=$((warns + 1))
    elif getfacl -p "$HOME" 2>/dev/null | grep -q "^user:$qu:..x"; then
      ok "hypervisor user '$qu' can reach your home directory"
    else
      warn "hypervisor user '$qu' cannot traverse $HOME yet - '$0 up' grants this"
      warns=$((warns + 1))
    fi
  else
    warn "no libvirt-qemu or qemu user found - is libvirt fully installed?"
    warns=$((warns + 1))
  fi

  local netstate
  netstate=$(net_state)
  if [[ $netstate == inactive ]]; then
    # The first virsh call of a boot can socket-activate virtnetworkd, which
    # then autostarts this network. Do not call it dead on the first reading.
    sleep 2
    netstate=$(net_state)
  fi
  case "$netstate" in
    active)
      ok "network '$LAB_NET' active"
      ;;
    inactive)
      bad "network '$LAB_NET' is defined but inactive"
      printf '         sudo virsh net-start %s && sudo virsh net-autostart %s\n' "$LAB_NET" "$LAB_NET"
      printf "         if that says 'already active', libvirt beat us to it - just re-run: %s check\n" "$0"
      fails=$((fails + 1))
      ;;
    *)
      bad "libvirt network '$LAB_NET' not defined"
      printf '         sudo virsh net-define /usr/share/libvirt/networks/default.xml\n'
      fails=$((fails + 1))
      ;;
  esac

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
    echo "  $(enable_hint)"
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
    echo "  $(enable_hint)"
    die "run '$0 check' first and fix everything it reports"
  fi
}

cmd_image() {
  require_lab_tools
  mkdir -p "$IMAGE_DIR"
  if [[ -f "$BASE_IMAGE" ]] && qemu-img info "$BASE_IMAGE" >/dev/null 2>&1; then
    grant_hypervisor_access
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
  grant_hypervisor_access
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
    # The marker every day script looks for before it changes anything.
    echo "write_files:"
    echo "  - path: /etc/bash-mastery-linux-lab"
    echo "    content: |"
    echo "      This is a bash-mastery-linux lab VM. Day scripts may change"
    echo "      anything here. Delete it with: ./lab/lab.sh down $vm"
    # SELinux is left enforcing on purpose. Day 13 depends on it.
    echo "runcmd:"
    echo "  - [ systemctl, enable, --now, sshd ]"
  } >"$ud"
  echo "$ud"
}

# virt-install --cloud-init is convenient and fragile: it runs the first boot as
# an "install phase" with on_reboot=destroy so it can detach the ISO, which
# leaves the domain powered off at exactly the wrong moment. Building the
# NoCloud seed ISO ourselves and attaching it as a permanent cdrom removes the
# install phase completely - the very first boot is a normal boot. cloud-init
# then re-reads the same seed on every boot, which is harmless because its
# modules are idempotent.
seed_iso() {
  local vm="$1" ud="$2" dir iso
  dir="$SEED_DIR/$vm"
  iso="$SEED_DIR/$vm-seed.iso"
  mkdir -p "$dir"
  cp "$ud" "$dir/user-data"
  # NoCloud needs a meta-data file even when it is nearly empty, and the ISO
  # filesystem label must be exactly CIDATA or cloud-init will not look at it.
  printf 'instance-id: %s-01\nlocal-hostname: %s\n' "$vm" "$vm" >"$dir/meta-data"
  rm -f "$iso"
  if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$iso" "$dir/user-data" "$dir/meta-data" >/dev/null 2>&1 || true
  elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "$iso" -volid CIDATA -joliet -rock \
      "$dir/user-data" "$dir/meta-data" >/dev/null 2>&1 || true
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -quiet -o "$iso" -V CIDATA -J -r \
      "$dir/user-data" "$dir/meta-data" >/dev/null 2>&1 || true
  fi
  [[ -s "$iso" ]] && echo "$iso"
  return 0
}

create_vm() {
  local vm="$1" mem disk ud osv iso
  mem=$(vm_mem "$vm")
  disk="$DISK_DIR/$vm.qcow2"

  if virsh -q dominfo "$vm" >/dev/null 2>&1; then
    warn "$vm already exists — skipping (use '$0 down $vm' first to recreate)"
    return 0
  fi

  mkdir -p "$DISK_DIR"
  info "creating $vm (${mem} MB, thin overlay on the base image)"
  if [[ "$LAB_HOME" == "$HOME"/* ]]; then
    warn "the lab is under $HOME; on Ubuntu qemu will be denied access to it"
    echo "         run this once, then '$0 image' and '$0 up' again:"
    relocate_hint
  fi
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "$DISK_SIZE"
  # A thin overlay is useless if the chain to the base image is broken - for
  # instance if the base image was moved after the overlay was created. The
  # guest then boots to nothing at all, with no error on the host side.
  if ! qemu-img info --backing-chain "$disk" >/dev/null 2>&1; then
    rm -f "$disk"
    die "overlay chain to $BASE_IMAGE is broken - removed $disk, run '$0 image' then '$0 up $vm'"
  fi
  # The overlay is created 0600 and owned by you; qemu needs to write it,
  # and to read the backing file it points at.
  grant_hypervisor_access
  grant_path rw "$disk"

  ud=$(write_seed "$vm")
  osv=$(osvariant)

  iso=$(seed_iso "$vm" "$ud")

  if [[ -n "$iso" ]]; then
    grant_path r "$iso"
    virt-install \
      --name "$vm" \
      --memory "$mem" \
      --vcpus 1 \
      --disk "path=$disk,format=qcow2,bus=virtio" \
      --disk "path=$iso,device=cdrom,readonly=on" \
      --import \
      --os-variant "$osv" \
      --network "network=$LAB_NET,model=virtio" \
      --boot hd \
      --graphics "$(graphics_arg)" \
      --noautoconsole
  else
    warn "no ISO builder found - falling back to virt-install --cloud-init"
    echo "         its first boot power-cycles the VM; install one to avoid that:"
    echo "         $(iso_pkg_hint)"
    virt-install \
      --name "$vm" \
      --memory "$mem" \
      --vcpus 1 \
      --disk "path=$disk,format=qcow2,bus=virtio" \
      --import \
      --os-variant "$osv" \
      --network "network=$LAB_NET,model=virtio" \
      --graphics "$(graphics_arg)" \
      --noautoconsole \
      --cloud-init "user-data=$ud,disable=on"
  fi

  ok "$vm defined and booting"
}

# "virt-install --import --cloud-init" treats the first boot as an install
# phase. During it libvirt sets on_reboot=destroy so the cloud-init ISO can be
# detached cleanly, and the Rocky image does reboot once cloud-init has applied
# our seed. With --noautoconsole virt-install has already returned by then, so
# the domain is left "shut off" and nothing brings it back. The final XML has no
# ISO attached and boots straight through, so all we have to do is start it.
ensure_running() {
  local vm="$1" state
  state=$(virsh -q domstate "$vm" 2>/dev/null || echo unknown)
  if [[ "$state" == running ]]; then
    return 0
  elif [[ "$state" == "shut off" ]]; then
    info "$vm powered off after its cloud-init boot - starting it for real now"
    if virsh -q start "$vm" >/dev/null 2>&1; then
      ok "$vm started"
    else
      warn "could not start $vm - try: virsh start $vm"
    fi
  elif [[ "$state" == paused ]]; then
    virsh -q resume "$vm" >/dev/null 2>&1 || true
  else
    warn "$vm is in state '$state'"
  fi
  return 0
}

wait_for_ip() {
  local vm="$1" ip n=0
  info "waiting for $vm to get an address (up to 180s)"
  # Give cloud-init room to run and reboot before judging the domain state.
  sleep 10
  ensure_running "$vm"
  while [[ $n -lt 85 ]]; do
    ip=$(vm_ip "$vm")
    if [[ -n "$ip" ]]; then ok "$vm is $ip"; return 0; fi
    n=$((n + 1))
    # It can power off at any point during that first boot, so keep checking.
    if [[ $((n % 8)) -eq 0 ]]; then ensure_running "$vm"; fi
    sleep 2
  done
  warn "$vm has no address yet - check '$0 status' or 'virsh console $vm'"
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
      if [[ -z "$ip" && "$state" == running ]]; then
        echo "           running but no DHCP lease yet: $0 console $vm"
      fi
      if [[ "$state" == "shut off" ]]; then
        echo "           start it with: $0 up $vm"
      fi
    fi
  done
  (( found == 0 )) && printf '  none defined — run: %s up\n' "$0"

  echo
  info "network namespaces"
  if ip netns list 2>/dev/null | grep -q .; then
    ip netns list | sed 's/^/  /'
  else
    printf '  none - only Days 6-10 need these (sudo %s netns-up)\n' "$0"
  fi
}

cmd_ssh() {
  local vm="${1:-}"
  [[ -n "$vm" ]] || die "usage: $0 ssh <vm>"
  is_known_vm "$vm" || die "unknown vm '$vm' (known: ${ALL_VMS[*]})"
  local ip
  ip=$(vm_ip "$vm")
  if [[ -z "$ip" ]]; then
    warn "no address for $vm yet"
    echo "         see what the VM is doing:  $0 console $vm"
    echo "         check the lease table:     virsh net-dhcp-leases $LAB_NET"
    die "cannot continue without an address"
  fi
  exec ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$LAB_USER@$ip"
}

# When a VM is running but never gets an address, the console is the only place
# the answer is: kernel messages, cloud-init output, or a login prompt meaning
# it booted fine and the problem is DHCP or the lease lookup.
cmd_console() {
  local vm="${1:-}" mode="${2:-}"
  [[ -n "$vm" ]] || die "usage: $0 console <vm> [--restart]"
  is_known_vm "$vm" || die "unknown vm '$vm' (known: ${ALL_VMS[*]})"
  # Attaching to a VM that has already booted shows nothing at all: the output
  # scrolled past long ago and a quiet guest writes nothing new. --restart
  # power-cycles it and attaches first, so you see firmware, boot loader and
  # kernel from the first byte. That is the only way to tell "booted fine, no
  # DHCP" apart from "never booted".
  if [[ "$mode" == "--restart" ]]; then
    info "power-cycling $vm and attaching - you will see the whole boot"
    virsh -q destroy "$vm" >/dev/null 2>&1 || true
    sleep 1
    exec virsh start "$vm" --console
  fi
  echo "press Enter for a prompt; Ctrl+] to get back here"
  echo "nothing at all? run: $0 console $vm --restart"
  exec virsh console "$vm"
}

# A silent serial console means the guest produced no output, which is not the
# same as the guest doing nothing - and none of the host-side commands people
# reach for first can tell those apart. This collects, in one go, the four
# measurements that can: whether the vCPU is burning time, whether the guest
# has read a single block from its disk, what qemu itself logged, and whether
# the kernel refused something. /var/log/libvirt/qemu/<vm>.log is the file
# that actually names the reason a domain will not run, and it needs root.
cmd_diagnose() {
  local vm="${1:-control}" disk dev qlog
  is_known_vm "$vm" || die "unknown vm '$vm' (known: ${ALL_VMS[*]})"
  disk="$DISK_DIR/$vm.qcow2"
  qlog="/var/log/libvirt/qemu/$vm.log"

  info "domain"
  echo "  state: $(virsh -q domstate "$vm" 2>&1)"
  virsh -q dominfo "$vm" 2>/dev/null |
    grep -E 'CPU time|Used memory|Autostart' | sed 's/^/  /'

  # If cpu_time barely moves between the two reads, the guest is not
  # executing instructions at all.
  info "is the guest executing? (cpu time should climb between these two reads)"
  virsh -q cpu-stats "$vm" --total 2>/dev/null | sed 's/^/  /'
  sleep 3
  virsh -q cpu-stats "$vm" --total 2>/dev/null | sed 's/^/  /'

  # A guest that reached its boot loader has read thousands of blocks. One
  # stuck before firmware has read almost none.
  info "has it read anything from its disk?"
  dev=$(virsh -q domblklist "$vm" 2>/dev/null | awk '$2 ~ /qcow2$/ {print $1; exit}')
  if [[ -n "$dev" ]]; then
    virsh -q domblkstat "$vm" "$dev" 2>/dev/null |
      grep -E 'rd_req|rd_bytes' | sed 's/^/  /'
  else
    warn "no qcow2 device found in domblklist"
  fi

  info "disk chain"
  # --force-share, because a running domain holds a write lock and qemu-img
  # would otherwise fail with an error that reads like corruption but is not.
  qemu-img info --backing-chain --force-share "$disk" 2>&1 |
    grep -E 'image:|file format|virtual size|backing file' | sed 's/^/  /'

  info "seed iso"
  if [[ -s "$SEED_DIR/$vm-seed.iso" ]]; then
    ls -l "$SEED_DIR/$vm-seed.iso" | sed 's/^/  /'
  else
    warn "no seed ISO - this VM predates the seed-ISO path, recreate it"
    echo "         $(iso_pkg_hint)"
  fi

  # 100% of a core with heavy disk reads and no console output is the
  # signature of a guest running under software emulation instead of KVM.
  info "acceleration, and what the vcpu is doing"
  virsh -q qemu-monitor-command "$vm" --hmp 'info kvm' 2>&1 | sed 's/^/  /'
  virsh -q qemu-monitor-command "$vm" --hmp 'info status' 2>&1 | sed 's/^/  /'

  # A DHCP lease is not the only evidence of an address. The host ARP table
  # sees a guest that configured itself without asking libvirt's dnsmasq.
  info "any address at all, not just leases"
  virsh -q domifaddr "$vm" --source arp 2>&1 | sed 's/^/  /'

  if [[ "$LAB_GRAPHICS" != none ]] || virsh -q vncdisplay "$vm" >/dev/null 2>&1; then
    info "screen"
    echo "  vnc display: $(virsh -q vncdisplay "$vm" 2>&1)"
  else
    info "screen"
    echo "  none - to watch this guest boot on a screen instead of the serial port:"
    echo "    $0 down $vm && $0 up $vm   (VMs get a screen by default now)"
    echo "    then: virsh vncdisplay $vm   and point a VNC viewer at it"
  fi

  info "qemu own log for this domain"
  if [[ -r "$qlog" ]]; then
    tail -n 20 "$qlog" | sed 's/^/  /'
  else
    echo "  needs root - run:  sudo tail -n 30 $qlog"
  fi

  info "host kernel complaints (AppArmor denials, OOM kills)"
  if dmesg >/dev/null 2>&1; then
    dmesg | grep -iE 'apparmor.*denied|oom-kill|Killed process' |
      tail -n 5 | sed 's/^/  /' || echo "  none"
  else
    echo "  needs root - run:  sudo dmesg | grep -iE 'apparmor|oom-kill'"
  fi

  info "free memory and dhcp leases"
  free -m 2>/dev/null | awk '/^Mem:/ {print "  " $7 " MB available"}'
  virsh -q net-dhcp-leases "$LAB_NET" 2>/dev/null | sed 's/^/  /' || true
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
  if [[ -z "$ip" ]]; then
    warn "no address for $vm yet"
    echo "         see what the VM is doing:  $0 console $vm"
    echo "         check the lease table:     virsh net-dhcp-leases $LAB_NET"
    die "cannot continue without an address"
  fi

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
    console)       cmd_console "$@" ;;
    diagnose)      cmd_diagnose "$@" ;;
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
