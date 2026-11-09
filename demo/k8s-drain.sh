#!/bin/bash
# demo/k8s-drain.sh (part 23): a whole node taken out for maintenance while a client is busy. pc1 sends 300 HTTPS requests, one every
# 0.1 s; 3 s in, k8s-w2 is drained (its pods evicted, each with its graceful exit). Prints the answers by HTTP code and where the pods
# ended up, then makes k8s-w2 schedulable again. Run on the lab server, in lab/demo.
cd "$(dirname "$0")"; ssh() { command ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }; . ./f5fn.sh
pc1 "for i in \$(seq 300); do curl -s -m 2 -o /dev/null -w '%{http_code}\n' https://k8s.f5lab.test/; sleep 0.1; done" > /tmp/k8s-drain.txt &
sleep 3; echo "$(date +%T) draining k8s-w2"; kubectl drain k8s-w2 --ignore-daemonsets --delete-emptydir-data 2>&1 | grep -E 'evicted|drained'
echo "$(date +%T) done"; wait; echo "answers by HTTP code:"; sort /tmp/k8s-drain.txt | uniq -c
kubectl -n web get pods -o wide --no-headers | awk '{print $1, $6, $7}'; kubectl uncordon k8s-w2
