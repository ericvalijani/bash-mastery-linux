# Day 09 - Packet-level debugging

> Prove where a packet stops, instead of guessing.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

Two people look at the same outage and disagree. One says the request was never sent. The other says it was sent and never answered. Both are certain, neither has evidence, and the call goes on for an hour.

A capture ends that argument in ten seconds, because it is taken in the middle of the path and belongs to neither side.

Today builds nothing. Day 06's four namespaces already exist and already work. What today adds is the ability to prove things about them: which interface a packet leaves by, whether it arrived at the hop in the middle, whether anything was listening when it got there, and why a path that answers ping perfectly can still lose every large transfer.

That last one is the day's real lesson. The failures worth practising are not the ones that print an error.

## What you will work with

- `ip route get DEST` - the kernel's routing decision for one destination, not your reading of the table
- `tcpdump -ni IFACE`, `-c N`, `-w FILE`, `-nr FILE` - capture live, capture to a file, re-read it afterwards
- capture filters - `icmp`, `host 10.10.2.2`, `port 53`
- `ip netns exec NS tcpdump ...` - capturing inside a namespace, where the traffic actually is
- `ss -ulpn`, `ss -s` - who is listening, and how many sockets exist
- `ip -s link show` - packet and drop counters that were kept while you were not watching
- `ip neigh` - the MAC behind an address, and what `PERMANENT` means there
- `ping -M do -s SIZE` - a packet that refuses to be fragmented, which is how you find an MTU
- `ping -t 1` - a TTL small enough to die at a known hop

## Verify

Checked automatically:

- [ ] all four namespaces from Day 06 are up
- [ ] the client reaches the auth namespace at 10.10.2.2
- [ ] ip route get names veth-cl as the way out of the client
- [ ] the saved capture holds at least one ICMP packet
- [ ] lab-trace reports requests and replies on the router leg

Only you can confirm:

- [ ] you attributed a dropped packet to a specific hop, using a capture rather than a guess
- [ ] you lowered an MTU, broke a large transfer, and read the cause off the interface

Run the automatic checks with:

```bash
sudo ./days/day09/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `scripts/setup.sh` | Makes sure Day 06's topology is up, installs `lab-trace`, takes one capture to prove capturing works | yes |
| `scripts/lab-trace.sh` | The payload. Route, wire and reply for one destination, in one answer | yes |
| `scripts/explore-packets.sh` | Twelve looks at the same network, each with a tool that answers one kind of question | yes |
| `scripts/break-and-fix.sh` | Five failures and the shape of evidence each one leaves. `--hard` adds the two that stay silent | yes |
| `scripts/teardown.sh` | Removes `lab-trace` and the captures, leaves the network alone | yes |

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

### 1. No VM today

Everything here happens in network namespaces on the machine you are reading this on. Nothing is installed system-wide except one script under `/usr/local/bin`, and nothing survives a reboot. Run it wherever you like - including your own laptop.

If a VM from an earlier day is still running and you want the memory back:

```bash
./lab/lab.sh down node1
```

### 2. Check what you already have

Today reuses Day 06's four namespaces. This is a diagram, not something to paste into a shell:

```text
client 10.10.0.2 --- 10.10.0.1 router 10.10.1.1 --- 10.10.1.2 resolver
                            router 10.10.2.1 --- 10.10.2.2 auth
```

If they are gone - and a reboot always removes them - `setup.sh` rebuilds them for you by calling Day 06's setup. That is expected, not a fault.

Day 08's DNS servers are optional. They are not required, but DNS is more interesting to capture than ping, so leave them running if you have them.

### 3. Build today's view of it

```bash
sudo ./days/day09/scripts/setup.sh
```

It checks for `ip`, `tcpdump`, `ss` and `ping`, makes sure the topology is up, asks the kernel which interface the client uses, installs `lab-trace`, and then takes one real capture and reads it back. That last step matters: a day about evidence should not start by assuming its own tools work.

If tcpdump is missing:

```bash
sudo dnf install -y tcpdump iproute iputils          # RHEL family
sudo apt-get install -y tcpdump iproute2 iputils-ping # Debian/Ubuntu
```

### 4. Look at what you built, then break it

```bash
sudo lab-trace                    # the path to 10.10.2.2, end to end
sudo lab-trace 10.10.9.9          # a destination that does not exist
sudo ./days/day09/scripts/explore-packets.sh
```

Then the five failures:

```bash
sudo ./days/day09/scripts/break-and-fix.sh
sudo ./days/day09/scripts/break-and-fix.sh --hard
```

The first three are loud: an interface down, no route, and a far end with no way back. Read the third one twice - requests arrive, replies never come, and the sender sees exactly what it would see if the destination were switched off.

`--hard` adds the two that stay quiet. An MTU of 1280 that lets every ping through and refuses a 1400-byte packet, and a permanent ARP entry that hands correctly routed packets to a MAC address nobody owns.

Do the MTU one by hand as well, because it is the manual check:

```bash
sudo ip -n client link set veth-cl mtu 1280
sudo ip netns exec client ping -c2 -W2 10.10.2.2
sudo ip netns exec client ping -c1 -W2 -M do -s 1400 10.10.2.2
sudo ip netns exec client ip -brief link show veth-cl
sudo ip -n client link set veth-cl mtu 1500
```

Small packets fine, large packets gone, and the only place the answer is written down is the interface itself.

### 5. Check yourself

```bash
sudo ./days/day09/verify.sh
```

Five automatic checks and two that are yours. The checks need root, because capturing and entering namespaces both do.

### 6. Optional cleanup

```bash
sudo ./days/day09/scripts/teardown.sh
```

That removes `lab-trace`, stops any tcpdump still running in a namespace, and deletes `/var/log/lab-trace`. The namespaces stay - they belong to Day 06.

## Notes

The order of the tools is the whole method, and it is not the order people reach for them in:

1. `ip route get` first. It tells you where to capture, and it catches the one failure a capture can never show you - a packet that was never sent.
2. `tcpdump` in the middle. Not at the sender, where "I sent it" is already believed, and not at the receiver, where "nothing arrived" is already believed.
3. `ss` at the far end. A packet can arrive perfectly and still be refused, because nothing was listening.
4. Counters last. `ip -s link` was counting drops while you were arguing.

Two things worth remembering after today. tcpdump has to be running before the traffic exists - an empty capture usually means a late tcpdump, not a dead network. And a capture with no `-c` limit and no rotation will fill a disk quietly, which turns the machine you were debugging into a second incident.

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 10 - TLS on the wire and a private CA.**
