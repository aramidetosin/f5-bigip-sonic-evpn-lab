#!/bin/bash
# demo/slow.sh <server1|server2|server3> [delay|off]: add (or remove) a network delay on one server's bond0 with tc netem, so its
# transfers take longer and its connections stay open (part 5: least connections, fastest). Default delay 100ms. Run on the lab server.
S=clab-f5-clos-dc-${1:?server}; D=${2:-100ms}
if [ "$D" = off ]; then docker exec $S tc qdisc del dev bond0 root 2>/dev/null; else docker exec $S tc qdisc replace dev bond0 root netem delay $D; fi
docker exec $S tc qdisc show dev bond0
