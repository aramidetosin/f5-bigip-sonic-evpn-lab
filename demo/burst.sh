#!/bin/bash
# demo/burst.sh [count] [gap] [path]: from pc1, start <count> downloads of http://app.f5lab.test<path>, one every <gap> seconds,
# each in the background (long transfers hold connections open), then wait for all of them (part 5). Run on the lab server.
C=${1:-30}; G=${2:-0.25}; P=${3:-/static/large.bin}
ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@172.21.32.111 \
  "for i in \$(seq $C); do curl -s -o /dev/null http://app.f5lab.test$P & sleep $G; done; wait"
