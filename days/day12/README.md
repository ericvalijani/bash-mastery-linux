# Day 12 - SSH hardening, bastions and fail2ban

> Keys only, one group allowed in, a jail on the log, and a jump host in front.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | VM: node1 |
| **Memory** | ~2 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

SSH is the door. It is also the service most often left with defaults that a scanner finds in minutes.

But the reason this day takes a whole day is not the hardening - that is six lines in a file. It is that SSH is the one service where a configuration mistake removes your ability to fix the configuration. Every other day in this course, a bad change means a broken service. Here it means a broken service *and* no way in.

So the work is really about a habit: read the effective policy rather than the file, test the policy for a named user rather than by logging out, and validate before loading. `sshd -T` and `sshd -T -C user=you` are the two commands that turn this from a nervous edit into a boring one.

## What you will work with

- **`sshd -T`** - print the effective server configuration after includes, defaults, and precedence have been resolved. Reading this output is safer than trusting a file that may not be the value sshd actually uses; `sshd -T -C user=...` goes further and evaluates policy for one named connection.
- **`/etc/ssh/sshd_config.d/`** - keep lab hardening in a focused drop-in instead of rewriting the distribution file. On Rocky 9 the include appears near the top, and sshd keeps the first value it reads for most keywords, so precedence is deliberately part of the exercise.
- **`PasswordAuthentication` and `PermitRootLogin`** - separate password access from root access rather than treating “SSH is hardened” as one switch. `prohibit-password` still permits root keys, while `no` forbids root completely; you should be able to explain which policy you chose.
- **`AllowUsers` and `AllowGroups`** - add an explicit admission list on top of valid credentials. The lab uses a group so future access changes happen with group membership rather than another risky sshd configuration edit.
- **`ProxyJump` and `~/.ssh/config`** - reach a destination through a bastion and then encode both hops as reusable client configuration. `ssh -G HOST` shows the client's effective choices just as `sshd -T` shows the server's.
- **`fail2ban-client status sshd`** - verify that fail2ban is reading SSH failures and maintaining the jail that can add firewall bans. You will deliberately ban and unban an address so a refusal caused by fail2ban is distinguishable from a broken sshd configuration.

## Verify

Checked automatically:

- [ ] password authentication is off
- [ ] root cannot log in with a password
- [ ] login is restricted to a named user or group
- [ ] the config is valid
- [ ] fail2ban is watching sshd

Only you can confirm:

- [ ] you reached node1 with ProxyJump through a bastion, and you can explain each hop
- [ ] you triggered a ban on purpose and then unbanned yourself

Run the automatic checks with:

```bash
sudo ./days/day12/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH - so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `setup.sh` | Confirms you have a key **before** it disables passwords, creates the `labssh` group and puts you in it, writes the hardening drop-in, validates with `sshd -t` and reloads, then configures a fail2ban jail with a deliberately short ban. Idempotent. | yes |
| `lab-ssh.sh` | The payload. Shows the files, the effective config, and where they disagree, plus the jail and the refusals in the log. With a username it answers "would this person get in, and why". Installed as `/usr/local/bin/lab-ssh`. | yes |
| `explore-ssh.sh` | Twelve read-only stops: include order, drop-in precedence, the four keywords that decide access, `-C` for one user, `ssh -G` on the client side, host key fingerprints, the log lines fail2ban reads, and the jail. | yes |
| `break-and-fix.sh` | Three failures and their repairs: a drop-in that never wins, an allow list that excludes you, and banning yourself. `--hard` adds the Match block that reverses your policy and the one that is not survivable. | yes |
| `teardown.sh` | Releases bans first, removes the drop-ins, validates before reloading, and proves the allow list is gone rather than assuming it. Leaves sshd and fail2ban running. | yes |

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

### 1. On your laptop, bring up node1

Day 12 runs on **`node1`**. Day 11 left it running; if you took it down, a rebuilt `node1` is fine - this day needs nothing from Day 11 except the habit of checking what the kernel really has.

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up node1            # 2 GB, about a minute
```

