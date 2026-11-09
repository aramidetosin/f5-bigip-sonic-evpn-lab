#!/bin/bash
# k8s-node-net.sh (parts 22-24): the fabric side of a Kubernetes node, run by containerlab (exec) on k8s-cp / k8s-w1 / k8s-w2.
# Cabled like the servers (host-up.sh BOND=1): bond0 = eth1 + eth2, LACP fast, to the server leaf pair (ESI-LAG); env IP, GW.
# The node's own entrypoint (kindest/node) boots systemd, containerd and the kubelet; k8s-up.sh (on the lab server) runs kubeadm.
set -e
for i in eth1 eth2; do ethtool -K $i tx off >/dev/null 2>&1 || true; done
ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
for i in eth1 eth2; do ip link set $i down; ip link set $i master bond0; done
ip link set bond0 mtu 9000; ip link set bond0 up; ip addr add $IP dev bond0
ip route replace default via $GW dev bond0   # like the servers: everything but management goes to the fabric
