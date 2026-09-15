#!/usr/bin/env bash
#
# lab-ids - read-only window onto today's two sensors.
#
#   lab-ids status    both daemons, the interface, the rules, the counts
#   lab-ids alerts    the last alerts out of eve.json, readably
#   lab-ids audit     what auditd recorded, by key
#   lab-ids watch     follow alerts live until you press Ctrl-C
#   lab-ids prove     trigger, then wait for the alert and time it
#   lab-ids trigger   fire both sensors on purpose
#
# Installed by setup.sh as /usr/local/bin/lab-ids.

set -uo pipefail

EVE="/var/log/suricata/eve.json"
SURILOG="/var/log/suricata/suricata.log"
YAML="/etc/suricata/suricata.yaml"
LAB_RULES="/etc/suricata/rules/lab.rules"
CANARY="/etc/lab-canary"

hdr()  { printf '\n== %s\n\n' "$*"; }
line() { printf '  %s\n' "$*"; }

need_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		printf 'needs root: sudo lab-ids %s\n' "${1:-}" >&2
		exit 1
	fi
}

capture_iface() {
	awk '/^af-packet:/{f=1} f && /^[[:space:]]*-?[[:space:]]*interface:/{print $NF; exit}' "$YAML" 2>/dev/null
}

cmd_status() {
	need_root status

	hdr "daemons"
	line "suricata: $(systemctl is-active suricata 2>/dev/null), $(systemctl is-enabled suricata 2>/dev/null)"
	line "auditd:   $(systemctl is-active auditd 2>/dev/null), $(systemctl is-enabled auditd 2>/dev/null)"

	hdr "is the detection engine actually up"
	# 'active' only means the process exists. Until this line appears,
	# Suricata has not looked at a single packet.
	if grep -q 'Engine started' "$SURILOG" 2>/dev/null; then
		line "engine started: yes"
	else
		line "engine started: NO - still building the detection engine, or it failed"
		tail -5 "$SURILOG" 2>/dev/null | sed 's/^/    /'
	fi
	line "rules loaded:   $(grep -o '[0-9]* rules successfully loaded' "$SURILOG" 2>/dev/null | tail -1)"

	hdr "where suricata is listening"
	IF="$(capture_iface)"
	REAL="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
	line "af-packet interface: ${IF:-unset}"
	line "default route uses:  ${REAL:-none}"
	if [[ -n "$IF" && -n "$REAL" && "$IF" != "$REAL" ]]; then
		line "MISMATCH - suricata is watching a quiet interface. It will look"
		line "           perfectly healthy and alert on nothing."
	fi

	hdr "your rules"
	if [[ -f "$LAB_RULES" ]]; then
		grep -o 'sid:[0-9]*' "$LAB_RULES" | while read -r s; do line "$s"; done
	else
		line "no $LAB_RULES"
	fi
	line "referenced by suricata.yaml: $(grep -qF "$LAB_RULES" "$YAML" 2>/dev/null && echo yes || echo NO)"

	hdr "alert counts in eve.json"
	if [[ -s "$EVE" ]]; then
		line "events total:  $(grep -c . "$EVE")"
		line "alerts total:  $(grep -c '"event_type":"alert"' "$EVE")"
		line "sid 9000001:   $(grep -c '"signature_id":9000001' "$EVE")"
		line "sid 9000002:   $(grep -c '"signature_id":9000002' "$EVE")"
	else
		line "no events written yet"
	fi

	hdr "audit rules in the kernel"
	auditctl -l 2>/dev/null | sed 's/^/  /' || line "auditctl unavailable"
	line ""
	line "file vs kernel: $(augenrules --check 2>/dev/null | tail -1)"
}

cmd_alerts() {
	need_root alerts
	[[ -s "$EVE" ]] || { line "no $EVE yet"; return 0; }

	hdr "last 15 alerts"
	jq -r 'select(.event_type=="alert")
	       | "\(.timestamp[0:19])  sid \(.alert.signature_id)  \(.src_ip) -> \(.dest_ip)  \(.alert.signature)"' \
		"$EVE" 2>/dev/null | tail -15 | sed 's/^/  /'

	hdr "alerts grouped by signature"
	jq -r 'select(.event_type=="alert") | .alert.signature' "$EVE" 2>/dev/null |
		sort | uniq -c | sort -rn | sed 's/^/  /'

	hdr "one alert in full"
	jq -r 'select(.event_type=="alert")' "$EVE" 2>/dev/null | tail -40 | sed 's/^/  /'
}

