#!/bin/bash
# demo/ai-drain.sh <graceful|force> (part 24): long streams (9 x 200 tokens, about 21 s each) from pc1 through the BIG-IP; 6 s in,
# the pod with the most active streams is deleted: graceful = the normal way (its preStop waits until its streams are done, while
# CIS takes it out of the pool), force = --grace-period=0 --force (killed at once, like a crash). Then the load summary.
# Run on the lab server, in lab/demo.
cd "$(dirname "$0")"; ssh() { command ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }; . ./f5fn.sh
./ai-load.sh 9 200 100 > /tmp/ai-drain.txt & sleep 6
p=$(for x in $(kubectl -n ai get pods --field-selector=status.phase=Running -o name); do echo "$(kubectl -n ai exec $x -- sh -c 'ls /tmp/active | wc -l') $x"; done | sort -rn | head -1)
echo "$(date +%T) deleting ${p#* } (${p%% *} active streams), $1"
if [ "$1" = force ]; then kubectl -n ai delete ${p#* } --grace-period=0 --force 2>&1 | grep -v Warning; else kubectl -n ai delete ${p#* } --wait=false; fi
wait; cat /tmp/ai-drain.txt
