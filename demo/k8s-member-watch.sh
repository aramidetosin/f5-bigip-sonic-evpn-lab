#!/bin/bash
# demo/k8s-member-watch.sh [seconds] (part 23): about once a second, side by side, the Service whoami's READY endpoints in Kubernetes
# (its EndpointSlice) and the members of CIS's pool on lb-f5a. Shows how long the BIG-IP takes to follow a pod change.
# Run on the lab server, in lab/demo.
cd "$(dirname "$0")"; ssh() { command ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }; . ./f5fn.sh
P=/f5lab_k8s/Shared/whoami_80_web_k8s_f5lab_test; END=$(( $(date +%s) + ${1:-40} ))
while [ $(date +%s) -lt $END ]; do
  k=$(kubectl -n web get endpointslices -l kubernetes.io/service-name=whoami \
        -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}' | sort | tr '\n' ' ')
  b=$(f5 "tmsh list ltm pool $P members" 2>/dev/null | grep -oE '10\.244\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')
  printf '%s  k8s ready: %-38s big-ip pool: %s\n' "$(date +%T)" "$k" "$b"
  sleep 0.5
done