cmd_audit() {
	need_root audit

	for k in shadow_watch sudoers_watch lab_canary root_cmd; do
		hdr "key $k"
		N="$(ausearch -k "$k" 2>/dev/null | grep -c 'type=SYSCALL')"
		line "syscall records: ${N:-0}"
		ausearch -k "$k" -i 2>/dev/null | tail -6 | sed 's/^/  /'
	done

	hdr "summary report"
	aureport --summary -i 2>/dev/null | sed -n '1,20p' | sed 's/^/  /'
}

alert_count() { grep -c '"event_type":"alert"' "$EVE" 2>/dev/null || echo 0; }

fmt_alerts() {
	jq -c '{time: .timestamp, sid: .alert.signature_id, msg: .alert.signature, src: .src_ip, dst: .dest_ip}' 2>/dev/null
}

cmd_watch() {
	need_root watch

	hdr "the last few alerts already in $EVE"
	grep '"event_type":"alert"' "$EVE" 2>/dev/null | tail -3 | fmt_alerts | sed 's/^/  /'

	hdr "now following $EVE - press Ctrl-C to stop"
	line "Run 'sudo lab-ids trigger' in a SECOND ssh session."
	line "Be patient. Suricata writes eve.json on an interval, so an alert can"
	line "take tens of seconds to show up. Silence here is normal, not broken -"
	line "a heartbeat prints every 15s so you can tell the two apart."
	line "One session, no coordination, no guessing:  sudo lab-ids prove"
	printf '\n'

	# A heartbeat, so an empty screen is never ambiguous. Killed on exit.
	( S=0; while sleep 15; do S=$((S + 15)); printf '  ... still watching, %ss, no new alert yet\n' "$S"; done ) &
	HB=$!
	trap 'kill $HB 2>/dev/null' EXIT INT TERM

	# --line-buffered matters: without it grep holds output in a 4 KB buffer
	# and the alerts you are waiting for arrive in silent bursts.
	tail -n 0 -F "$EVE" 2>/dev/null |
		grep --line-buffered '"event_type":"alert"' |
		jq -c --unbuffered '{time: .timestamp, sid: .alert.signature_id, msg: .alert.signature, src: .src_ip, dst: .dest_ip}' 2>/dev/null
}

cmd_prove() {
	need_root prove

	# The two-session demo only works if you wait long enough, and "long
	# enough" is not knowable in advance. This waits for you, in one session,
	# and reports how long it actually took.
	BEFORE="$(alert_count)"
	hdr "alerts in $EVE right now: $BEFORE"

	line "firing both sensors"
	cmd_trigger >/dev/null 2>&1

	hdr "waiting for a new alert to be written"
	for i in $(seq 1 30); do
		NOW="$(alert_count)"
		if [[ "${NOW:-0}" -gt "${BEFORE:-0}" ]]; then
			line "a new alert appeared after about $((i * 3))s:"
			grep '"event_type":"alert"' "$EVE" 2>/dev/null | tail -1 | fmt_alerts | sed 's/^/    /'
			printf '\n'
			line "That delay is the flush interval. Every dashboard, ticket and"
			line "page ever built on top of an IDS inherits it."
			return 0
		fi
		[[ $((i % 5)) -eq 0 ]] && line "nothing yet after $((i * 3))s - suricata has not flushed"
		sleep 3
	done

	line "no new alert in 90s. Look at the sensor itself: sudo lab-ids status"
	return 1
}

cmd_trigger() {
	need_root trigger
	GW="$(ip route show default | awk '/default/ {print $3; exit}')"

	hdr "network: three pings to $GW, and one canary lookup"
	ping -c 3 -W 2 "$GW" >/dev/null 2>&1 || line "no replies - the packets still left the host"
	dig +time=2 +tries=1 "@$GW" lab-canary.lab.test >/dev/null 2>&1 || true
	line "done - suricata flushes eve.json within a few seconds"

	hdr "disk: one read of /etc/shadow, one read and write of $CANARY"
	# /etc/shadow is watched -p wa, so the read below records nothing. The
	# canary is watched -p rwa, so both of its accesses land in the log.
	cat /etc/shadow >/dev/null 2>&1 || true
	cat "$CANARY" >/dev/null 2>&1 || true
	printf 'triggered %s\n' "$(date -Is)" >>"$CANARY" 2>/dev/null || true
	line "done - find them with: lab-ids audit"
}

case "${1:-status}" in
	status)  cmd_status ;;
	alerts)  cmd_alerts ;;
	audit)   cmd_audit ;;
	watch)   cmd_watch ;;
	prove)   cmd_prove ;;
	trigger) cmd_trigger ;;
	*) printf 'usage: lab-ids [status|alerts|audit|watch|prove|trigger]\n' >&2; exit 2 ;;
esac
