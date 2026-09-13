#!/usr/bin/env bash
#
# Day 17 setup - nginx in front of a plain HTTP service, over TLS.
#
#   sudo ./scripts/setup.sh
#
# Runs on node1 only. Idempotent - run it as often as you like.
#
# What exists afterwards:
#   /srv/lab-app/index.html                     the application, such as it is
#   lab-app.service                             it, on 127.0.0.1:8080, plain HTTP
#   /etc/lab-tls/{ca.crt,ca.key}                Day 10's CA - reused, or issued here
#   /etc/pki/tls/certs/www.lab.test.crt         the server certificate
#   /etc/pki/tls/private/www.lab.test.key       its key, 0600
#   /etc/pki/ca-trust/source/anchors/lab-ca.crt the CA, trusted system-wide
#   /etc/nginx/conf.d/lab-proxy.conf            80 redirects, 443 terminates
#   /etc/hosts                                  www.lab.test -> 127.0.0.1
#   80/tcp, 443/tcp open in firewalld           permanently
#   /usr/local/bin/lab-proxy                    the payload
#
# The shape to keep in your head: TLS stops at nginx. Behind it the traffic is
# ordinary HTTP on the loopback interface, which is exactly how most internal
# services are really exposed.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n\n' "$*"; }
die()  { printf '\nfailed: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 $*"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_SRC="$HERE/lab-proxy.sh"
PAYLOAD="/usr/local/bin/lab-proxy"

NAME="${LAB_SITE:-www.lab.test}"
BACKEND_PORT="${LAB_BACKEND_PORT:-8080}"
APP_DIR="/srv/lab-app"
CA_DIR="/etc/lab-tls"
CRT="/etc/pki/tls/certs/$NAME.crt"
KEY="/etc/pki/tls/private/$NAME.key"
ANCHOR="/etc/pki/ca-trust/source/anchors/lab-ca.crt"
CONF="/etc/nginx/conf.d/lab-proxy.conf"

# ---------------------------------------------------------------------------
# 1. the packages
# ---------------------------------------------------------------------------
say "1. nginx, openssl, and a python to serve the backend"

NEEDED=()
command -v nginx >/dev/null 2>&1 || NEEDED+=(nginx)
command -v openssl >/dev/null 2>&1 || NEEDED+=(openssl)
command -v python3 >/dev/null 2>&1 || NEEDED+=(python3)
# Day 11 installed and started firewalld, on node1, which is this host - but a
# rebuilt VM has neither. A day may use another day's lesson; it may not
# assume another day's packages are still there.
command -v firewall-cmd >/dev/null 2>&1 || NEEDED+=(firewalld)
if [[ ${#NEEDED[@]} -gt 0 ]]; then
	note "installing: ${NEEDED[*]}"
	dnf install -y "${NEEDED[@]}" >/dev/null || die "dnf install failed: ${NEEDED[*]}"
fi
ok "nginx $(nginx -v 2>&1 | sed 's|.*/||')"
ok "$(openssl version)"

# ---------------------------------------------------------------------------
# 2. the application behind the proxy
# ---------------------------------------------------------------------------
# Deliberately trivial, and deliberately plain HTTP on the loopback address.
# The point of a reverse proxy is that the thing behind it does not have to
# know what TLS is - and usually does not.
say "2. the backend, on 127.0.0.1:$BACKEND_PORT"

mkdir -p "$APP_DIR"
cat > "$APP_DIR/index.html" <<'HTML'
<!doctype html>
<title>lab-app</title>
<h1>lab-app</h1>
<p>LAB-BACKEND-OK</p>
<p>Served as plain HTTP on 127.0.0.1. Everything you can see was
decrypted by nginx one hop ago.</p>
HTML
chmod 0644 "$APP_DIR/index.html"
ok "wrote $APP_DIR/index.html"

cat > /etc/systemd/system/lab-app.service <<UNIT
[Unit]
Description=Day 17 backend - plain HTTP on loopback, no TLS of its own
After=network-online.target

[Service]
# --bind 127.0.0.1 is the whole security model of the backend. Bind it to
# 0.0.0.0 and every byte the proxy protects is also available unencrypted on
# port $BACKEND_PORT to anyone who can reach this host.
ExecStart=/usr/bin/python3 -m http.server $BACKEND_PORT --bind 127.0.0.1 --directory $APP_DIR
Restart=on-failure
DynamicUser=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab-app.service >/dev/null 2>&1 ||
	die "lab-app.service did not start:  systemctl status lab-app.service"
systemctl is-active --quiet lab-app.service || die "lab-app.service is not active"
ok "lab-app.service is active and enabled"

if ss -tlnH "sport = :$BACKEND_PORT" | grep -q '127.0.0.1'; then
	ok "listening on 127.0.0.1:$BACKEND_PORT and nowhere else"
else
	note "expected a listener on 127.0.0.1:$BACKEND_PORT - check the unit"
fi

# ---------------------------------------------------------------------------
# 3. the CA
# ---------------------------------------------------------------------------
# Day 10 built this CA on your laptop, in /etc/lab-tls, and never installed it
# anywhere. If it is not on this VM, issue one here with the same commands -
# the day does not depend on Day 10 having been run on this machine.
say "3. the certificate authority"

mkdir -p "$CA_DIR"
chmod 0755 "$CA_DIR"

if [[ -s "$CA_DIR/ca.crt" && -s "$CA_DIR/ca.key" ]]; then
	ok "reusing the CA already in $CA_DIR"
else
	(umask 077 && openssl genrsa -out "$CA_DIR/ca.key" 4096 >/dev/null 2>&1)
	openssl req -x509 -new -key "$CA_DIR/ca.key" -sha256 -days 3650 \
		-subj "/CN=Bash Mastery Lab CA/O=lab" \
		-addext "basicConstraints=critical,CA:TRUE" \
		-addext "keyUsage=critical,keyCertSign,cRLSign" \
		-out "$CA_DIR/ca.crt" >/dev/null 2>&1 ||
		die "could not create the CA certificate"
	ok "issued a new CA in $CA_DIR"
	note "self-signed, which is what an authority is - there is nobody above it"
fi
chmod 0600 "$CA_DIR/ca.key"
chmod 0644 "$CA_DIR/ca.crt"
ok "ca.key is 0600, ca.crt is 0644"

# ---------------------------------------------------------------------------
# 4. the server certificate
# ---------------------------------------------------------------------------
say "4. a certificate for $NAME"

issue_cert() {
	local cn="$1" crt="$2" key="$3" days="${4:-825}"
	local csr ext
	csr="$(mktemp)"
	ext="$(mktemp)"
	# subjectAltName is the field that decides hostname matching. CN has not
	# been consulted by browsers for years, and openssl -verify_hostname
	# ignores it too. A certificate with no SAN matches nothing.
	cat > "$ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$cn
EXT
	(umask 077 && openssl genrsa -out "$key" 2048 >/dev/null 2>&1)
	openssl req -new -key "$key" -subj "/CN=$cn" -out "$csr" >/dev/null 2>&1
	openssl x509 -req -in "$csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
		-CAcreateserial -days "$days" -sha256 -extfile "$ext" -out "$crt" >/dev/null 2>&1
	local rc=$?
	rm -f "$csr" "$ext"
	return $rc
}

if [[ -s "$CRT" ]] &&
   openssl verify -CAfile "$CA_DIR/ca.crt" "$CRT" >/dev/null 2>&1 &&
   openssl x509 -in "$CRT" -noout -checkend 86400 >/dev/null 2>&1 &&
   openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$NAME"; then
	ok "$CRT is signed by this CA, in date, and carries DNS:$NAME"
else
	issue_cert "$NAME" "$CRT" "$KEY" || die "could not issue the certificate for $NAME"
	ok "issued $CRT with subjectAltName DNS:$NAME"
fi
chmod 0644 "$CRT"
chmod 0600 "$KEY"

# Relabel, or SELinux gives nginx permission denied on files that look fine.
# /etc/pki/tls is already labelled cert_t, which is why the certificates live
# there rather than next to the CA.
if command -v restorecon >/dev/null 2>&1; then
	restorecon -F "$CRT" "$KEY" >/dev/null 2>&1 || true
	ok "relabelled: $(ls -Z "$CRT" | awk '{print $1}')"
fi

# The key and the certificate being a pair is not implied by either one being
# valid. Same modulus, same pair.
if [[ "$(openssl x509 -noout -modulus -in "$CRT" | openssl md5)" == \
      "$(openssl rsa -noout -modulus -in "$KEY" 2>/dev/null | openssl md5)" ]]; then
	ok "the certificate and the key are a pair"
else
	die "$CRT and $KEY are not a pair - delete both and run this again"
fi

# ---------------------------------------------------------------------------
# 5. trusting the CA on this host
# ---------------------------------------------------------------------------
# Day 10 stopped short of this on purpose. This is the day that installs a CA
# into a system trust store, which is what makes `curl https://...` work with
# no flags - and what makes the CA key on this VM worth protecting.
say "5. installing the CA into the system trust store"

if command -v update-ca-trust >/dev/null 2>&1; then
	install -m 0644 "$CA_DIR/ca.crt" "$ANCHOR"
	update-ca-trust extract
	ok "installed $ANCHOR and ran update-ca-trust"
	note "this is the RHEL-family path. Debian: /usr/local/share/ca-certificates"
	note "and update-ca-certificates. Firefox, Java and node each keep their own"
	note "store and will still refuse this certificate"
else
	note "no update-ca-trust here - clients will need --cacert $CA_DIR/ca.crt"
fi

# ---------------------------------------------------------------------------
# 6. the name
# ---------------------------------------------------------------------------
say "6. making $NAME resolve"

if grep -qE "[[:space:]]$NAME(\$|[[:space:]])" /etc/hosts; then
	ok "$NAME is already in /etc/hosts"
else
	printf '127.0.0.1 %s\n' "$NAME" >> /etc/hosts
	ok "added '127.0.0.1 $NAME' to /etc/hosts"
fi
note "Day 08's zone serves this name properly. /etc/hosts is the local"
note "shortcut, and it is also why a name can work on one host only"

# ---------------------------------------------------------------------------
# 7. nginx
# ---------------------------------------------------------------------------
say "7. nginx: 80 redirects, 443 terminates"

# HTTP/2 is spelled two different ways, and the wrong one is a hard parse
# error rather than a warning:
#   < 1.25.1   a parameter on the listen line:  listen 443 ssl http2;
#   >= 1.25.1  its own directive:               http2 on;
# Rocky 9 ships nginx 1.20, which wants the first. Ask nginx, do not assume.
NG_VER="$(nginx -v 2>&1 | sed -E 's#.*/([0-9]+\.[0-9]+\.[0-9]+).*#\1#')"
NG_MAJOR="${NG_VER%%.*}"
NG_REST="${NG_VER#*.}"
NG_MINOR="${NG_REST%%.*}"
NG_PATCH="${NG_REST#*.}"
if [[ "$NG_MAJOR" =~ ^[0-9]+$ && "$NG_MINOR" =~ ^[0-9]+$ && "$NG_PATCH" =~ ^[0-9]+$ ]] &&
	{ [ "$NG_MAJOR" -gt 1 ] ||
	  { [ "$NG_MAJOR" -eq 1 ] && [ "$NG_MINOR" -gt 25 ]; } ||
	  { [ "$NG_MAJOR" -eq 1 ] && [ "$NG_MINOR" -eq 25 ] && [ "$NG_PATCH" -ge 1 ]; }; }; then
	LISTEN_443="listen 443 ssl;"
	HTTP2_LINE="    http2 on;"
else
	LISTEN_443="listen 443 ssl http2;"
	HTTP2_LINE="    # on nginx $NG_VER, http2 is the listen parameter above"
fi
note "nginx ${NG_VER:-unknown} - using '$LISTEN_443'"

cat > "$CONF" <<NGINX
# Day 17 - written by setup.sh.
#
# Two servers. The first one exists only to refuse plain HTTP, because a
# service that answers on both is a service that will be used on both.

server {
    listen 80;
    listen [::]:80;
    server_name $NAME;

    # 301 is permanent and gets cached hard. That is the intent here, and it
    # is also why a wrong 301 is so painful to take back.
    return 301 https://\$host\$request_uri;
}

server {
    $LISTEN_443
$HTTP2_LINE
    server_name $NAME;

    # server_name is matched against SNI. A request for a name no server
    # block claims is answered by the default server, with the default
    # server's certificate - which is how you end up debugging a name
    # mismatch on a host whose certificates are all correct.
    ssl_certificate     $CRT;
    ssl_certificate_key $KEY;

    # These are read once, when the worker starts. A renewed certificate on
    # disk changes nothing until nginx is reloaded.
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:1m;
    ssl_session_timeout 10m;

    access_log /var/log/nginx/lab-proxy.access.log;
    error_log  /var/log/nginx/lab-proxy.error.log;

    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;

        # Without these the backend sees a request from 127.0.0.1 for the
        # host '127.0.0.1', and every log line, redirect and absolute URL it
        # generates is wrong. The proxy knows things the backend cannot.
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 5s;
        proxy_read_timeout    30s;
    }
}
NGINX
ok "wrote $CONF"

# nginx -t parses the whole configuration and checks the certificate files are
# readable. It does not tell you whether the running workers use any of it.
nginx -t >/dev/null 2>&1 || {
	nginx -t || true
	die "nginx rejected the configuration - the output above says why"
}
ok "nginx -t accepts it"

systemctl enable nginx >/dev/null 2>&1
if systemctl is-active --quiet nginx; then
	systemctl reload nginx
	ok "reloaded nginx (workers replaced, listeners kept)"
else
	systemctl start nginx || die "nginx did not start:  systemctl status nginx"
	ok "started and enabled nginx"
fi

# ---------------------------------------------------------------------------
# 8. SELinux
# ---------------------------------------------------------------------------
# Day 13 said this day would fight you, and this is the fight: nginx runs as
# httpd_t, and httpd_t is not allowed to open network connections unless a
# boolean says so. The failure is a 502 with 'Permission denied' in nginx's
# error log and a denial in the audit log that nobody thinks to read.
say "8. SELinux, and the one boolean this needs"

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != Disabled ]]; then
	ok "SELinux is $(getenforce)"
	if command -v getsebool >/dev/null 2>&1 &&
	   [[ "$(getsebool httpd_can_network_connect)" == *" on" ]]; then
		ok "httpd_can_network_connect is already on"
	else
		setsebool -P httpd_can_network_connect on
		ok "setsebool -P httpd_can_network_connect on"
		note "-P writes the policy so it survives a reboot. Without -P you get a"
		note "proxy that works until the next boot, which is the worst outcome"
	fi
else
	note "SELinux is disabled here - nothing to do, and one fewer thing learned"
fi

# ---------------------------------------------------------------------------
# 9. the ports
# ---------------------------------------------------------------------------
# Same daemon/offline split as Day 16: firewall-cmd --permanent needs the
# daemon, firewall-offline-cmd edits the same XML without it.
say "9. firewalld: 80 and 443, and not $BACKEND_PORT"

# Get the daemon up FIRST, then ask it. The alternative - writing the policy
# offline and starting firewalld afterwards - is what Day 16 does, and it is
# the right answer only when the daemon cannot be started. Here it can.
if ! command -v firewall-cmd >/dev/null 2>&1; then
	note "no firewalld on this host, and it could not be installed"
	note "nothing will be opened - 443 is reachable only because nothing is"
	note "filtering it, which is not the same as being allowed"
elif systemctl is-active --quiet firewalld; then
	ok "firewalld is running"
elif systemctl enable --now firewalld 2>/tmp/day17-firewalld.err; then
	ok "started and enabled firewalld - a port is only open in a loaded policy"
else
	# Do not swallow this. A daemon that refuses to start has a reason, and
	# hiding it is how the last two runs of this day wasted an evening.
	note "firewalld would not start. systemctl said:"
	sed 's/^/      /' /tmp/day17-firewalld.err 2>/dev/null | head -5
	systemctl status firewalld --no-pager 2>&1 | sed -n '1,6p' | sed 's/^/      /'
	journalctl -u firewalld -n 8 --no-pager 2>&1 | sed 's/^/      /'
	note "falling back to editing the policy offline - the ports will be in"
	note "the permanent policy, but nothing will have loaded it"
fi

# systemctl returns as soon as the unit is started, not as soon as the daemon
# is ANSWERING. firewalld is a python process that builds its whole ruleset
# before it takes requests on D-Bus, so the first firewall-cmd after a start
# can fail with "Could not reach any firewall daemon" on a 1.5 GB VM. Wait for
# it to say it is ready instead of assuming that started means usable.
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
	for _ in $(seq 1 30); do
		[ "$(firewall-cmd --state 2>/dev/null || true)" = "running" ] && break
		sleep 1
	done
	if [ "$(firewall-cmd --state 2>/dev/null || true)" = "running" ]; then
		ok "firewalld is answering"
	else
		note "firewalld is started but not answering yet - using the offline tool"
	fi
fi

open_port() {
	local p="$1" out=""
	if [ "$(firewall-cmd --state 2>/dev/null || true)" = "running" ]; then
		if firewall-cmd --permanent --query-port="$p" >/dev/null 2>&1; then
			ok "$p already in the permanent policy"
			return 0
		fi
		# Do not hide the error and do not let set -e kill the script here:
		# there is a working fallback right below.
		if out="$(firewall-cmd --permanent --add-port="$p" 2>&1)"; then
			firewall-cmd --reload >/dev/null 2>&1 || true
			ok "opened $p permanently and reloaded"
			return 0
		fi
		note "firewall-cmd could not add $p: $out"
	fi
	if command -v firewall-offline-cmd >/dev/null 2>&1; then
		if out="$(firewall-offline-cmd --add-port="$p" 2>&1)"; then
			ok "$p written into the permanent policy with the offline tool"
			firewall-cmd --reload >/dev/null 2>&1 || true
			return 0
		fi
		note "firewall-offline-cmd could not add $p either: $out"
	else
		note "no firewalld here - nothing to open"
	fi
	return 0
}

open_port 80/tcp
open_port 443/tcp

# Assert what was actually asked for, rather than trusting the branch above.
# This is the check verify.sh runs, run here, where the error is still visible.
POLICY="$(firewall-cmd --permanent --list-ports 2>/dev/null ||
	firewall-offline-cmd --list-ports 2>/dev/null || true)"
