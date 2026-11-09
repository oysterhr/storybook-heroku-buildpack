#!/usr/bin/env bash
# VPN gate test matrix (FLOW-1713).
# Usage: scripts/test-matrix.sh <hostname> [on|off]
#   on  = you are connected to the Perimeter 81 VPN
#   off = you are NOT on the VPN
# Run it once in each mode.
set -u
HOST="${1:?usage: $0 <hostname> on|off}"; MODE="${2:?usage: $0 <hostname> on|off}"
URL="https://$HOST/"; SPOOF="95.179.220.118"; fail=0
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@" "$URL"; }
check() { local name="$1" want="$2" got="$3"
  if [[ "$got" =~ ^($want)$ ]]; then echo "PASS  $name -> $got"; else echo "FAIL  $name -> $got (want $want)"; fail=1; fi; }

echo "egress IP: $(curl -s --max-time 10 https://ifconfig.me || echo unknown)"
if [ "$MODE" = on ]; then
  check "on-VPN plain GET (Basic auth in front)" "401|200" "$(code)"
  # Catches an over-broad set_real_ip_from: if the client itself were treated as
  # a trusted proxy, a spoofed XFF would change the resolved IP. It must not.
  check "on-VPN spoofed XFF ignored (still served)" "401|200" "$(code -H "X-Forwarded-For: 203.0.113.7")"
else
  check "off-VPN plain GET" "403" "$(code)"
  check "off-VPN spoofed leftmost XFF ($SPOOF)" "403" "$(code -H "X-Forwarded-For: $SPOOF")"
  check "off-VPN spoofed XFF + bogus Basic auth" "403" "$(code -u x:y -H "X-Forwarded-For: $SPOOF")"
  body=$(curl -s --max-time 15 "$URL"); grep -q "VPN required" <<<"$body" && echo "PASS  403 body is the VPN page" || { echo "FAIL  403 body is not the VPN page"; fail=1; }
fi
cat <<MSG

Verify realip (required before trusting 10.0.0.0/8):
  heroku logs -a <app> --tail | grep router_peer=
  - every router_peer= value must be inside 10.0.0.0/8
  - client_ip= must equal the egress IP printed above, NOT $SPOOF
MSG
exit $fail
