#!/bin/bash
# gslb-dig.sh <pc> <server> [n] [name]: from pc1-3, n queries (default 20) for the wide IP straight to a DNS server (a BIG-IP DNS
# listener, or the resolver), counted per answer (part 18): which site, how often.
P=${1:?pc}; S=${2:?server}; N=${3:-20}; Q=${4:-app.gslb.f5lab.test}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@172.21.32.$((110 + ${P#pc})) "for i in \$(seq $N); do dig +short +time=2 +tries=1 @$S $Q; done | sort | uniq -c" |
  awk -v p="$P" -v s="$S" -v n="$N" '{a = $2; site = (a == "10.20.5.10") ? "site A" : (a == "10.20.5.140") ? "site B" : "?"; printf "%s > %s: %3d of %d  %s  (%s)\n", p, s, $1, n, a, site}'
