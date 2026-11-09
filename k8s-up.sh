#!/bin/bash
# k8s-up.sh (parts 22-24): build the lab's Kubernetes cluster on the running nodes, after the switches are configured (the workers
# join over the fabric). kubeadm with the images preloaded in kindest/node (no internet); node IPs = the fabric addresses on bond0, so
# the API server, the kubelets and NodePorts all live in VLAN 120; CNI = kindnet (kind's own: a route per node's pod /24 via its
# node IP). Loads the lab's images (whoami web, CIS) into every node's containerd. Idempotent: a built cluster is only checked.
cd "$(dirname "$0")"; . ./lib.sh; . shared/k8s-values.sh
K() { docker exec -i $C-$1 bash -c "$2"; }
nv() { eval echo \$NODE_$(echo $1 | tr 'a-z-' 'A-Z_'); }          # "<fabric ip> <role> <mgmt ip>"
CP=$(for n in $K8S_NODES; do set -- $(nv $n); [ "$2" = control-plane ] && echo $n; done | head -1); CPIP=$(nv $CP | cut -d' ' -f1)
for n in $K8S_NODES; do
  for i in $(seq 1 60); do K $n 'systemctl is-active -q containerd' 2>/dev/null && break; sleep 5; done
  K $n "ip -4 -o addr show bond0 | grep -q $(nv $n | cut -d' ' -f1)" || { say "k8s-up: $n has no fabric address on bond0"; exit 1; }
done
if K $CP 'test -f /etc/kubernetes/admin.conf'; then say "k8s-up: cluster already built on $CP"
else
  say "k8s-up: kubeadm init on $CP ($CPIP)"
  K $CP 'cat > /etc/kubernetes-kubeadm.yaml' < k8s/kubeadm.yaml      # gen.py's kubeadm configuration
  K $CP 'kubeadm init --config /etc/kubernetes-kubeadm.yaml --skip-phases=preflight --skip-token-print' > logs/k8s-init.txt 2>&1 \
    || { tail -5 logs/k8s-init.txt; exit 1; }
  K $CP "sed 's#{{ .PodSubnet }}#$K8S_PODS#' /kind/manifests/default-cni.yaml | kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -" >/dev/null
  J=$(K $CP 'kubeadm token create --print-join-command')          # holds a bootstrap token: never printed or logged
  T=$(echo "$J" | sed -n 's/.*--token \([^ ]*\).*/\1/p'); H=$(echo "$J" | sed -n 's/.*--discovery-token-ca-cert-hash \([^ ]*\).*/\1/p')
  for n in $K8S_NODES; do [ $n = $CP ] && continue; ip=$(nv $n | cut -d' ' -f1)
    printf 'apiVersion: kubeadm.k8s.io/v1beta4\nkind: JoinConfiguration\ndiscovery: {bootstrapToken: {apiServerEndpoint: "%s:6443", token: "%s", caCertHashes: ["%s"]}}\nnodeRegistration: {criSocket: unix:///run/containerd/containerd.sock, kubeletExtraArgs: [{name: node-ip, value: "%s"}]}\n' \
      "$CPIP" "$T" "$H" "$ip" | K $n 'umask 077; cat > /etc/kubernetes-join.yaml'
    say "k8s-up: $n joins ($ip)"
    K $n 'kubeadm join --config /etc/kubernetes-join.yaml --skip-phases=preflight; rm -f /etc/kubernetes-join.yaml' > logs/k8s-join-$n.txt 2>&1 \
      || { tail -5 logs/k8s-join-$n.txt; exit 1; }
    K $CP "kubectl --kubeconfig /etc/kubernetes/admin.conf label node $n node-role.kubernetes.io/worker= --overwrite" >/dev/null
  done
fi
for img in f5lab/web:1 $CIS_IMAGE; do
  docker image inspect $img >/dev/null 2>&1 || { say "k8s-up: image $img missing on this server"; continue; }
  for n in $K8S_NODES; do
    K $n "ctr -n k8s.io images ls -q | grep -qx 'docker.io/$img'" && continue
    docker save $img | K $n 'ctr -n k8s.io images import --digests --snapshotter=overlayfs -' >/dev/null && say "k8s-up: $img > $n"
  done
done
for i in $(seq 1 60); do
  r=$(K $CP 'kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes --no-headers' | awk '$2=="Ready"' | wc -l)
  [ "$r" -eq $(echo $K8S_NODES | wc -w) ] && break; sleep 5; done
K $CP 'kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide'
