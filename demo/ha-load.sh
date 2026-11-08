#!/bin/bash
# ha-load.sh <seconds> [log]: from the lab server, pc1 asks $URL (default http://app.f5lab.test/) five times a second (1 s timeout) for <seconds> and
# logs "<epoch> <server or FAIL>" per request (part 13); then prints the failures and the longest gap with no answer.
D=${1:-30}; L=${2:-/tmp/ha-load.log}; URL=${URL:-http://app.f5lab.test/}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@172.21.32.111 "end=\$((\$(date +%s)+$D)); while [ \$(date +%s) -lt \$end ]; do t=\$(date +%s.%N | cut -c1-14); r=\$(curl -s -m 1 $URL | head -1 | cut -d' ' -f1); echo \"\$t \${r:-FAIL}\"; sleep 0.2; done" > $L
awk '{n++; if ($2=="FAIL") {f++; if (!s) s=$1; e=$1}; c[$2]++} END {printf "%d requests, %d failed", n, f; if (f) printf ", first failure %.1f s in, last %.1f s in (%.1f s without an answer)", s-t0, e-t0, e-s+0.2; printf "\n"; for (k in c) printf "  %s %d\n", k, c[k]} NR==1 {t0=$1}' $L
