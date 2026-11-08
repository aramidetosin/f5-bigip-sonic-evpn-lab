#!/bin/bash
# sonic-layers.sh <seconds> [vrf] [prefix]: runs ON a Dell SONiC leaf (the caller copies it to /tmp). Polls one route at four layers in
# a loop and prints a line, with the time since start on the leaf's own clock, whenever any layer's next hop changes (part 15):
#   frr    FRR's RIB (vtysh): the selected next hop          kern   the kernel's VRF table: what the VS dataplane forwards with
#   appl   APPL_DB (instance redis2, db 0): ROUTE_TABLE > nexthop_group > NEXT_HOP_GROUP_TABLE nexthop   (written by fpmsyncd)
#   asic   ASIC_DB (instance redis3, db 1): SAI ROUTE_ENTRY > NEXT_HOP_ID > SAI_NEXT_HOP_ATTR_IP          (written by orchagent)
# The Redis password is read from /run/redis/auth/passwd into REDISCLI_AUTH, never printed.
D=${1:-30}; V=${2:-Vrf-App}; P=${3:-10.20.5.10/32}
export REDISCLI_AUTH=$(cat /run/redis/auth/passwd)
A() { redis-cli -p 63792 -n 0 "$@" 2>/dev/null; }      # APPL_DB
S() { redis-cli -p 63793 -n 1 "$@" 2>/dev/null; }      # ASIC_DB
now() { date +%s.%N; }
t0=$(now); end=$(( $(date +%s)+D )); last=""; key=""
asickey() {   # the ASIC route entry for this prefix in the BIG-IP VRF: the one whose next hop is a BIG-IP transit address
  S KEYS "ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*\"dest\":\"$P\"*" | while read -r k; do
    ip=$(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_NEXT_HOP:$(S HGET "$k" SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID)" SAI_NEXT_HOP_ATTR_IP)
    case "$ip" in 10.254.5.*|10.254.7.*) echo "$k"; break;; esac; done; }
while [ $(date +%s) -lt $end ]; do
  frr=$(vtysh -c "show ip route vrf $V $P json" 2>/dev/null | grep -oE '"ip":"[0-9.]+"' | head -1 | cut -d'"' -f4)
  kern=$(ip route show vrf $V ${P%/32} 2>/dev/null | grep -oE 'via [0-9.]+' | head -1 | cut -d' ' -f2)
  g=$(A HGET "ROUTE_TABLE:$V:$P" nexthop_group); appl=$( [ -n "$g" ] && A HGET "NEXT_HOP_GROUP_TABLE:$g" nexthop)
  [ -z "$key" ] && key=$(asickey)
  nh=$( [ -n "$key" ] && S HGET "$key" SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID)
  asic=$( [ -n "$nh" ] && S HGET "ASIC_STATE:SAI_OBJECT_TYPE_NEXT_HOP:$nh" SAI_NEXT_HOP_ATTR_IP)
  [ -z "$nh" ] && key=""
  cur="frr ${frr:--}   kern ${kern:--}   appl ${appl:--} (group ${g:--})   asic ${asic:--}"
  [ "$cur" != "$last" ] && { awk -v a=$(now) -v b=$t0 -v c="$cur" 'BEGIN {printf "%6.2f s  %s\n", a-b, c}'; last=$cur; }
done
true