The curriculum lists this day as `control + node1`, because a bastion needs two hosts. Two VMs use about 3 GB. **You do not need the second VM for the automatic checks** - all five run on `node1` alone - and section 3 below gives you a one-host version of the ProxyJump exercise. Bring up `control` as well only if you have the memory to spare.

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push node1          # carries both days/ and lab/
./lab/lab.sh ssh node1
```

`push` is the step people skip. Editing a file on your laptop changes nothing on the VM until this runs.

### 3. Work through the day on the VM

Check where you are before changing the service you are connected through:

```bash
hostname                         # must print: node1
cd ~/lab/days/day12
```

fail2ban is not in the base Rocky repositories - it comes from EPEL:

```bash
sudo dnf install -y epel-release
sudo dnf install -y fail2ban fail2ban-firewalld openssh-server
```

Before you change anything, read what is already there:

```bash
sudo sshd -T | sort | head -20
sudo grep -nE '^\s*Include' /etc/ssh/sshd_config
ls -1 /etc/ssh/sshd_config.d/
```

That `Include` line is at the **top** of the file on Rocky 9, and sshd keeps the **first** value it reads for most keywords. So a drop-in beats the main file - the opposite of how Apache or nginx behave, and the subject of failure 1.

Open a second terminal to your laptop now and leave it connected to `node1`. Everything below is safe, but the habit is the point: never make the only session you have the one you are experimenting on.

In this order:

```bash
less scripts/setup.sh            # 1. read it BEFORE running it
sudo ./scripts/setup.sh          # 2. key check, group, drop-in, reload, jail
```

Step 1 of the script is the one to notice: it refuses to continue if your account has no `authorized_keys`. Disabling passwords on an account with no key is the single most common way people lose a cloud VM.

```bash
sudo /usr/local/bin/lab-ssh
sudo /usr/local/bin/lab-ssh "$USER"
sudo /usr/local/bin/lab-ssh root
```

Type the full path. `sudo` on Rocky uses its own `secure_path`, which does not include `/usr/local/bin`, so `sudo lab-ssh` will tell you the command does not exist even though it is installed.

Compare the last two. Your account is in `labssh` and gets in; `root` is not, and the verdict says so - even though `PermitRootLogin prohibit-password` suggests root has a way in. The allow list is checked first.

```bash
sudo ./scripts/explore-ssh.sh    # 3. the tour
```

Stop at stop 7. `sshd -T -C user=NAME` is the command that makes this day safe: it answers "what would sshd decide for this person" without requiring you to log out and find out.

Now the ProxyJump exercise, which is the first `YOU` item. **With two VMs**, use `control` as the bastion:

```bash
# on your laptop
ssh -J lab@control lab@node1
```

**With one VM**, you can still prove you understand the mechanic, because a jump host is just an SSH connection opened through another SSH connection:

```bash
# on your laptop - node1 is both the jump host and the destination
ssh -J lab@192.168.122.13 lab@127.0.0.1
```

The second hop is made *from* `node1`, so `127.0.0.1` means node1 itself. Then write it down properly so you never type the flag again:

```bash
cat >> ~/.ssh/config <<'EOF'

Host node1
    HostName 192.168.122.13
    User lab

Host behind
    HostName 127.0.0.1
    User lab
    ProxyJump node1
EOF

ssh -G behind | grep -E '^(hostname|user|proxyjump) '
ssh behind hostname
```

`ssh -G` prints the client's effective config the way `sshd -T` prints the server's. When a connection lands somewhere you did not expect, that is the first command, not the last.

```bash
sudo ./scripts/break-and-fix.sh          # 4. three failures, three fixes
sudo ./scripts/break-and-fix.sh --hard   # 5. the two that get misdiagnosed
```

Failure 4 is the one worth the time. `sshd -T` reports `passwordauthentication no` while `sshd -T -C user=you` reports `yes`, because a `Match` block re-enabled it for exactly the account an attacker would target. Both commands are correct. An audit that only runs the first one passes a machine that is not hardened.

### 4. Check yourself

```bash
sudo ./days/day12/verify.sh
```

Five automatic checks and two that are yours. The second `YOU` item wants a ban you caused on purpose:

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd banip 127.0.0.1
sudo fail2ban-client status sshd            # Currently banned: 1
sudo fail2ban-client set sshd unbanip 127.0.0.1
```

The jail is set to a two-minute ban on purpose. A ten-hour default on a lab machine teaches you nothing except how to rebuild a VM.

### 5. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

It releases bans before touching the config, validates before reloading, and checks that the allow list is really gone. sshd and fail2ban stay - Days 13 and 14 reach this machine over SSH.

### 6. Back on your laptop

```bash
exit
./lab/lab.sh down node1          # frees the memory; takes the disk with it
```

Day 13 uses `node1` again, so you can leave it running if you have the RAM.

## Notes

The order that keeps you logged in, every time:

1. **Make the credential work first.** Key in `authorized_keys`, user in the allowed group. Build the allow list before you enforce it, never after.
2. **Validate.** `sudo sshd -t` parses the config without loading it. It catches typos, not policy mistakes.
3. **Ask about a person, not a file.** `sudo sshd -T -C user=you,host=localhost,addr=127.0.0.1`. This is the step that catches the policy mistakes `-t` cannot.
4. **Reload, do not restart.** `systemctl reload sshd` re-reads the config and leaves established sessions alone. A restart plus a bad policy ends the session you would have used to fix it.
5. **Prove a new login works from a second terminal** before you close the first one.

Two things worth keeping. `PermitRootLogin prohibit-password` is not `no` - root may still log in with a key, which is a reasonable choice for automation and a surprise in an audit, so decide which one you meant. And a fail2ban ban is a firewall rule, not an SSH setting: when a healthy sshd refuses a healthy client for no visible reason, `fail2ban-client status sshd` is the second thing to check and `sshd -T` is a waste of time.

The difference between someone who hardens SSH confidently and someone who does it once a year with sweaty palms is not knowledge of the keywords. It is having a second terminal open.

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 13 - SELinux: contexts, booleans and denial triage.**
