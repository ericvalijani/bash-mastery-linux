# The lab

## What you need

| | |
|---|---|
| Host OS | Linux (KVM lives in your kernel; nothing to install for the hypervisor itself) |
| CPU | virtualization enabled in BIOS/UEFI — `vmx` for Intel, `svm` for AMD |
| RAM | 8 GB works. 2 GB for node1, about 3.8 GB for all three |
| Disk | ~12 GB: a 1 GB base image plus thin overlays |
| Packages | libvirt, virt-install, qemu system emulation for x86 |

Run the check first. It reports exactly what is missing and the command to fix
it for your distribution:

```bash
./lab/lab.sh check
```

## One-time setup

```bash
# Fedora / Rocky / Alma
sudo dnf install -y libvirt virt-install qemu-kvm libvirt-daemon-config-network

# Debian / Ubuntu
sudo apt-get install -y qemu-system-x86 libvirt-daemon-system libvirt-clients libvirt-daemon-config-network virtinst acl
# There is no qemu-kvm package on Debian or Ubuntu any more, and plain
# qemu-system installs every architecture. qemu-system-x86 is the right one.

sudo systemctl enable --now libvirtd
sudo usermod -aG kvm,libvirt "$USER"    # then log out and back in
```

One more step the first time, and only once:

```bash
sudo install -d -o "$(id -un)" -g "$(id -gn)" /var/lib/libvirt/images/bash-mastery-linux
```

The lab keeps its base image and VM disks there rather than under your home
directory. That is not a style preference. Under `qemu:///system` the VM runs as
the `libvirt-qemu` user, and on Ubuntu AppArmor confines that process to a fixed
list of paths which does not include home directories, so a disk under `$HOME`
is refused even when the file permissions are correct. `lab.sh` uses this
directory automatically as soon as it exists and is writable by you.

That last step matters. Without it `/dev/kvm` is not writable and every VM
creation fails with a permission error.

## Daily use

```bash
./lab/lab.sh up control node1     # bring up what the day needs
./lab/lab.sh status               # VMs, addresses, namespaces
./lab/lab.sh push node1           # copy days/ and lab/ into ~/lab on the VM
./lab/lab.sh ssh node1
./lab/lab.sh add-disk node1 2     # Day 4 wants a spare disk
./lab/lab.sh down node1           # delete it; recreate in about a minute
./lab/lab.sh diagnose node1       # when a VM will not boot or get an address
```

Each VM has a VNC screen on `127.0.0.1`; `virsh vncdisplay node1` prints the
display to open in a viewer. Guests created with no display device have been
seen to spin forever on this hardware without writing anything to the serial
console, so the screen is on by default. `LAB_GRAPHICS=none` turns it off.

VMs are disposable on purpose. If Day 12 locks you out of sshd or Day 13
leaves the filesystem mislabelled, delete and recreate rather than repair.
The recovery skill is worth practising once, deliberately — not by accident at
midnight.

## The namespace topology

```
client 10.10.0.2 ---- 10.10.0.1 router 10.10.1.1 ---- 10.10.1.2 resolver
                                router 10.10.2.1 ---- 10.10.2.2 auth
```

```bash
sudo ./lab/lab.sh netns-up
sudo ./lab/lab.sh netns-status
sudo ip netns exec router tcpdump -ni veth-rau
sudo ./lab/lab.sh netns-down
```

These are real network stacks in your kernel. Real routing decisions, real
packets, real captures. They are not a simulation, and they cost no memory —
which is why Days 6–10 are the cheapest days in the curriculum.

## If the script fails

It is a convenience wrapper, not a dependency. Everything it does is plain
libvirt, and doing it by hand is a reasonable Day 0 exercise:

```bash
qemu-img create -f qcow2 -F qcow2 \
  -b ~/.local/share/bash-mastery-linux/images/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 \
  ~/.local/share/bash-mastery-linux/disks/node1.qcow2 10G

virt-install --name node1 --memory 2048 --vcpus 1 \
  --disk path=~/.local/share/bash-mastery-linux/disks/node1.qcow2,format=qcow2 --import \
  --os-variant rocky9 --network network=default --noautoconsole \
  --graphics vnc,listen=127.0.0.1 \
  --disk path=/path/to/seed.iso,device=cdrom,readonly=on --boot hd

virsh list --all
virsh domifaddr node1
virsh console node1        # escape with ctrl-]
```

If `--os-variant rocky9` is rejected, your `osinfo-db` is older than Rocky 9.
Use `rhel9.0`, or `generic` as a last resort.

## Known limits

- The `default` libvirt network is NAT. VMs reach the internet and each other,
  but nothing on your LAN reaches them without extra work.
- Namespaces share your host kernel, so they cannot host Days 1–5 or Day 13:
  no separate init, no separate disks, no separate SELinux state.
- `lab.sh` has not been executed against real hardware. Treat `check` as the
  first thing to run and the first thing to trust.
