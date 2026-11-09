# Part 22: Kubernetes services through the BIG-IP with F5 CIS

| | |
|---|---|
| Video | [F5 CIS Tutorial: Kubernetes Ingress Through BIG-IP (Part 22)](https://youtu.be/35jRdBYhT6A) (public from 2026-12-26 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-cis/) (from 2026-12-26 04:00 UTC) |
| Previous / next | [Part 21](part21.md) / [Part 23](part23.md) |

## Goal

I put a Kubernetes cluster on the fabric and let a controller inside it configure the BIG-IP: F5 Container Ingress Services (CIS),
in NodePort mode. The cluster is three nodes cabled like the servers (LACP to both server leaves, VLAN 120), built with kubeadm. An
application runs as three pods behind a NodePort Service. On lb-f5a I make a partition and a user for CIS, install CIS (F5's CRDs and
RBAC, a Secret, the controller), and publish the application with one Kubernetes resource, a VirtualServer, which CIS turns into an
AS3 declaration. Then I measure what scaling changes on the BIG-IP, what `externalTrafficPolicy: Local` changes, what a node selector
does, how long a hand change lasts, what a stopped controller stops, and what deleting the resource removes.

The numbers below are from my runs. Yours will differ (timings, and how requests spread over nodes and pods).

## Starting state

- The lab is up and `./validate.sh` passes, including the Kubernetes checks: `up.sh` builds the cluster (stage 4b, `k8s-up.sh`, see
  [BUILD.md](../BUILD.md)). The two Docker images this part needs are on the lab host: `kindest/node:v1.35.8` (the nodes) and
  `f5networks/k8s-bigip-ctlr:2.20.4.1` (CIS); `k8s-up.sh` loads CIS and the lab's `f5lab/web:1` into every node, because the nodes have
  no internet access (`imagePullPolicy: Never` in the manifests).
- The name is part of the lab: `gen.py` `CIS` (k8s.f5lab.test, 10.20.30.120, partition `f5lab_k8s`, user `cis`, namespace `web`;
  `shared/cis-values.sh`); the PCs have it in `/etc/hosts` (`shared/pc-up.sh`). 10.20.30.120 is in the published 10.20.30.0/24 (part 3's
  BASIC VIPs), so the fabric and the firewall need no change.
- The end state of part 21 on lb-f5a: AS3 3.56.0 installed (CIS speaks AS3), no AS3 tenant; part 3's `vs-web` unchanged. On lb-f5a: no
  partition `f5lab_k8s`, no user `cis`.
- Units used: lb-f5a only. To get here: the guide of part 21, or restore the UCS you saved at its end with `./f5-restore.sh` (AS3 is in
  the UCS). Save lb-f5a before you start (`./f5-save.sh`).

Every command runs **on the lab server, as root, in the repo's root folder, with the helper functions loaded**:

```bash
. demo/f5fn.sh
S=/root/f5-clos-dc-secrets                       # the lab's secrets folder (BUILD.md, section 4)
P=/f5lab_k8s/Shared/whoami_80_web_k8s_f5lab_test  # the pool CIS will build (step 13)
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` runs a command on lb-f5a (bash as admin); `pc1 '<cmd>'` runs it on pc1;
`leaf2a '<cmd>'` runs a SONiC CLI command on leaf2a-server; `node <node> <cmd...>` runs a command inside a Kubernetes node
(`docker exec`); `kubectl ...` runs kubectl on the control plane (`k8s-cp`, admin kubeconfig).

## Values used in this part

| Object | Value |
|---|---|
| Kubernetes nodes | `k8s-cp` (control plane) 10.20.0.31, `k8s-w1` 10.20.0.32, `k8s-w2` 10.20.0.33 (VLAN 120, gateway 10.20.0.1); management 172.21.32.121-123 |
| Node cabling | bond0 = eth1 + eth2, 802.3ad, fast LACP, to leaf2a-server / leaf2b-server eth8-eth10 (PortChannel26-28, ESI-LAG) |
| Cluster | `kindest/node:v1.35.8`, kubeadm, cluster `f5lab`, pods 10.244.0.0/16, services 10.96.0.0/16, CNI kindnet, API 10.20.0.31:6443 |
| Application | namespace `web`, Deployment `whoami` (3 replicas, `f5lab/web:1`), Service `whoami` NodePort 80 > 30080 |
| BIG-IP | lb-f5a (management 172.21.32.43), partition `f5lab_k8s`, user `cis` (admin, all partitions), password in `$S/lb-f5a-cis-password` |
| CIS | `f5networks/k8s-bigip-ctlr:2.20.4.1`, custom-resource mode, namespace `web`, `--pool-member-type=nodeport`, Secret `kube-system/bigip-login` |
| VirtualServer | `web/whoami`: host k8s.f5lab.test, 10.20.30.120:80, SNAT auto, pool from Service `whoami` port 80, HTTP monitor on `/health` (5 s / 16 s) |

## Steps

### 1. The Kubernetes nodes in the lab

```bash
sed -n '/^IMG_K8S/,/^       "cis_image/p' gen.py
sed -n '/^    k8s-w1:/,/^    k8s-w2:/p' f5-clos-dc.clab.yml | head -14; grep 'k8s-w1:eth' f5-clos-dc.clab.yml
docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}' | grep k8s
```

You should see `IMG_K8S`, the three nodes with their port, VLAN, address, gateway, port-channel, management octet and role, and the
`K8S` values; in the topology, `k8s-w1` as a containerlab `linux` node from `kindest/node:v1.35.8`, with `/var` bound to a host
directory (`k8s-seed.sh` fills it before each deploy) and `/shared/k8s-node-net.sh` as its exec; its eth1 and eth2 cabled to
leaf2a-server and leaf2b-server eth9; and three running containers.

### 2. Cabled like the servers

```bash
sed -n '6,11p' shared/k8s-node-net.sh
leaf2a 'show interfaces portchannel' | grep -E 'No\.|PortChannel2[678]'; ssh admin@172.21.32.24 'show interfaces portchannel' | grep -E 'PortChannel2[678]'
leaf2a 'sudo vtysh -c "show evpn es"' | grep -E '^ESI|PortChannel2[678]'
node k8s-w1 sh -c "grep -iE 'bonding mode|slave interface|partner mac' /proc/net/bonding/bond0; ip -br addr show bond0; ip route show default"
node k8s-w1 curl -s -m 3 http://10.20.30.30/ | head -1
```

You should see the node script build bond0 (802.3ad, fast LACP) from eth1 and eth2, give it the fabric address and the default route;
PortChannel26-28 up on both server leaves; each as an EVPN Ethernet segment; on k8s-w1, 802.3ad with both slaves and a partner MAC,
10.20.0.32/24 on bond0, default via 10.20.0.1; and the sorry page fetched through the fabric (VLAN 120 > the anycast gateway >
VLAN 130).

### 3. The cluster

`up.sh` built the cluster with `k8s-up.sh`. Here is what that script runs, so you can see each piece. The kubeadm configuration is
generated by `gen.py`:

```bash
cat k8s/kubeadm.yaml
```

- `InitConfiguration`: the API server on 10.20.0.31:6443, and `node-ip` 10.20.0.31, so the control plane registers with its fabric
  address, not its management one.
- `ClusterConfiguration`: Kubernetes v1.35.8, cluster `f5lab`, pods 10.244.0.0/16, services 10.96.0.0/16.
- `KubeletConfiguration`: systemd cgroups, no swap check, no disk-pressure eviction (the node is a container on a shared disk).
- `KubeProxyConfiguration`: `conntrack.maxPerCore: 0` (a container cannot change the host's conntrack table size).

What `k8s-up.sh` runs with it, on k8s-cp:

```bash
kubeadm init --config /etc/kubernetes-kubeadm.yaml --skip-phases=preflight --skip-token-print
sed 's#{{ .PodSubnet }}#10.244.0.0/16#' /kind/manifests/default-cni.yaml | kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -
```

The second command installs kindnet, the CNI that ships in the kindest/node image: a route per node's pod /24 via that node's address.
Each worker then joins with a `JoinConfiguration` that sets its own `node-ip` (10.20.0.32, 10.20.0.33) and is labelled
`node-role.kubernetes.io/worker`. The node IP matters for this part: CIS builds the BIG-IP pool from the nodes' addresses.

Check the result:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
```

You should see three nodes `Ready`, INTERNAL-IP 10.20.0.31-33, and the control-plane pods, CoreDNS and kindnet running.

**Building it by hand instead.** In the video I built the cluster from nodes with no cluster, one command at a time. To do the same,
reset the nodes first (I did not run this exact loop; check that `kubectl get nodes` then fails):

```bash
for n in k8s-w2 k8s-w1 k8s-cp; do node $n kubeadm reset -f; done
```

Then on the control plane (the configuration file as above, then init, then kindnet):

```bash
node k8s-cp sh -c 'cat > /etc/kubernetes/kubeadm.yaml' < k8s/kubeadm.yaml && echo copied
node k8s-cp kubeadm init --config /etc/kubernetes/kubeadm.yaml --skip-phases=preflight --skip-token-print
node k8s-cp sh -c "sed 's#{{ .PodSubnet }}#10.244.0.0/16#' /kind/manifests/default-cni.yaml" | kubectl apply -f -
kubectl get nodes -o wide
```

`kubeadm init` took 9-10 s in my runs. For the workers, take the join command from the control plane (it holds a bootstrap token: do
not paste it anywhere) and join k8s-w1 the plain way first:

```bash
J=$(node k8s-cp kubeadm token create --print-join-command)
node k8s-w1 $J --skip-phases=preflight 2>&1 | tail -2
sleep 15; kubectl get nodes -o wide
node k8s-w1 ip -br -4 addr show | grep -E 'eth0|bond0'
```

You should see k8s-w1 registered with INTERNAL-IP 172.21.32.122, its management address on eth0: the node has two networks and the
kubelet chose the wrong one. Undo it, set the node IP on both workers, and join them:

```bash
kubectl delete node k8s-w1; node k8s-w1 kubeadm reset -f >/dev/null 2>&1; echo reset
node k8s-w1 sh -c 'echo KUBELET_EXTRA_ARGS=--node-ip=10.20.0.32 > /etc/default/kubelet'
node k8s-w2 sh -c 'echo KUBELET_EXTRA_ARGS=--node-ip=10.20.0.33 > /etc/default/kubelet'
for w in k8s-w1 k8s-w2; do node $w $J --skip-phases=preflight 2>&1 | tail -1; kubectl label node $w node-role.kubernetes.io/worker=; done
sleep 20; kubectl get nodes -o wide
node k8s-w1 crictl images | grep -E 'IMAGE|f5lab|bigip'
```

You should see all three nodes `Ready` on 10.20.0.31-33, and the `f5lab/web` and `k8s-bigip-ctlr` images already on the worker
(`kubeadm reset` does not remove images).

### 4. The application: pods behind a NodePort Service

```bash
cat k8s/part22/web.yaml
```

- Namespace `web`.
- Deployment `whoami`: 3 replicas of `f5lab/web:1` (nginx). The downward API gives each pod its own name, pod IP and node; the pod
  answers every request with them and with the client address it saw, and serves `/health` (`OK`) for its readiness probe.
- Service `whoami`, `type: NodePort`: port 80 to the pods' port 80, and node port 30080 open on every node.

```bash
kubectl apply -f - < k8s/part22/web.yaml; kubectl -n web rollout status deploy/whoami
kubectl -n web get pods -o wide; kubectl -n web get svc whoami
kubectl -n web get endpointslices
```

You should see `successfully rolled out`, three pods on the workers with 10.244.x addresses, the Service `NodePort` `80:30080/TCP`,
and an EndpointSlice with the three pod addresses.

### 5. What a NodePort does

```bash
for n in 10.20.0.31 10.20.0.32 10.20.0.33; do echo "== $n:30080"; docker exec clab-f5-clos-dc-server1 curl -s -m 3 http://$n:30080/; done
node k8s-w1 iptables-save -t nat | grep -E 'KUBE-NODEPORTS.*30080|KUBE-SVC-.*statistic' | head -6
```

You should see every node answer on 30080, including the control plane, which runs no pod: kube-proxy forwarded the request to a pod
on another node, and that pod saw the receiving node's address as the client (the default `externalTrafficPolicy: Cluster` source-NATs
it). In the NAT table: the `KUBE-NODEPORTS` rule for 30080, and the Service chain choosing a pod with `statistic --mode random` rules
(1/3, then 1/2, then the rest).

### 6. A partition for CIS on lb-f5a

```bash
f5 'tmsh list auth partition | grep partition; tmsh list auth user | grep "auth user"'
f5 'tmsh create auth partition f5lab_k8s description "managed by F5 CIS (cluster f5lab)"; tmsh list auth partition f5lab_k8s'
```

You should see the existing partitions and users, then `f5lab_k8s` with its description. CIS will write only into this partition.

### 7. A BIG-IP user for CIS

The password goes into the lab's secrets folder, never on a command line or in the repo. `tr -d '\n'` matters: a trailing newline in
the file would end up in the Kubernetes Secret (step 10) and the login would fail.

```bash
openssl rand -hex 16 | tr -d '\n' > $S/lb-f5a-cis-password; chmod 600 $S/lb-f5a-cis-password; ls -l $S/lb-f5a-cis-password
```

First try: the admin role on the CIS partition only. The password is read on the BIG-IP from stdin (`read -r P`); keep the single
quotes, so `$P` is expanded on the BIG-IP, not on the lab server:

```bash
f5 'read -r P; tmsh create auth user cis password "$P" shell none partition-access replace-all-with { f5lab_k8s { role admin } }' < $S/lb-f5a-cis-password
```

You should see it refused: the admin role "may not be restricted to a single partition". Second try, the manager role on the partition:

```bash
f5 'read -r P; tmsh create auth user cis password "$P" shell none partition-access replace-all-with { f5lab_k8s { role manager } }; tmsh list auth user cis partition-access' < $S/lb-f5a-cis-password
```

You should see `cis` created with `f5lab_k8s` `role manager`. Test it the way CIS uses it. `demo/bigip-user.sh` reads the password
on stdin; `login` asks the BIG-IP for a token (`POST /mgmt/shared/authn/login`) and calls AS3 with it; `setpw` sets the password as
admin through the REST user store (`PATCH /mgmt/shared/authz/users/<user>`):

```bash
sed -n '2,7p' demo/bigip-user.sh
demo/bigip-user.sh login cis < $S/lb-f5a-cis-password
```

You should see "Password expired. Update password via /mgmt/shared/authz/users": with the password policy enforced, a password an
administrator sets for a new user starts expired. Set it through that user store, and test again:

```bash
demo/bigip-user.sh setpw cis < $S/lb-f5a-cis-password; demo/bigip-user.sh login cis < $S/lb-f5a-cis-password
```

You should see the PATCH return HTTP 200, a token, and then AS3 answering that token with HTTP 401: a partition manager cannot use AS3.
CIS therefore needs admin on all partitions; the partition boundary is kept by CIS's own `--bigip-partition` argument (step 11):

```bash
f5 'tmsh modify auth user cis partition-access replace-all-with { all-partitions { role admin } }; tmsh list auth user cis partition-access'
sleep 5; demo/bigip-user.sh login cis < $S/lb-f5a-cis-password
```

You should see `all-partitions` `role admin`, then a token and AS3 `HTTP 200`.

### 8. F5's custom resource definitions

CIS's CRDs and RBAC come from F5's release 2.20.4.1, unchanged in `k8s/vendor/` (`SOURCE.md` gives the URL of each file):

```bash
cat k8s/vendor/SOURCE.md
kubectl apply -f - < k8s/vendor/cis-customresourcedefinitions-v2.20.4.1.yml
kubectl api-resources --api-group=cis.f5.com
```

You should see the CRDs created, and the `cis.f5.com` resources listed: VirtualServer, TLSProfile, TransportServer, IngressLink, ExternalDNS and Policy.

### 9. RBAC: what CIS may read

```bash
sed -n '4,13p;36,52p' k8s/vendor/cis-k8s-rbac-v2.20.4.1.yml
kubectl apply -f - < k8s/vendor/cis-k8s-rbac-v2.20.4.1.yml
```

The ClusterRole lets CIS read nodes, Services, endpoints, namespaces, pods and ingresses, write ConfigMaps, events and status, and
read and update its own resources; the ClusterRoleBinding gives it to the service account `bigip-ctlr` in `kube-system`, which the
file also creates. You should see the three objects created.

### 10. The credentials Secret

```bash
kubectl -n kube-system create secret generic bigip-login --from-literal=username=cis --from-file=password=/dev/stdin < $S/lb-f5a-cis-password
kubectl -n kube-system describe secret bigip-login | tail -5
```

The password comes from the file on stdin, so it is never on a command line. You should see `password: 32 bytes` (no newline) and
`username: 3 bytes`.

### 11. The controller

```bash
cat k8s/part22/cis.yaml
```

One Deployment in `kube-system`, service account `bigip-ctlr`, image `f5networks/k8s-bigip-ctlr:2.20.4.1`, with these arguments:

- `--bigip-url=https://172.21.32.43`: lb-f5a's management address. CIS talks to the REST API there; it never carries traffic.
- `--bigip-partition=f5lab_k8s`: the only partition it writes.
- `--credentials-directory=/tmp/creds`: the Secret `bigip-login`, mounted as files.
- `--custom-resource-mode=true`: it acts on CIS custom resources (VirtualServer and the others).
- `--namespace=web`: the only namespace it watches.
- `--pool-member-type=nodeport`: pool members are the nodes with the Service's node port.
- `--insecure=true`: the lab's BIG-IP management certificate is the factory self-signed one.

```bash
kubectl apply -f - < k8s/part22/cis.yaml; kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr
kubectl -n kube-system get pods -l app=k8s-bigip-ctlr -o wide
kubectl -n kube-system logs deploy/k8s-bigip-ctlr | grep -vE 'deprecated|informer' | head -9
```

You should see the controller rolled out and running on a worker, and the start of its log. Nothing is built on the BIG-IP yet: there
is no VirtualServer.

### 12. Publishing the application: one VirtualServer

```bash
cat k8s/part22/vs.yaml
```

- `labels: {f5cr: "true"}`: CIS only picks up custom resources with this label. Without it (I tried in the dry run), CIS logged
  nothing and built nothing.
- `host: k8s.f5lab.test` and `virtualServerAddress: 10.20.30.120`: the name and the VIP.
- `snat: auto`: SNAT automap (the BIG-IP is not the nodes' gateway).
- `pools`: path `/` to Service `whoami` port 80, with an HTTP monitor (`GET /health`, receive `OK`, interval 5 s, timeout 16 s).

```bash
kubectl apply -f - < k8s/part22/vs.yaml; sleep 15; kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=60s | grep -E 'Request|SUCCESS'
kubectl -n web get virtualserver whoami
```

You should see CIS log `CREATE in VIRTUALSERVER web/whoami`, an AS3 request, then `SUCCESS: code: 200 --- tenant:f5lab_k8s` (10 s
after the apply in my run), and the VirtualServer with 10.20.30.120 and status OK.

### 13. What CIS built on lb-f5a

```bash
echo $P
f5 "tmsh -c 'cd /f5lab_k8s; list ltm recursive one-line' | grep -E '^ltm (virtual |pool|monitor|policy)'"
f5 'tmsh list ltm virtual /f5lab_k8s/Shared/crd_10_20_30_120_80 destination pool policies source-address-translation { type } profiles persist'
f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |status.availability|status.status-reason' | grep -v 'pool '"
f5 "curl -s -u admin: http://localhost:8100/mgmt/shared/appsvcs/declare/f5lab_k8s | jq -c '.f5lab_k8s.Shared | keys'"
f5 "curl -s -u admin: http://localhost:8100/mgmt/shared/appsvcs/declare/f5lab_k8s | jq -c '.f5lab_k8s.Shared.whoami_80_web_k8s_f5lab_test.members[] | {serverAddresses, servicePort}'"
```

You should see, in `/f5lab_k8s/Shared`: an HTTP monitor, an LTM policy (host to pool), the pool `whoami_80_web_k8s_f5lab_test`
(named after the service, port, namespace and host), and the virtual server `crd_10_20_30_120_80` on 10.20.30.120:80 with no default
pool (the policy picks it), SNAT automap, and `f5-tcp-progressive`, `http` and cookie persistence: AS3's `http` template defaults
(part 21), which the VirtualServer never asked for. The pool's members are 10.20.0.31-33:30080, all available. The AS3 declaration
CIS posted holds the same objects.

### 14. Through the BIG-IP to the pods

```bash
pc1 'grep k8s.f5lab /etc/hosts'
pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
pc1 'curl -s -m 3 -o /dev/null -w "by address, Host 10.20.30.120: %{http_code}\n" http://10.20.30.120/'
f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |serverside.tot-conns' | grep -v 'pool '"
```

You should see six answers from pods on both workers. The client each pod saw is a node's address (10.20.0.31 / .32), or the receiving
node's own pod-range address (10.244.x.1) when the pod was on that node: the BIG-IP's SNAT, then kube-proxy's. By address instead of
name: `000`, no answer, because the policy forwards only the host k8s.f5lab.test. The BIG-IP counted six server-side connections, split
3/2/1 over the three nodes in my run. lb-f5a runs four TMMs; that each keeps its own round-robin position is my inference, not measured.

### 15. Scaling the application

```bash
kubectl -n web scale deploy/whoami --replicas=1; sleep 15; kubectl -n web get pods -o wide
f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |status.availability|status.status-reason' | grep -v 'pool '"
kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=60s | grep -E 'Request|SUCCESS'; echo "CIS log lines in the last 60 s: $(kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=60s | grep -c Request)"
pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
```

You should see one pod; the pool unchanged, three members, all available; in CIS's log (at `--log-level=INFO` the detail is short)
an update of the endpoints and then "No tenants found in request": nothing posted. Every request reaches the one pod, most of them
through another node. In NodePort mode the pool is the nodes, and the nodes did not change.

### 16. `externalTrafficPolicy: Local`

With `Local`, a node delivers only to its own pods and does not source-NAT; a node without a pod does not answer on the node port.

```bash
kubectl -n web patch svc whoami -p '{"spec":{"externalTrafficPolicy":"Local"}}'; sleep 25
f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |status.availability|status.status-reason' | grep -v 'pool '"
pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
```

You should see the control plane and the worker without a pod `offline` ("No successful responses received before deadline"), and
every request answered by the one pod, which now sees 10.20.0.240, the BIG-IP's floating internal self IP: one NAT instead of two.
Scale back to three:

```bash
kubectl -n web scale deploy/whoami --replicas=3; sleep 25; kubectl -n web get pods -o wide
sleep 30; f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |status.availability|status.status-reason' | grep -v 'pool '"
kubectl describe node k8s-cp | grep Taints
```

You should see both workers available again and the control plane still offline: its taint (`NoSchedule`) keeps pods off it, so with
`Local` it never answers. Note what the monitor tests: with `Cluster`, `GET /health` to a node reaches some pod anywhere, so a node with
no pod is "available"; with `Local`, it tests a pod on that node.

### 17. Pool members from the workers only

```bash
kubectl get nodes -L node-role.kubernetes.io/worker
kubectl -n kube-system patch deploy k8s-bigip-ctlr --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--node-label-selector=node-role.kubernetes.io/worker"}]'
kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr; sleep 25
sleep 45; f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |status.availability|status.status-reason' | grep -v 'pool '"
pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
```

You should see the worker label on k8s-w1 and k8s-w2 only; after CIS restarts with `--node-label-selector`, the pool holds only the two
workers, and requests reach pods on both.

### 18. A hand change inside the CIS partition

```bash
f5 "tmsh modify ltm pool $P load-balancing-mode least-connections-member; tmsh list ltm pool $P load-balancing-mode"
sleep 60; f5 "tmsh list ltm pool $P load-balancing-mode"
kubectl -n kube-system rollout restart deploy/k8s-bigip-ctlr; kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr
for i in $(seq 30); do kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=90s | grep -q SUCCESS && break; sleep 2; done
kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=60s | grep -E 'Request|SUCCESS'
f5 "tmsh list ltm pool $P load-balancing-mode"
```

You should see `least-connections-member`, still there a minute later: CIS does not compare the box with its declaration on a timer.
After a controller restart, CIS posts the tenant again (`SUCCESS ... tenant:f5lab_k8s`) and the pool is back to round robin.

### 19. The controller stopped

```bash
kubectl -n kube-system scale deploy/k8s-bigip-ctlr --replicas=0; sleep 5; kubectl -n kube-system get deploy k8s-bigip-ctlr
pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
kubectl -n web scale deploy/whoami --replicas=1; sleep 20; kubectl -n web get pods -o wide
f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |status.availability|status.status-reason' | grep -v 'pool '"
pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
kubectl -n kube-system scale deploy/k8s-bigip-ctlr --replicas=1; kubectl -n web scale deploy/whoami --replicas=3; kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr
```

You should see CIS at 0 replicas and traffic carrying on; with the application at one pod, the BIG-IP's own monitor (the Service is
still `Local`) takes the worker without a pod out, and requests still succeed. The data plane does not need the controller; only
changes wait for it. The last line brings CIS and the three pods back.

### 20. Deleting the VirtualServer

```bash
kubectl -n web delete virtualserver whoami; sleep 5
for i in $(seq 30); do kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=20s | grep -q SUCCESS && break; sleep 2; done
kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=25s | grep -E 'Request|SUCCESS'
f5 "tmsh -c 'cd /f5lab_k8s; list ltm recursive one-line' | grep -cE '^ltm (virtual |pool|monitor|policy)'; tmsh list auth partition f5lab_k8s"
pc1 'curl -s -m 3 -o /dev/null -w "k8s.f5lab.test: %{http_code}\n" http://k8s.f5lab.test/'
f5 'tmsh list ltm virtual vs-web destination'
```

You should see CIS post the empty tenant (`SUCCESS`), 0 objects left in `/f5lab_k8s` (the partition stays, its description now
"Updated by AS3"), `000` on the name, and part 3's `vs-web` untouched. Apply it again:

```bash
kubectl apply -f - < k8s/part22/vs.yaml; sleep 20; pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
```

You should see the application served again, within 20 s in my run.

### 21. Back to the end state

Part 23 starts from the default traffic policy and a controller without the node selector:

```bash
kubectl -n web patch svc whoami -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
kubectl apply -f - < k8s/part22/cis.yaml; kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr
kubectl -n web get svc whoami -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'; kubectl -n web get virtualserver whoami
```

Re-applying `cis.yaml` replaces the patched argument list with the file's. You should see `Cluster` and the VirtualServer with status OK.

## Verify

| Test | What I measured |
|---|---|
| Cluster | 3 nodes Ready, INTERNAL-IP 10.20.0.31-33; `kubeadm init` 9-10 s |
| Plain `kubeadm join` | worker registered with 172.21.32.122 (management); with `--node-ip`, 10.20.0.32 / .33 |
| NodePort | every node answers on 30080, the control plane included |
| User `cis` | admin on one partition refused; manager: token, AS3 401; first password expired until set via `/mgmt/shared/authz/users`; admin on all partitions: AS3 200 |
| VirtualServer without `f5cr: "true"` | nothing logged, nothing built |
| VirtualServer applied | AS3 `SUCCESS` 10 s later, status Ok; monitor, policy, pool (10.20.0.31-33:30080), `crd_10_20_30_120_80` with f5-tcp-progressive and cookie persistence |
| Traffic | 6 requests to pods on both workers; BIG-IP split 3/2/1 over the nodes; by address: 000 |
| Scale 3 > 1 | pool unchanged, "No tenants found in request", nothing posted |
| `Local` | pod-less nodes and the control plane offline; pod sees 10.20.0.240 |
| Node selector | pool = the two workers |
| Hand change | still there after 60 s; undone by a controller restart |
| CIS at 0 replicas | traffic continues; the monitor handles a scale-down alone (Local) |
| Delete VirtualServer | 0 objects, partition kept, vs-web untouched; re-applied: served within 20 s |

## Gotchas

- **Multi-homed nodes need `--node-ip`.** A plain `kubeadm join` registered the worker with its management address (eth0). CIS builds
  the pool from node addresses, so the BIG-IP would send traffic to the management network. `k8s-up.sh` sets the node IP for every node.
- **The label.** CIS ignores a VirtualServer without `f5cr: "true"`, silently: no log, no status.
- **The CIS user is an administrator.** Admin cannot be limited to one partition, and a partition manager gets 401 from AS3. CIS's
  `--bigip-partition` keeps it in its partition; treat the Secret as an administrator's password.
- **The first password of a new user starts expired** when the password policy is enforced. Set it as admin through
  `PATCH /mgmt/shared/authz/users/<user>`; check with a token login, as CIS does.
- **No newline in the password file.** A Secret built from a file keeps a trailing newline; write the file with `tr -d '\n'`.
- **Quotes around `$P`.** In `f5 '... "$P" ...'` the single quotes send `$P` to the BIG-IP, where `read -r P` set it. With outer double
  quotes, the lab server would expand it (empty).
- **Defaults you did not write.** CIS posts AS3, so its virtual server got the `http` template's `f5-tcp-progressive` and cookie
  persistence.
- **NodePort balances nodes, not pods.** With `Cluster`, kube-proxy balances again behind the BIG-IP, and a node with no pod is still
  "available". With `Local`, empty nodes stay in the pool and only the monitor keeps them out. Persistence, least connections and slow
  start act on nodes. Part 23 moves to pods as members.
- **Hand changes last until the next post.** CIS has no timer that re-posts; any change it does post (a restart, a resource change)
  overwrites the partition.

## End state

- Cluster of three nodes with the application (`whoami`, 3 replicas, NodePort 30080, `externalTrafficPolicy: Cluster`).
- CIS 2.20.4.1 running with `cis.yaml` as in the repo (no node selector); CRDs, RBAC and Secret `bigip-login` in place.
- VirtualServer `web/whoami` applied: on lb-f5a, `/f5lab_k8s/Shared` with `crd_10_20_30_120_80` on 10.20.30.120, its pool, monitor and
  policy; k8s.f5lab.test answers from pc1.
- lb-f5a: partition `f5lab_k8s`, user `cis` (admin, all partitions); password in `$S/lb-f5a-cis-password`. Everything from parts 1-21
  unchanged.

Save it (lb-f5a; the Kubernetes objects live in the cluster, not in the UCS):

```bash
./f5-save.sh lb-f5a
```

## Reset

I did not run these reset commands in my lab: check each result. On the Kubernetes side, delete in this order, so CIS removes its
objects from the BIG-IP before it stops:

```bash
kubectl -n web delete virtualserver whoami; sleep 20
kubectl delete -f - < k8s/part22/cis.yaml
kubectl -n kube-system delete secret bigip-login
kubectl delete -f - < k8s/vendor/cis-k8s-rbac-v2.20.4.1.yml
kubectl delete -f - < k8s/vendor/cis-customresourcedefinitions-v2.20.4.1.yml
kubectl delete -f - < k8s/part22/web.yaml
```

On lb-f5a, restore the UCS you saved at the start of this part (the end of part 21):

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
```

Or remove `cis` and the partition (`tmsh list auth partition` should then list no `f5lab_k8s`):

```bash
f5 'tmsh delete auth user cis; tmsh delete auth partition f5lab_k8s'
rm -f $S/lb-f5a-cis-password
```

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `pc1`, `leaf2a`, `node`, `kubectl`.
- `demo/bigip-user.sh`: a token login as a BIG-IP user and an AS3 call with the token, and setting its password through the REST user store (password on stdin).
- `gen.py`: `IMG_K8S`, `K8S_NODES`, `K8S`, `CIS`; it writes `k8s/kubeadm.yaml`, `shared/k8s-values.sh` and `shared/cis-values.sh`.
- `k8s-seed.sh`, `k8s-up.sh`, `shared/k8s-node-net.sh`: the nodes' `/var`, the cluster build, the nodes' bond0 (run by `up.sh` and containerlab).
- `k8s/part22/web.yaml`: namespace `web`, Deployment and NodePort Service `whoami`.
- `k8s/part22/cis.yaml`: the CIS controller.
- `k8s/part22/vs.yaml`: the VirtualServer.
- `k8s/vendor/`: F5's CRDs and RBAC for CIS 2.20.4.1, unchanged (`SOURCE.md` gives their URLs).
- Not in the repository: the CIS password (`$S/lb-f5a-cis-password`, created in step 7) and the Docker images (BUILD.md).
