#!/bin/bash
# demo/pool-watch.sh [samples] [pool]: once a second, the open server-side connections per member of a pool on lb-f5a (part 5).
# Run on the lab server. Values: lb-f5a's container name from gen.py; the pool from
N=${1:-12}; POOL=${2:-pool-web}
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@clab-f5-clos-dc-lb-f5a "
for i in \$(seq $N); do
  tmsh show ltm pool $POOL members field-fmt | awk -v t=\$i '/^ +addr /{a=\$2} /^        +serverside.cur-conns/{c[a]=\$2}
    END{printf \"%3ss   server1 %3s   server2 %3s   server3 %3s   open connections\n\", t, c[\"10.20.0.11\"], c[\"10.20.0.12\"], c[\"10.20.0.13\"]}'
  sleep 1
done"
