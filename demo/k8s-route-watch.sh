#!/bin/bash
# demo/k8s-route-watch.sh [seconds] (part 23): about every 5 s on lb-f5a: is CIS's route to k8s-w2's pod network there, where would the
# BIG-IP send a packet to a pod on k8s-w2, and what does the monitor say about each pod member. Run on the lab server, in lab/demo.
cd "$(dirname "$0")"; ssh() { command ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }; . ./f5fn.sh
P=/f5lab_k8s/Shared/whoami_80_web_k8s_f5lab_test; W2=$(kubectl -n web get pods -o wide --no-headers | awk '$7=="k8s-w2"{print $6; exit}')
END=$(( $(date +%s) + ${1:-50} ))
while [ $(date +%s) -lt $END ]; do
  f5 "echo \"\$(date +%T)  w2 route: \$(tmsh -c 'cd /f5lab_k8s; list net route recursive one-line' | grep -c w2)  $W2 via: \$(ip route get $W2 | head -1 | awk '{print \$3, \$5}')  members: \$(tmsh show ltm pool $P members field-fmt | grep -E 'addr |availability-state' | grep -v 'pool ' | paste - - | awk '{printf \"%s=%s \", \$2, \$4}')\"" 2>/dev/null
  sleep 4
done
