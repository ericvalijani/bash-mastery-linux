# Day 16 — WireGuard: a private network between hosts

**Phase:** Production operations
**Runs on:** `control` + `node1`, on both of them
**Time:** about ninety minutes

Every environment has a network you are not supposed to expose: a database
port, a metrics endpoint, an admin interface that was written in 2011. The
usual answer is a VPN, and the usual VPN is too large to hold in your head.

WireGuard is about four thousand lines of kernel code and a config file with
six keys in it. Today you build a tunnel between two VMs, by hand, twice —
because each host generates its own private key and the keys are exchanged out
of band, which is most of the point.

The part worth your attention is not `wg-quick up`. It is that one line,
`AllowedIPs`, is simultaneously a routing table and an access control list,
and that WireGuard's answer to anything that fails to authenticate is silence.
No error, no log line, nothing. Four of today's failures look exactly like a
working tunnel until you ask for the handshake.

## What you will work with

- `wg genkey` and `wg pubkey`, and `umask 077` **before** you generate rather
  than `chmod` after — a private key only has to leak once
- `/etc/wireguard/wg0.conf`: `[Interface]` for this host, `[Peer]` for the
  other, and no notion of client or server anywhere
- `AllowedIPs` in both of its jobs: a route outbound, a source-address filter
  inbound — so the two ends are coupled and the symptom shows at the healthy
  one
- `wg show` versus `wg showconf`: live kernel state, and the fact that nothing
  re-reads the file after the interface comes up
- `wg-quick up / down / strip`, which is a shell script wrapping `ip(8)` —
  `Address` and `MTU` are its keys, not WireGuard's
- `wg syncconf`, which applies a changed file without dropping the tunnel or
  your session with it
- `systemctl enable wg-quick@wg0`, and the difference between a tunnel that
  works now and one that works after a reboot
- `firewalld` and one UDP port, with no TCP fallback to fall back to
- MTU: 1500 − 80 = 1420, and what happens when you get it wrong (ping passes,
  transfers hang)

No kernel module to build. WireGuard has been in the mainline kernel since
5.6, so Rocky 9 needs `wireguard-tools` and nothing else — no DKMS, no elrepo,
nothing to compile.

## Two VMs, and the memory

| VM | Memory | Tunnel address | Why |
|---|---|---|---|
| `control` | 1536 MB | `10.20.0.1/24` | one end |
| `node1` | 2048 MB | `10.20.0.2/24` | the other end |

About **3.5 GB** in total, down from Day 15's three VMs. Nothing in this lab
is below 1536 MB, which is the minimum Rocky 9 recommends and the number
`virt-install` warns about.

The `10.20.0.0/24` addresses are the tunnel's own. They are not the
`192.168.122.x` lab addresses and they do not replace them — the tunnel cannot
carry the packets that build the tunnel.

## Scripts

| Script | What it does |
|---|---|
| `scripts/setup.sh` | pass 1: keys, `wg0.conf`, prints this host's public key. Run on both VMs |
| `scripts/setup.sh <peer-key> <peer-addr>` | pass 2: adds the peer, opens the port, enables the unit, proves the handshake |
| `scripts/lab-wg.sh` | installed as `lab-wg`. `status`, `keys`, `routes`, `watch` |
| `scripts/explore-wg.sh` | twelve read-only stops through the tunnel you just built |
| `scripts/break-and-fix.sh` | four failures that look like success. `--hard` describes two lock-outs rather than causing them |
| `scripts/teardown.sh` | down, disabled, port closed. `--all` also deletes the keys |
| `verify.sh` | twelve automatic checks, two for you to judge |

## Run it

On your laptop, in the repository:

```bash
./lab/lab.sh up control node1           # ~3.5 GB
./lab/lab.sh status                     # read BOTH addresses
./lab/lab.sh push control               # carries days/ and lab/
./lab/lab.sh push node1                 # today runs on both hosts
./lab/lab.sh ssh control
```

Both hosts need the repository today, which is new — every earlier day ran its
scripts from `control` only. `push <vm>` with no path copies `days/` and
`lab/`; `push <vm> <path>` copies **only** that one file.

`lab.sh status` prints something like:

```
control   running   192.168.122.188     # EXAMPLE address — use your own
node1     running   192.168.122.105     # EXAMPLE address — use your own
```

Those are examples. DHCP leases move every time a VM is rebuilt, so read them
yourself each session rather than copying them from here.

Day 14 and Day 15 are not prerequisites. Today touches nothing they built.

### Pass 1, on each host

On `control`:

```bash
cd ~/lab/days/day16
sudo ./scripts/setup.sh
```

It prints a public key. In another terminal, on `node1`:

```bash
cd ~/lab/days/day16
sudo ./scripts/setup.sh
```

That prints a different public key. Two hosts, two keypairs, neither private
key having moved anywhere. If you find yourself copying a file called
`wg0.key` between machines, stop — that is not how this works.