for p in 80/tcp 443/tcp; do
	case " $POLICY " in
	*" $p "*) ok "$p is in the permanent policy: $POLICY" ;;
	*) note "$p is NOT in the permanent policy (it reads: ${POLICY:-empty})" ;;
	esac
done
note "$BACKEND_PORT stays closed. It does not need to be open - the proxy"
note "reaches it over the loopback interface, which no firewall zone sees"

# ---------------------------------------------------------------------------
# 10. the payload
# ---------------------------------------------------------------------------
say "10. installing $PAYLOAD"

[[ -f "$PAYLOAD_SRC" ]] || die "cannot find $PAYLOAD_SRC"
install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
ok "$PAYLOAD installed"

# ---------------------------------------------------------------------------
# 11. proving it
# ---------------------------------------------------------------------------
say "11. proving it"

sleep 1
if curl -sS -o /dev/null -w '%{http_code}' "https://$NAME/" 2>/dev/null | grep -q '^200$'; then
	ok "https://$NAME/ returns 200 with the system trust store alone"
else
	note "https://$NAME/ did not return 200. Look at:"
	note "  curl -v https://$NAME/"
	note "  sudo tail /var/log/nginx/lab-proxy.error.log"
	note "  sudo ausearch -m avc -ts recent"
	die "the proxy is not serving yet"
