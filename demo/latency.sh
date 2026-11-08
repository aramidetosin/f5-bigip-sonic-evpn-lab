#!/bin/bash
# latency.sh <url> [n]: from the lab server, pc1 fetches <url> n times (default 300) one after another, and prints the median, 95th
# percentile and max of curl's time_starttransfer (request sent > first byte of the answer back) in milliseconds (part 16: what the
# WAF adds to a request). New connection per request, so the TCP handshake is in every sample.
U=${1:?url}; N=${2:-300}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@172.21.32.111 "for i in \$(seq $N); do curl -sk -o /dev/null -m 2 -w '%{time_starttransfer}\n' '$U'; done" |
  awk '{print $1 * 1000}' | sort -n | awk -v u="$U" '{a[NR]=$1} END {printf "%s: %d requests, median %.2f ms, p95 %.2f ms, max %.2f ms\n", u, NR, a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'
