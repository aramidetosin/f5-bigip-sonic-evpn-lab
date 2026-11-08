#!/bin/bash
# sonic-walk.sh [vrf] [prefix]: runs ON a Dell SONiC leaf (leaf1a 'bash -s' < sonic-walk.sh). Walks one route through APPL_DB and
# ASIC_DB and prints each object on one line: APPL_DB route > next-hop group; ASIC_DB route entry > next hop > router interface > VLAN;
# the neighbour (APPL_DB NEIGH_TABLE) that gives the next hop its MAC. Part 15. The Redis password stays in REDISCLI_AUTH.
V=${1:-Vrf-App}; P=${2:-10.20.5.10/32}; export REDISCLI_AUTH=$(cat /run/redis/auth/passwd)
A() { redis-cli -p 63792 -n 0 "$@" </dev/null 2>/dev/null; }; S() { redis-cli -p 63793 -n 1 "$@" </dev/null 2>/dev/null; }
g=$(A HGET "ROUTE_TABLE:$V:$P" nexthop_group)
echo "APPL_DB  ROUTE_TABLE:$V:$P            nexthop_group $g"
echo "APPL_DB  NEXT_HOP_GROUP_TABLE:$g              nexthop $(A HGET NEXT_HOP_GROUP_TABLE:$g nexthop)  ifname $(A HGET NEXT_HOP_GROUP_TABLE:$g ifname)"
S KEYS "ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:*\"dest\":\"$P\"*" | while read -r k; do
  nh=$(S HGET "$k" SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID); ip=$(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_NEXT_HOP:$nh" SAI_NEXT_HOP_ATTR_IP)
  case "$ip" in 10.254.5.*|10.254.7.*) ;; *) continue;; esac
  vr=$(echo "$k" | grep -oE 'oid:0x3[0-9a-f]+')
  echo "ASIC_DB  ROUTE_ENTRY dest $P vr $vr  NEXT_HOP_ID $nh"
  rif=$(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_NEXT_HOP:$nh" SAI_NEXT_HOP_ATTR_ROUTER_INTERFACE_ID)
  echo "ASIC_DB  NEXT_HOP $nh               $(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_NEXT_HOP:$nh" SAI_NEXT_HOP_ATTR_TYPE)  IP $ip  RIF $rif"
  vl=$(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_ROUTER_INTERFACE:$rif" SAI_ROUTER_INTERFACE_ATTR_VLAN_ID)
  echo "ASIC_DB  ROUTER_INTERFACE $rif       $(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_ROUTER_INTERFACE:$rif" SAI_ROUTER_INTERFACE_ATTR_TYPE)  VR $(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_ROUTER_INTERFACE:$rif" SAI_ROUTER_INTERFACE_ATTR_VIRTUAL_ROUTER_ID)  MAC $(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_ROUTER_INTERFACE:$rif" SAI_ROUTER_INTERFACE_ATTR_SRC_MAC_ADDRESS)"
  echo "ASIC_DB  VLAN $vl          VLAN_ID $(S HGET "ASIC_STATE:SAI_OBJECT_TYPE_VLAN:$vl" SAI_VLAN_ATTR_VLAN_ID)"
  n=$(S KEYS "ASIC_STATE:SAI_OBJECT_TYPE_NEIGHBOR_ENTRY:*\"ip\":\"$ip\"*" | head -1)
  echo "ASIC_DB  NEIGHBOR_ENTRY ip $ip  rif $(echo "$n" | grep -oE 'oid:0x6[0-9a-f]+')"
  ifn=$(A HGET NEXT_HOP_GROUP_TABLE:$g ifname); echo "APPL_DB  NEIGH_TABLE:$ifn:$ip    neigh $(A HGET "NEIGH_TABLE:$ifn:$ip" neigh)"
done