### Pass 2, on each host, with the other one's key

On `control`, using `node1`'s public key and `node1`'s **lab** address:

```bash
sudo ./scripts/setup.sh <node1-public-key> 192.168.122.105
```

And on `node1`, using `control`'s:

```bash
sudo ./scripts/setup.sh <control-public-key> 192.168.122.188
```

The second one to run is the one that reports a handshake. The first will say
it is waiting, which is correct — a tunnel needs both ends to hold the other's
key, and until then packets arrive and get dropped without comment.

If the hostnames are not `control` and `node1`, tell it which end it is:

```bash
sudo ROLE=control ./scripts/setup.sh <peer-key> <peer-addr>
```

Then, in order:

```bash
sudo lab-wg                          # interface, peer, handshake, traffic
sudo lab-wg keys                     # what is public and what is not
sudo lab-wg routes                   # AllowedIPs as the routing table
sudo ./scripts/explore-wg.sh         # read the tunnel you just built
sudo ./scripts/break-and-fix.sh      # four failures that look like success
sudo ./verify.sh
```

Before `verify.sh`, reboot one of the VMs and watch the tunnel come back by
itself. One of the two manual checks is exactly that, and `enabled` is a claim
until you have tested it.

## What to actually look at

**There is no server.** Both ends listen on the same port, both can initiate,
and the only asymmetry is that one of them was told where the other is.
`Endpoint` is a hint, and it updates itself when a peer moves — which is why
WireGuard survives a laptop changing wifi mid-session, and why a DHCP lease
change on `node1` is not fatal.

**`AllowedIPs` is two things.** Outbound it is a route: `wg-quick` turned each
entry into `ip route add`. Inbound it is an ACL: a packet from that peer whose
source is not listed is dropped silently. So narrowing it on one side only
means traffic leaves and never returns — and the end you would naturally debug
is the one that is configured correctly. This is the second failure in
`break-and-fix.sh` and the one that costs people an afternoon.

**The handshake is the only evidence.** An interface with an address, a peer
and a route looks identical in `ip addr` whether it works or not. `wg show
wg0` and `latest handshake: never` is the whole diagnosis. `wg show wg0
transfer` is the second question: sent climbing, received zero means your
packets are leaving and being dropped at the far end.

**The crypto is not configurable.** No cipher list, no TLS version, no
downgrade to negotiate. That removes a whole category of misconfiguration, and
costs you the ability to fix a broken primitive with a config change — it
would take a new protocol version.

**Nothing re-reads the file.** `wg-quick up` parsed it once. Edit `wg0.conf`
afterwards and the kernel keeps what it was given, with no warning that the
two disagree. `diff <(wg-quick strip wg0) <(wg showconf wg0)` is the check,
and `wg syncconf` is the fix that does not drop the tunnel — on a management
VPN, `down && up` drops your own session.

**MTU is where the day goes if it goes.** 1420 is 1500 minus 80 bytes of
WireGuard overhead. Set it to 1500 and `ping` succeeds, `ssh` logs in, and
`scp` stalls at 0%, because only full-size packets die and the ICMP that would
have explained it is usually dropped somewhere in between.

**`wg-quick strip` and `wg showconf` do not print the same text.** Both
describe the same tunnel, but `strip` echoes your file with your order,
spacing and comments while `showconf` prints the kernel's normalized version.
Diff them raw and it always looks broken. Collapse the whitespace, keep the
peer settings, sort both sides — then a difference means a real unapplied
edit, which is the only thing worth checking.

**`firewall-cmd --permanent` needs the daemon.** On a freshly built VM,
`firewalld` is installed and stopped, and `--permanent` does not quietly fall
back to editing files — it prints `FirewallD is not running` and fails, which
is the first thing this day's `setup.sh` used to do. `firewall-offline-cmd`
writes the same XML with no daemon to ask. `setup.sh` now uses whichever
applies, then starts and enables `firewalld`, because a port "open" in a
policy nothing has loaded is a comment.

**Port scans see a closed port.** WireGuard does not reply to anything that
fails to authenticate, including with an error. A real security property, and
a real tax when you are the one debugging.

## Teardown

On each VM:

```bash
sudo ./scripts/teardown.sh          # down, disabled, port closed, keys kept
sudo ./scripts/teardown.sh --all    # keys and payload deleted too
```

Keys kept means `sudo wg-quick up wg0` puts the tunnel straight back. Keys
deleted means the far end now lists a public key that does not exist anywhere
— so if you delete them on one host, run `setup.sh` again on both.

Then, on your laptop:

```bash
./lab/lab.sh down control node1
```

## Done when

`./verify.sh` prints **12 passed, 0 failed**, the tunnel came back after a
reboot without you touching it, and you can say — without looking it up — what
`AllowedIPs` does to a packet going out and to a packet coming in.

---

Next up: **Day 17 — Reverse proxy and TLS termination.**
