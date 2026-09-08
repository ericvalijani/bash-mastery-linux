#!/usr/bin/env bash
#
# teardown.sh - remove the four namespaces and prove nothing was left behind.
#
#   sudo ./teardown.sh
#
# Order matters less today than on Day 05, because deleting a namespace takes
# everything inside it with it - but what "everything" means is worth watching
# rather than assuming, which is most of what this script prints.

set -uo pipefail

say() { printf '\n==> %s\n' "$*"; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "needs root:  sudo $0" >&2
  exit 1
fi

NS_LIST=(client router resolver auth)

say "before: what exists"
ip netns list || true
echo
echo "veth interfaces visible on your own machine (should be none of ours):"
ip -br link | grep -c 'veth-' || true

# Deleting a namespace deletes every interface inside it. A veth is a pair, and
# a pair cannot survive with one end gone - so removing 'client' also removes
# router:veth-rcl, three namespaces away from the command you typed. Delete the
# leaves first and watch the router lose a leg each time.
say "deleting the leaves, one at a time"
for ns in client resolver auth; do
  if ip netns list | grep -qw "$ns"; then
    ip netns del "$ns"
    printf '  deleted %-9s router legs remaining: ' "$ns"
    ip -n router -br link 2>/dev/null | grep -c 'veth-' || echo 0
  else
    echo "  $ns was not there"
  fi
done

say "deleting the router"
if ip netns list | grep -qw router; then
  ip netns del router
  echo "  deleted router"
else
  echo "  router was not there"
fi

say "after: proving each one is gone"
for ns in "${NS_LIST[@]}"; do
  if ip netns list | grep -qw "$ns"; then
    printf '  STILL THERE: %s\n' "$ns"
  else
    printf '  gone: %s\n' "$ns"
  fi
done

# Any veth end left in the root namespace is the signature of a half-finished
# build, not of this teardown. setup.sh clears them on its next run, but you
# should see the count rather than trust the claim.
say "stranded interfaces on your own machine"
stranded="$(ip -br link | grep -c 'veth-cl\|veth-rcl\|veth-rs\|veth-rrs\|veth-au\|veth-rau' || true)"
echo "  $stranded"
if [[ "$stranded" != "0" ]]; then
  echo "  That is a finding, not a bug - go and read why:"
  echo "    ip -d link show | grep -A1 veth"
fi

# The directory iproute2 uses for named namespaces stays behind, empty. It is
# a mount point, not state, and it is not worth removing.
say "what deliberately stays"
echo "  /var/run/netns still exists, empty - it is how 'ip netns' names things"
echo "  your own machine's net.ipv4.ip_forward: $(sysctl -n net.ipv4.ip_forward)"
echo "  never changed by any script today, and this is the proof"

cat <<'EOF'

Nothing persisted, and nothing needed to. The whole lab is a second of kernel
work away:

  sudo ./days/day06/scripts/setup.sh     the way you built it today
  sudo ./lab/lab.sh netns-up             the same topology, one command

Days 07-10 and 18 begin with one of those two lines, so run teardown as often
as you like - on this day it costs you nothing.
EOF