fi

if curl -sS "https://$NAME/" | grep -q 'LAB-BACKEND-OK'; then
	ok "the body came from the backend, so the proxy hop works"
fi

REDIR="$(curl -sS -o /dev/null -w '%{http_code}' "http://$NAME/" || true)"
if [[ "$REDIR" == 301 ]]; then
	ok "http://$NAME/ answers 301 to https"
fi

cat <<TXT

=== Day 17 is set up on $(hostname -s) ===

  site      https://$NAME/    (nginx, TLS terminated here)
  backend   127.0.0.1:$BACKEND_PORT     (plain HTTP, loopback only)
  cert      $CRT
  CA        $CA_DIR/ca.crt, trusted system-wide

Look at it:

  sudo lab-proxy                     the whole path, end to end
  sudo lab-proxy certs               what the certificate actually claims
  sudo lab-proxy test                a verified handshake and a real request
  sudo lab-proxy logs                both logs, proxy and backend

Then the tour:  sudo ./days/day17/scripts/explore-proxy.sh
And break it:   sudo ./days/day17/scripts/break-and-fix.sh
                sudo ./days/day17/scripts/break-and-fix.sh --hard

Check yourself: sudo ./days/day17/verify.sh

Worth doing before verify: curl the backend directly on 127.0.0.1:$BACKEND_PORT
and notice there is no TLS there at all. That is the hop you are trusting.
TXT
