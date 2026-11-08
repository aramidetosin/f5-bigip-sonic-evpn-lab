#!/bin/bash
# demo/pool-count.sh [pool]: per member of a pool on lb-f5a, the server-side connections since the last reset-stats (total) and the
# most open at once (peak) (part 5). Run on the lab server. Values: lb-f5a's container name from gen.py.
POOL=${1:-pool-web}
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@clab-f5-clos-dc-lb-f5a \
  "tmsh show ltm pool $POOL members field-fmt" | awk '/^ +addr /{a=$2} /^        +serverside.tot-conns/{t[a]=$2} /^        +serverside.max-conns/{m[a]=$2}
  END{n["10.20.0.11"]="server1"; n["10.20.0.12"]="server2"; n["10.20.0.13"]="server3"
      for (k in n) printf "%s  %-11s  total %3s   peak open %3s\n", n[k], k, t[k], m[k]}' | sort
