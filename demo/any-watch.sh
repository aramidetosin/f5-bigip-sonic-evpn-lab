#!/bin/bash
# any-watch.sh <seconds> [log]: part 20, the anycast VIP any.f5lab.test (10.20.5.200) watched from two places at once:
#   pc1 fetches http://any.f5lab.test/ about four times a second (new connection each time, 1 s timeout) and logs
#     <epoch> F <site A|site B|FAIL> <server>      (the site from the address the server saw: site A's SNAT 10.20.0.240/.241, site B's .242)
#   leaf1a polls its own route table about four times a second for its next hops to 10.20.5.200 and logs (in leaf1a's own clock: the
#   leaves are VMs; any-timeline.sh corrects the offset)
#     <epoch> R <next hops, e.g. A+B, B, none>     (10.254.5.3 = lb-f5a = site A, 10.254.5.4 = lb-f5b = site B)
# Each fetch is also printed live (UTC time), unless QUIET=1. any-timeline.sh merges the log with lb-f5a's LTM log.
D=${1:-60}; L=${2:-/tmp/any-watch.log}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
: > "$L"
ssh $O -n admin@172.21.32.21 "end=\$((\$(date +%s)+$D)); while [ \$(date +%s) -lt \$end ]; do
    r=\$(ip route show vrf Vrf-App 10.20.5.200 | grep -oE '10\\.254\\.5\\.[34]' | sort -u | sed 's/10.254.5.3/A/; s/10.254.5.4/B/' | paste -sd+ -)
    echo \"\$(date +%s.%N | cut -c1-14) R \${r:-none}\"; sleep 0.2; done" >> "$L" 2>/dev/null &
ssh $O -n admin@172.21.32.111 "end=\$((\$(date +%s)+$D)); while [ \$(date +%s) -lt \$end ]; do
  t=\$(date +%s.%N | cut -c1-14); b=\$(curl -s -m 1 http://any.f5lab.test/)
  s=\$(echo \"\$b\" | awk '/client seen/ {split(\$3, a, \":\"); print (a[1] == \"10.20.0.242\") ? \"site_B\" : \"site_A\"}')
  echo \"\$t F \${s:-FAIL} \$(echo \"\$b\" | head -1 | cut -d' ' -f1)\"; sleep 0.15; done" |
  tee -a "$L" | if [ -n "$QUIET" ]; then cat >/dev/null; else
  awk '{ printf "%s  fetch: %-7s %s\n", strftime("%H:%M:%S", int($1), 1) substr($1, 11, 2), $3 == "FAIL" ? "FAIL" : $3, $4; fflush() }' | sed 's/site_/site /'; fi
wait
sort -n -o "$L" "$L"
echo "$(grep -c ' F ' "$L") fetches, $(grep -c ' R ' "$L") route samples in $L"
