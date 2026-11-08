#!/bin/bash
# demo/monitor-watch.sh <server-ip> [samples] [monitor ...]: about once a second, each monitor's verdict on one server as lb-f5a sees it,
# plus the pool member's availability (part 6). The left column is real elapsed seconds. A monitor is "type:name"
# (default: icmp:icmp tcp:tcp http:http http:http-health). One tmsh call per sample, so samples stay close together.
# Run on the lab server. Values: lb-f5a's container name from gen.py; pool-web from
IP=${1:?server ip}; N=${2:-20}; shift 2 2>/dev/null; MONS=${*:-icmp:icmp tcp:tcp http:http http:http-health}
CMDS=""; for m in $MONS; do CMDS="$CMDS show ltm monitor ${m%%:*} ${m#*:};"; done
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@clab-f5-clos-dc-lb-f5a "
t0=\$(date +%s)
for i in \$(seq $N); do
  tmsh -c '$CMDS show ltm pool pool-web members field-fmt' 2>/dev/null | awk -v ip='$IP' -v t=\$((\$(date +%s)-t0)) '
    /LTM::Monitor/ {split(\$2, p, \"/\"); mon=p[3]; order[++n]=mon}
    /Destination:/ {d=(index(\$2, ip \":\")==1)}
    d && /State time:/ {st[mon]=\$3; d=0}
    /^ +addr / {a=(\$2==ip)}
    a && /status.availability-state/ {mem=\$2; a=0}
    END {printf \"%3ss \", t; for (k=1;k<=n;k++) printf \"  %s %-5s\", order[k], (st[order[k]]?st[order[k]]:\"-\"); printf \"   | member %s\n\", mem}'
  sleep 1
done"
