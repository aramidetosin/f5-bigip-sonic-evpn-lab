#!/bin/bash
# gslb-watch.sh <seconds> [log]: from the lab server, pc1 samples the wide IP about twice a second for <seconds> (part 19) and logs
#   <epoch> <answer via the resolver> <its TTL> <answer from site B's listener> <curl result>
# "via the resolver" is what pc1 really gets (/etc/resolv.conf > 10.10.0.5, cached for the TTL); "site B's listener" (10.20.5.153) is
# what BIG-IP DNS answers at that moment, uncached; curl fetches http://app.gslb.f5lab.test/ by name, 1 s timeout (server name or FAIL).
# Each sample is also printed live (UTC time, sites by name), unless QUIET=1.
D=${1:-60}; L=${2:-/tmp/gslb-watch.log}; W=${GSLB_WIDEIP:-app.gslb.f5lab.test}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@172.21.32.111 "end=\$((\$(date +%s)+$D)); while [ \$(date +%s) -lt \$end ]; do
  t=\$(date +%s.%N | cut -c1-14)
  r=\$(dig +noall +answer +time=1 +tries=1 $W A | awk '\$4==\"A\" {print \$5, \$2; exit}')
  a=\$(dig +short +time=1 +tries=1 @10.20.5.153 $W A | head -1)
  c=\$(curl -s -m 1 http://$W/ | head -1 | cut -d' ' -f1)
  echo \"\$t \${r:-none -} \${a:-none} \${c:-FAIL}\"; sleep 0.4; done" | tee "$L" |
  if [ -n "$QUIET" ]; then cat >/dev/null; else awk 'function s(a) { return a == "10.20.5.10" ? "site A" : a == "10.20.5.140" ? "site B" : a }
    { printf "%s  resolver: %-6s TTL %-3s  site B listener: %-6s  fetch: %s\n", strftime("%H:%M:%S", int($1), 1) substr($1, 11, 2), s($2), $3, s($4), $5; fflush() }'; fi
echo "$(wc -l < "$L") samples in $L"
