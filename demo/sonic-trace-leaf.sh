#!/bin/bash
# sonic-trace-leaf.sh <seconds> <prefix>: runs ON a Dell SONiC leaf. For <seconds>, records every change of <prefix> in the
# kernel (ip -ts monitor route), APPL_DB (MONITOR on instance redis2: what fpmsyncd writes) and ASIC_DB (MONITOR on redis3: what
# orchagent writes for syncd), then prints one line per change, in order: '<epoch on this leaf's clock> <layer> <change>'.
D=$1; P=$2; R=/tmp/trace.$$; export REDISCLI_AUTH=$(cat /run/redis/auth/passwd)
timeout $D ip -ts monitor route 2>/dev/null | grep --line-buffered " ${P%/32} " > $R.k &
timeout $D redis-cli -p 63792 MONITOR 2>/dev/null | grep --line-buffered -E '"(HSET|DEL)" "(ROUTE_TABLE:[^"]*'"$P"'|NEXT_HOP_GROUP_TABLE:[0-9]+)"' > $R.a &
timeout $D redis-cli -p 63793 MONITOR 2>/dev/null | grep --line-buffered -F '"HSET" "ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:' | grep --line-buffered -F "$P" | grep --line-buffered -F SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID > $R.s &
wait
{ while read -r l; do ts=$(echo "$l" | grep -oE '[0-9]{4}-[0-9-]+T[0-9:.]+'); e=$(date -d "${ts/T/ }" +%s.%N)
    v=$(echo "$l" | grep -oE '(nhid [0-9]+ )?via [0-9.]+ dev [A-Za-z0-9]+' | head -1)
    echo "$e kernel     ${v:-$(echo "$l" | grep -oE 'nhid [0-9]+' | head -1) multipath (several next hops)}"; done < $R.k
  awk '{gsub(/"/,""); t=$1; if ($4=="HSET" && $5 ~ /^ROUTE_TABLE/ && $6=="nexthop_group") print t, "APPL_DB    route  > next-hop group " $7;
        else if ($4=="HSET" && $5 ~ /^NEXT_HOP_GROUP_TABLE/ && $6=="nexthop") {split($5,a,":"); print t, "APPL_DB    group " a[2] " = " $7}
        else if ($4=="DEL" && $5 ~ /^NEXT_HOP_GROUP_TABLE/) {split($5,a,":"); print t, "APPL_DB    group " a[2] " deleted"}}' $R.a
  while read -r l; do t=${l%% *}; oid=$(echo "$l" | grep -oE '"oid:0x[0-9a-f]+"$' | tr -d '"')
    k="ASIC_STATE:SAI_OBJECT_TYPE_NEXT_HOP:$oid"; ty=$(redis-cli -p 63793 -n 1 HGET "$k" SAI_NEXT_HOP_ATTR_TYPE </dev/null 2>/dev/null)
    ip=$(redis-cli -p 63793 -n 1 HGET "$k" SAI_NEXT_HOP_ATTR_IP </dev/null 2>/dev/null)
    case "$oid" in oid:0x5*) ty="NEXT_HOP_GROUP";; esac; [ -z "$ty" ] && ty="(removed since)"
    echo "$t ASIC_DB    route  > SAI next hop $oid ${ty#SAI_NEXT_HOP_TYPE_} ${ip}"; done < $R.s
} | sort -n
[ -n "$KEEP" ] && cp $R.k /tmp/k.raw && cp $R.s /tmp/s.raw; rm -f $R.k $R.a $R.s
