#!/bin/bash
# demo/ai-watch.sh [seconds] (part 24): about once a second, the open server-side connections (= active streams) on each pod member of
# the AI pool on lb-f5a, and the pool's total. Run on the lab server, in lab/demo.
cd "$(dirname "$0")"; ssh() { command ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }; . ./f5fn.sh
f5 "N=${1:-15} bash -s" 2>/dev/null <<'R'
for i in $(seq $N); do
  tmsh show ltm pool /f5lab_ai/ai/llm_pool members field-fmt | awk -v t=$(date +%T) '
    /^ +addr /{a=$2} /^ +serverside.cur-conns/{if (a) {c[a]=$2; n+=$2; a=""}}
    END{printf "%s  ", t; for (k in c) printf "%s=%s  ", k, c[k]; printf "| open streams %d\n", n}'
  sleep 1
done
R
