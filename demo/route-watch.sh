#!/bin/bash
# route-watch.sh <seconds> [prefix]: from the lab server, polls leaf1a's Vrf-App route to the prefix (default 10.20.5.10/32) and
# prints a line with the elapsed time (lab server clock) each time the next hop changes, or the route disappears (part 14)
D=${1:-60}; P=${2:-10.20.5.10/32}; O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
t0=$(date +%s.%N); end=$(( $(date +%s)+D )); last=x
while [ $(date +%s) -lt $end ]; do
  v=$(ssh $O admin@172.21.32.21 "vtysh -c 'show ip route vrf Vrf-App $P'" 2>/dev/null | grep -oE '[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+, via [A-Za-z0-9]+' | head -1); v=${v:-no route}
  [ "$v" != "$last" ] && { printf "%5.1f s  leaf1a %s: %s\n" "$(echo "$(date +%s.%N) - $t0" | bc)" "$P" "$v"; last=$v; }
done
true
