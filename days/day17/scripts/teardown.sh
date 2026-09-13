#!/usr/bin/env bash
#
# Day 17 teardown.
#
#   sudo ./scripts/teardown.sh          proxy, backend, ports, nginx config
#   sudo ./scripts/teardown.sh --all    also the certificates, the CA and the
#                                       trust anchor
#
# Leaves nginx installed. Removing a package is not the interesting part.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

NAME="${LAB_SITE:-www.lab.test}"
CA_DIR="/etc/lab-tls"
CRT="/etc/pki/tls/certs/$NAME.crt"
KEY="/etc/pki/tls/private/$NAME.key"
ANCHOR="/etc/pki/ca-trust/source/anchors/lab-ca.crt"
CONF="/etc/nginx/conf.d/lab-proxy.conf"

say()  { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
ok()   { printf '  ok    %s\n' "$*"; }
skip() { printf '  --    %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s %s\n' "$0" "${1:-}" >&2; exit 1; }

ALL=no
[[ "${1:-}" == "--all" ]] && ALL=yes

say "nginx"
if [[ -f "$CONF" ]]; then
	rm -f "$CONF"
	ok "removed $CONF"
	if systemctl is-active --quiet nginx; then
		if nginx -t >/dev/null 2>&1; then
			systemctl reload nginx
			ok "reloaded nginx without it"
		else
			systemctl stop nginx
			ok "stopped nginx (the remaining config does not parse)"
		fi
	fi
else
	skip "no $CONF"
fi

say "the backend"
if systemctl list-unit-files lab-app.service >/dev/null 2>&1; then
	systemctl disable --now lab-app.service >/dev/null 2>&1
	rm -f /etc/systemd/system/lab-app.service
	systemctl daemon-reload
	ok "lab-app.service stopped, disabled and removed"
else
	skip "lab-app.service was not installed"
fi
rm -rf /srv/lab-app
ok "removed /srv/lab-app"

say "the ports"
close_port() {
	local p="$1"
	if systemctl is-active --quiet firewalld &&
	   firewall-cmd --permanent --query-port="$p" >/dev/null 2>&1; then
		firewall-cmd --permanent --remove-port="$p" >/dev/null
		firewall-cmd --reload >/dev/null
		ok "closed $p"
	elif command -v firewall-offline-cmd >/dev/null 2>&1 &&
	     firewall-offline-cmd --query-port="$p" >/dev/null 2>&1; then
		firewall-offline-cmd --remove-port="$p" >/dev/null
		ok "closed $p (offline - firewalld is not running)"
	else
		skip "$p was not open"
	fi
}
close_port 80/tcp
close_port 443/tcp

say "the name"
if grep -qE "[[:space:]]$NAME(\$|[[:space:]])" /etc/hosts; then
	sed -i "/[[:space:]]$NAME\$/d" /etc/hosts
	ok "removed $NAME from /etc/hosts"
else
	skip "$NAME was not in /etc/hosts"
fi

say "the payload and the scratch files"
rm -f /usr/local/bin/lab-proxy
rm -rf /tmp/day17-broken
ok "removed /usr/local/bin/lab-proxy and /tmp/day17-broken"

# The SELinux boolean is left on. It is a policy change, it harms nothing, and
# turning it off would break any other httpd_t service on this host.
say "SELinux"
skip "httpd_can_network_connect left on - it is policy, not litter"

if [[ "$ALL" == yes ]]; then
	say "the certificates, the CA, and the trust"
	rm -f "$CRT" "$KEY"
	ok "removed the server certificate and key"
	if [[ -f "$ANCHOR" ]]; then
		rm -f "$ANCHOR"
		command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract
		ok "removed the trust anchor and ran update-ca-trust"
	fi
	rm -rf "$CA_DIR"
	ok "removed $CA_DIR - the CA key is gone with it"
else
	say "kept"
	skip "$CRT and $KEY"
	skip "$CA_DIR and the trust anchor - pass --all to remove them"
fi

printf '\ndone. Day 17 can be rebuilt with:  sudo ./scripts/setup.sh\n'
