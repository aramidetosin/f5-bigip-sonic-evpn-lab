#!/bin/bash
# sonic-trace.sh <leaf-ip> <unit-to-fail> [seconds] [prefix]: from the lab server. Measures the leaf's clock offset, starts
# sonic-trace-leaf.sh on the leaf, runs `run sys failover standby` on <unit-to-fail> 5 s in, and prints the leaf's kernel / APPL_DB /
# ASIC_DB events for the prefix in ms after the failover command (both clocks aligned by the measured offset). Part 15.
L=$1; U=$2; D=${3:-25}; P=${4:-10.20.5.10/32}; O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
cd "$(dirname "$0")"; scp $O -q sonic-trace-leaf.sh admin@$L:/tmp/
a=$(date +%s.%N); l=$(ssh $O admin@$L 'date +%s.%N'); b=$(date +%s.%N)
off=$(awk -v a=$a -v b=$b -v l=$l 'BEGIN {printf "%.3f", l-(a+b)/2}')
echo "leaf $L clock offset ${off} s (leaf minus lab server; ssh round trip $(awk -v a=$a -v b=$b 'BEGIN {printf "%.0f", (b-a)*1000}') ms)"
ssh $O admin@$L "KEEP=$KEEP bash /tmp/sonic-trace-leaf.sh $D $P" > /tmp/sonic-trace.raw &
sleep 5; t=$(date +%s.%N); ssh $O admin@clab-f5-clos-dc-$U "tmsh run sys failover standby" >/dev/null
echo "failover command on $U at 0 ms"; wait
awk -v z=$t -v o=$off '{t=$1; $1=""; printf "%+8.0f ms %s\n", (t-o-z)*1000, $0}' /tmp/sonic-trace.raw
