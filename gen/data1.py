# Days 1-10. tier: lint | ci | lab
# check tuples: ("auto", text, cmd) or ("manual", text, "")
# cmd must not contain a single quote (the generator asserts this).

DAYS_1_10 = [
dict(n=1, title="systemd and the boot path", runs="VM: control", tier="lab",
  obj="Follow a Linux machine from power-on to a running service, and write a unit that survives a reboot.",
  why="Every later day ends with \"make it persist\", and on this family of distros that always means a unit file. Start where the machine starts.",
  work=["systemctl list-units --failed", "systemctl cat sshd.service", "systemd-analyze blame", "systemd-analyze critical-chain", "journalctl -b -p err", "/etc/systemd/system/"],
  checks=[("auto","a custom unit is installed and enabled","systemctl is-enabled lab-demo.service"),
    ("auto","that unit is running","systemctl is-active lab-demo.service"),
    ("auto","the machine boots with no failed units",'[ "$(systemctl list-units --failed --no-legend | wc -l)" -eq 0 ]'),
    ("auto","the unit restarts itself after being killed",'grep -qE "^Restart=" /etc/systemd/system/lab-demo.service'),
    ("manual","you can read systemd-analyze critical-chain and name the slowest unit","")]),

dict(n=2, title="Users, sudo, permissions and ACLs", runs="VM: node1", tier="lab",
  obj="Give a service account exactly the access it needs and nothing else.",
  why="\"It works when I run it as root\" is where most security incidents begin. Least privilege is a habit you build with your hands.",
  work=["useradd -r -s /sbin/nologin", "visudo and /etc/sudoers.d/", "sudo -l -U <user>", "setgid directories", "setfacl / getfacl", "umask"],
  checks=[("auto","a system account appsvc exists with no login shell",'id appsvc && getent passwd appsvc | grep -qE "(nologin|false)$"'),
    ("auto","appsvc may restart one service and nothing else",'sudo -l -U appsvc | grep -q "systemctl restart"'),
    ("auto","appsvc cannot become root",'! sudo -l -U appsvc | grep -qE "\\(ALL\\).*ALL"'),
    ("auto","the shared directory is setgid","[ -g /srv/shared ]"),
    ("auto","an ACL grants appsvc access without changing the owner",'getfacl -p /srv/shared 2>/dev/null | grep -q "^user:appsvc:"'),
    ("manual","you can explain every line of sudo -l -U appsvc","")]),

dict(n=3, title="Processes, signals, cgroups v2 and limits", runs="VM: node1", tier="lab",
  obj="Constrain a process so it cannot take the machine down with it.",
  why="Containers are cgroups plus namespaces. Meet the primitives directly and container behaviour stops being magic.",
  work=["ps -eo pid,ppid,stat,cmd", "kill -TERM vs -KILL, trap", "/sys/fs/cgroup/", "systemd-run --scope -p MemoryMax=", "systemctl set-property", "ulimit, /etc/security/limits.d/"],
  checks=[("auto","cgroups v2 is the unified hierarchy",'mount | grep -q "cgroup2 on /sys/fs/cgroup"'),
    ("auto","a service is capped with MemoryMax",'systemctl show lab-cap.service -p MemoryMax | grep -qv "infinity"'),
    ("auto","the same service is capped with CPUQuota",'systemctl show lab-cap.service -p CPUQuotaPerSecUSec | grep -qv "infinity"'),
    ("auto","a nofile limit is raised for one account only",'grep -rqE "nofile" /etc/security/limits.d/'),
    ("manual","you triggered the memory cap and found the kill in the journal",""),
    ("manual","you can explain why SIGKILL cannot be trapped","")]),

dict(n=4, title="Storage: LVM, filesystems and mount units", runs="VM: node1 + extra disk", tier="ci",
  obj="Grow a filesystem while it is mounted, and mount it persistently.",
  why="Disk full at 3am is the most common page in operations. Growing storage without downtime is the fix, and it should be boring.",
  work=["lsblk, blkid, pvcreate, vgcreate, lvcreate", "lvextend, resize2fs / xfs_growfs", "mkfs.xfs, mkfs.ext4", "/etc/fstab vs .mount units", "df -h vs du -sh", "lsof +L1 for deleted-but-open files"],
  checks=[("auto","the volume group labvg exists","vgs labvg"),
    ("auto","a logical volume labdata exists in it","lvs labvg/labdata"),
    ("auto","it is mounted at /srv/data","mountpoint -q /srv/data"),
    ("auto","the mount is persistent",'grep -q "/srv/data" /etc/fstab || systemctl is-enabled srv-data.mount'),
    ("auto","the filesystem fills the logical volume after extending",'df --output=avail /srv/data | tail -1 | grep -qE "[0-9]"'),
    ("manual","you extended it live, with no unmount, and watched df change",""),
    ("manual","you found a deleted-but-still-open file with lsof +L1","")]),

dict(n=5, title="Logs and time: journald, logrotate and chrony", runs="VM: node1", tier="lab",
  obj="Make logs persistent, bounded, and correctly timestamped.",
  why="Every diagnosis in Days 6-20 is log reading. Unbounded logs fill the disk; wrong clocks make correlation across hosts impossible.",
  work=["journalctl -u, -b, -p, --since, -f", "/etc/systemd/journald.conf", "Storage=persistent, SystemMaxUse=", "logrotate.d and logrotate -d", "chronyc sources / tracking", "timedatectl"],
  checks=[("auto","the journal is persistent across reboots","[ -d /var/log/journal ]"),
    ("auto","journal size is bounded",'grep -qE "^SystemMaxUse=" /etc/systemd/journald.conf'),
    ("auto","the clock is synchronised",'chronyc tracking | grep -q "Leap status.*Normal"'),
    ("auto","the timezone is set deliberately",'timedatectl show -p Timezone --value | grep -q .'),
    ("auto","a logrotate rule exists for your own log",'ls /etc/logrotate.d/ | grep -q .'),
    ("manual","logrotate -d showed your rule doing what you intended","")]),

dict(n=6, title="Interfaces, routing and building the namespace lab", runs="Host: network namespaces", tier="ci",
  obj="Build a four-node routed network inside your kernel and prove packets cross it.",
  why="This is real kernel networking, not a simulation: real interfaces, real routing tables, real packets. It is also the environment Days 7-10 and 18 run in, at zero memory cost.",
  work=["ip netns add / exec", "ip link add type veth", "ip addr, ip route", "net.ipv4.ip_forward", "ip -br addr, ip route get", "lab/lab.sh netns-up"],
  checks=[("auto","all four namespaces exist",'for n in client router resolver auth; do ip netns list | grep -qw "$n" || exit 1; done'),
    ("auto","the client has an address on 10.10.0.0/24",'ip netns exec client ip -br addr | grep -q "10.10.0.2"'),
    ("auto","the router forwards IPv4",'[ "$(ip netns exec router sysctl -n net.ipv4.ip_forward)" = "1" ]'),
    ("auto","the client reaches the auth network through the router","ip netns exec client ping -c1 -W2 10.10.2.2"),
    ("auto","the client has a default route",'ip netns exec client ip route | grep -q "^default"'),
    ("manual","you can draw the topology from ip route output alone","")]),

dict(n=7, title="The DNS resolution path", runs="Host: network namespaces", tier="ci",
  obj="Trace one name lookup through every layer that can answer it.",
  why="\"It is always DNS\" is a joke because it is usually true. Knowing which layer answered is the difference between a five minute fix and an afternoon.",
  work=["getent hosts vs dig", "/etc/nsswitch.conf", "/etc/hosts", "/etc/resolv.conf", "systemd-resolved and resolvectl", "dig +trace, +short, +norecurse"],
  checks=[("auto","nsswitch consults files before dns",'grep -qE "^hosts:[[:space:]]+files" /etc/nsswitch.conf'),
    ("auto","a hosts entry beats DNS for the same name",'ip netns exec client getent hosts lab.test | grep -q .'),
    ("auto","the client has a nameserver configured",'ip netns exec client grep -q "nameserver" /etc/resolv.conf || ip netns exec client cat /etc/resolv.conf'),
    ("auto","dig and getent are both available to compare","command -v dig && command -v getent"),
    ("manual","you can explain why dig ignored /etc/hosts and getent did not",""),
    ("manual","you followed one name from application call to authoritative answer","")]),

dict(n=8, title="Running DNS: authoritative and recursive", runs="Host: network namespaces", tier="ci",
  obj="Serve your own zone, then resolve it recursively from another namespace.",
  why="Reading DNS is one skill; owning a zone is another. Days 10, 12 and 17 all need names that resolve to your own machines.",
  work=["unbound or bind in a namespace", "a zone file: SOA, NS, A, CNAME", "authoritative vs recursive", "dig SOA / NS / ANY", "TTL and negative caching", "ss -ulpn to see the listener"],
  checks=[("auto","something is listening on port 53 in the auth namespace",'ip netns exec auth ss -ulpn | grep -q ":53"'),
    ("auto","the zone answers with a SOA","ip netns exec client dig +short SOA lab.test @10.10.2.2 | grep -q ."),
    ("auto","an A record resolves from the client","ip netns exec client dig +short A www.lab.test @10.10.2.2 | grep -q ."),
    ("auto","the resolver namespace also answers for the zone","ip netns exec client dig +short A www.lab.test @10.10.1.2 | grep -q ."),
    ("auto","an unknown name returns NXDOMAIN not an error",'ip netns exec client dig nope.lab.test @10.10.2.2 | grep -q "NXDOMAIN"'),
    ("manual","you lowered a TTL and watched the cache expire","")]),

dict(n=9, title="Packet-level debugging", runs="Host: network namespaces", tier="ci",
  obj="Prove where a packet stops, instead of guessing.",
  why="When two hosts disagree about whether traffic arrived, only a capture settles it. This day is the one you will reuse most.",
  work=["tcpdump -ni, -w, host/port filters", "ss -tulpn, ss -s", "ping vs traceroute vs mtr", "ip route get", "MTU and path MTU discovery", "conntrack basics"],
  checks=[("auto","tcpdump can capture on a router interface","ip netns exec router timeout 3 tcpdump -c1 -ni any -w /tmp/lab.pcap; [ -s /tmp/lab.pcap ]"),
    ("auto","the capture contains packets","tcpdump -r /tmp/lab.pcap 2>/dev/null | grep -q ."),
    ("auto","ss reports the DNS listener",'ip netns exec auth ss -ulpn | grep -q ":53"'),
    ("auto","ip route get names the outgoing interface",'ip netns exec client ip route get 10.10.2.2 | grep -q "dev"'),
    ("manual","you attributed a dropped packet to a specific hop",""),
    ("manual","you lowered an MTU, broke a transfer, and diagnosed it from the capture","")]),

dict(n=10, title="TLS on the wire and a private CA", runs="Host: network namespaces", tier="ci",
  obj="Run your own certificate authority and understand what a client actually verifies.",
  why="Certificate errors are the most common self-inflicted outage. Issuing certificates yourself makes the trust chain concrete, and Day 17 needs this CA.",
  work=["openssl genrsa / ecparam", "openssl req with SANs", "openssl x509 -req -CA", "openssl verify -CAfile", "openssl s_client -connect -showcerts", "trust anchors in /etc/pki/"],
  checks=[("auto","a CA certificate exists and is marked as a CA",'openssl x509 -in ca/ca.crt -noout -text | grep -q "CA:TRUE"'),
    ("auto","a server certificate carries a subjectAltName",'openssl x509 -in ca/server.crt -noout -text | grep -q "Subject Alternative Name"'),
    ("auto","the server certificate verifies against the CA","openssl verify -CAfile ca/ca.crt ca/server.crt"),
    ("auto","the private key matches the certificate",'[ "$(openssl x509 -noout -modulus -in ca/server.crt 2>/dev/null | openssl md5)" = "$(openssl rsa -noout -modulus -in ca/server.key 2>/dev/null | openssl md5)" ]'),
    ("manual","you can read an s_client chain and say why it was trusted or refused",""),
    ("manual","you made verification fail on purpose, by hostname and by expiry","")]),
]


