#!/bin/bash
# demo/k8s-errors.sh [url] (part 23): what a client sees while a pod goes away. pc1 sends 150 requests to the url, one every 0.1 s
# (about 20 s); 3 s in, one whoami pod is deleted. Prints how many answers had each HTTP code (000 = no answer: reset or timeout).
# Run on the lab server, in lab/demo.
cd "$(dirname "$0")"; ssh() { command ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }; . ./f5fn.sh; U=${1:-http://k8s.f5lab.test/}
pc1 "for i in \$(seq 150); do curl -s -m 2 -o /dev/null -w '%{http_code}\n' $U; sleep 0.1; done" > /tmp/k8s-errors.txt &
sleep 3; p=$(kubectl -n web get pods -o name | head -1); echo "$(date +%T) deleting $p"; kubectl -n web delete $p --wait=false >/dev/null
wait; echo "answers by HTTP code:"; sort /tmp/k8s-errors.txt | uniq -c
