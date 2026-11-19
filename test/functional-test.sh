#!/usr/bin/env bash
# Run the ARMv5 pihole-FTL under qemu-arm with an ARM926EJ-S (ARMv5TEJ) CPU
# model and check that it actually works: DNS (local record, exact and regex
# blocking), the embedded sqlite3 shell, and the HTTP + HTTPS (mbedTLS) API.
#
# Usage: sudo test/functional-test.sh <pihole-FTL-armv5> [core-checkout]
# Needs: qemu-user, dnsutils (dig), curl. Writes to /etc/pihole - run it on a
# throwaway machine or CI runner, not on your Pi-hole.
set -euo pipefail
BIN="$(realpath "${1:?usage: $0 <pihole-FTL-armv5> [pi-hole core checkout]}")"
CORE="${2:-}"
FTL=(qemu-arm -cpu arm926 "$BIN")
fail() { echo "FAIL: $*" >&2; tail -n 30 /var/log/pihole/FTL.log >&2 || true; exit 1; }

id pihole >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin pihole
mkdir -p /etc/pihole /var/log/pihole /var/www/html/admin
chown -R pihole:pihole /etc/pihole /var/log/pihole

cfg() { "${FTL[@]}" --config "$1" "$2" >/dev/null; }
cfg dns.port 5335
cfg dns.upstreams '["127.0.0.1#5399"]'
cfg dns.hosts '["10.9.8.7 pogotest.lan"]'
cfg webserver.port '8080,8443s'
cfg dhcp.active false
cfg ntp.ipv4.active false
cfg ntp.ipv6.active false
cfg ntp.sync.active false

# Gravity database, created with FTL's own embedded sqlite3
schema="${CORE:+$CORE/advanced/Templates/gravity.db.sql}"
if [[ -z "$schema" || ! -f "$schema" ]]; then
  schema="$(mktemp)"
  curl -fsSL -o "$schema" https://raw.githubusercontent.com/pi-hole/pi-hole/master/advanced/Templates/gravity.db.sql
fi
rm -f /etc/pihole/gravity.db
"${FTL[@]}" sqlite3 /etc/pihole/gravity.db < "$schema"
"${FTL[@]}" sqlite3 /etc/pihole/gravity.db \
  "INSERT INTO domainlist (type,domain,enabled) VALUES (1,'ads.example.com',1),(3,'(^|\.)tracker\.',1);"
chown pihole:pihole /etc/pihole/gravity.db

"${FTL[@]}" no-daemon >/tmp/ftl-functional.out 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

# FTL is slow to start under emulation; wait for the API
for _ in $(seq 1 120); do
  curl -fs http://127.0.0.1:8080/api/info/login >/dev/null 2>&1 && break
  kill -0 $pid 2>/dev/null || fail "FTL exited early: $(cat /tmp/ftl-functional.out)"
  sleep 1
done

q() { # name expected  (retry: the first regex query compiles regexes under emulation)
  local got=""
  for _ in 1 2 3 4 5; do
    got="$(dig +short +time=5 +tries=1 @127.0.0.1 -p 5335 "$1" A 2>/dev/null | tail -n1)"
    [[ "$got" == "$2" ]] && { echo "ok   $1 -> $got"; return; }
    sleep 2
  done
  fail "$1 resolved to '$got', expected '$2'"
}
q pogotest.lan    10.9.8.7
q ads.example.com 0.0.0.0
q a.tracker.net   0.0.0.0

curl -fs  http://127.0.0.1:8080/api/info/login | grep -q '"dns":true' || fail "HTTP API"
echo "ok   HTTP API"
curl -fsk https://127.0.0.1:8443/api/info/login | grep -q '"dns":true' || fail "HTTPS API (mbedTLS)"
echo "ok   HTTPS API"
curl -fs http://127.0.0.1:8080/api/stats/summary | grep -q '"blocked":[1-9]' || fail "stats"
echo "ok   query statistics"
echo "All functional tests passed."
