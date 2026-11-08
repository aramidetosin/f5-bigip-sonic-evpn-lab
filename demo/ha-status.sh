#!/bin/bash
# ha-status.sh: one line per BIG-IP: failover status, traffic-group-1 state, and the config sync status (part 13)
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
for u in lb-f5a lb-f5b; do
  ssh $O admin@clab-f5-clos-dc-$u 'f=$(tmsh show cm failover-status | awk "/^Status/ {print \$2}")
    d=$(tmsh list cm device one-line | awk "/self-device true/ {print \$3}")
    t=$(tmsh show cm traffic-group traffic-group-1 field-fmt 2>/dev/null | awk -v d="traffic-group-1:$d" "\$3==d {f=1} f && /failover-state/ {print \$2; exit}")
    s=$(tmsh show cm sync-status | awk "/^Status/ {\$1=\"\"; sub(/^ +/,\"\"); print}")
    printf "%-8s failover %-9s traffic-group-1 %-9s sync: %s\n" '$u' "$f" "${t:--}" "$s"' 2>/dev/null || printf "%-8s no answer\n" $u
done
