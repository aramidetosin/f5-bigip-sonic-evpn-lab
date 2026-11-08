#!/bin/bash
# any-count.sh <pc> [n]: part 20, pc1-3 fetch http://any.f5lab.test/ n times (default 10), each a new connection, counted by the site
# that answered (from the SNAT address the server saw: site B = 10.20.0.242, site A otherwise).
P=${1:?pc}; N=${2:-10}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@172.21.32.$((110 + ${P#pc})) "for i in \$(seq $N); do curl -s -m 2 http://any.f5lab.test/ | awk '/client seen/ {split(\$3, a, \":\"); print (a[1] == \"10.20.0.242\") ? \"B\" : \"A\"}'; done" |
  awk -v p="$P" -v n="$N" '{c[$1]++} END {printf "%s: %d fetches, site A %d, site B %d, failed %d\n", p, n, c["A"], c["B"], n - c["A"] - c["B"]}'