# --------------------------------------------------------------------------
# Per-day script tables and run instructions.
#
# Added day by day as the scripts get written. A day with no entry here still
# renders fine - its README just tells you to put your own work in scripts/.
#
# SCRIPTS: (filename, what it does, needs_root)
# HOWTO:   markdown, rendered as the "Run it on the lab" section
# --------------------------------------------------------------------------

SCRIPTS = {
    1: [
        ("lab-demo.sh", "The service payload. Long-running, prints to the journal, traps SIGTERM.", False),
        ("setup.sh", "Installs the payload and writes, enables and starts `lab-demo.service`. Idempotent.", True),
        ("explore-boot.sh", "Read-only guided tour: boot timing, blame, critical chain, failed units, cgroup.", False),
        ("break-and-fix.sh", "Kills the service to watch `Restart=always` work. `--hard` also breaks the unit file, then repairs it.", True),
        ("teardown.sh", "Removes everything `setup.sh` installed, and proves it is gone.", True),
    ],
}

HOWTO = {
    1: """
### 1. On your laptop, bring up one VM

```bash
cd bash-mastery-linux
./lab/lab.sh check          # first time only: does this machine have KVM?
./lab/lab.sh image          # first time only: ~900 MB download, cached
./lab/lab.sh up control     # ~1 GB of RAM, about a minute
./lab/lab.sh status         # wait until control has an IP address
```

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push control
```

That lands `days/` and `lab/` in `~/lab` on the VM. Both are needed: every
`verify.sh` sources `lab/verify-lib.sh`, so pushing `days/` alone gives you a
day that cannot check itself.

Re-run `push` whenever you edit anything on the host. It overwrites, so it is
safe to run as often as you like.

### 3. Work through the day on the VM

```bash
./lab/lab.sh ssh control
cd ~/lab/days/day01
```

Then, in this order:

```bash
less scripts/setup.sh              # 1. read it BEFORE running it
sudo ./scripts/setup.sh            # 2. install the service
```

```bash
systemctl status lab-demo          # 3. look at your own work
journalctl -u lab-demo -f          #    ctrl-c when you have seen enough
systemctl cat lab-demo
```

```bash
./scripts/explore-boot.sh          # 4. the tour. no root needed
```

Do not skim this one. It prints the command it is about to run before each
block, and the reason you are looking at the output. Stop at anything you
cannot explain and go read `man systemd.service` or `man journalctl` on the
VM - both are installed.

```bash
sudo ./scripts/break-and-fix.sh          # 5. crash it, watch it come back
sudo ./scripts/break-and-fix.sh --hard   # 6. now break the unit file itself
```

Step 6 is the important one. A crashed process and a broken unit file are two
different failures with two different signatures, and the whole skill is
telling them apart from `systemctl status` alone.

### 4. Check yourself

```bash
sudo ./verify.sh
echo "exit: $?"
```

Expected on a healthy Day 01: **4 PASS, 1 YOU, exit 0.** The `YOU` line is the
critical-chain question - nothing can grade that but you.

Root is needed because the checks read `/etc/systemd/system/` and query unit
state. Without it the run exits 0 with everything skipped, which is not a pass.

| If you see | It means | Do this |
|---|---|---|
| `FAIL a custom unit is installed and enabled` | `setup.sh` did not finish, or you ran it in the wrong directory | `cd ~/lab/days/day01 && sudo ./scripts/setup.sh` |
| `FAIL that unit is running` | it started and then died | `journalctl -u lab-demo -n 30` |
| `FAIL the machine boots with no failed units` | something unrelated is broken on the VM - a genuine finding, not a bug in the day | `systemctl list-units --failed`, then fix it and write down what it was |
| `SKIP missing root` | you forgot `sudo` | run it again with `sudo` |

### 5. Prove it survives a reboot

This is the actual objective of the day, and no script can do it for you:

```bash
sudo reboot                      # your ssh session will drop
```

Then from the host, once it is back (about 20 seconds):

```bash
./lab/lab.sh ssh control
systemctl is-active lab-demo     # active
systemctl is-enabled lab-demo    # enabled
systemd-analyze critical-chain   # does your service appear? why not?
```

If `is-enabled` says `enabled` but `is-active` says `inactive`, you have found
the difference between the two words the hard way - which is the best way.

### 6. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

You do not have to. Nothing in Days 02-20 conflicts with `lab-demo`, and
leaving it running gives you a harmless service to practise on later. Run the
teardown if you want to do the whole install-inspect-remove loop again from
scratch.

To give the RAM back to your laptop when you are done for the day:

```bash
./lab/lab.sh down control        # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download.
""",
}

for _d in DAYS_1_10:
    if _d["n"] in SCRIPTS:
        _d["scripts"] = SCRIPTS[_d["n"]]
    if _d["n"] in HOWTO:
        _d["howto"] = HOWTO[_d["n"]]
