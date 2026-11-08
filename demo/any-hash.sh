#!/bin/bash
# any-hash.sh [leaf] [sources...]: part 20, asks a leaf (default leaf1a) which next hop its kernel would choose for 10.20.5.200 for
# traffic arriving from the firewall (Vlan3002) from each source address (default: pc1-3 and 10.10.0.21-28). With an L3-only hash
# the choice depends on the source and destination addresses alone.
L=${1:-leaf1a}; shift; S=${*:-10.10.0.11 10.10.0.12 10.10.0.13 10.10.0.21 10.10.0.22 10.10.0.23 10.10.0.24 10.10.0.25 10.10.0.26 10.10.0.27 10.10.0.28}
case $L in leaf1a) A=172.21.32.21;; leaf1b) A=172.21.32.22;; *) echo "leaf1a or leaf1b"; exit 1;; esac
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@$A "for s in $S; do printf '%s ' \$s; sudo ip route get 10.20.5.200 from \$s iif Vlan3002 vrf Vrf-App | head -1; done" |
  awk -v l="$L" '{nh = $6; s = (nh ~ /\.3$/) ? "site A (lb-f5a)" : (nh ~ /\.4$/) ? "site B (lb-f5b)" : nh; printf "%s: from %-11s > via %-11s %s\n", l, $1, nh, s}'
