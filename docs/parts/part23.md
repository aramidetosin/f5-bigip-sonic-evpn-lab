# Part 23: CIS in cluster mode: pods as pool members, TLS and WAF from Kubernetes

| | |
|---|---|
| Video | [F5 CIS Cluster Mode: Pods as Pool Members, TLS and WAF (Part 23)](https://youtu.be/xywG1iOrfTM) (public from 2026-12-29 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-cis-cluster-mode/) (from 2026-12-29 04:00 UTC) |
| Previous / next | [Part 22](part22.md) / [Part 24](part24.md) |

## Goal

In part 22 the BIG-IP balanced nodes (NodePort) and kube-proxy balanced again behind it. Here I switch the same CIS controller to
cluster mode: the pool members are the pods themselves. Two controller arguments do it: `--pool-member-type=cluster` and
`--static-routing-mode=true`, with which CIS also writes one BIG-IP route per node (the node's pod CIDR via its fabric address). I
look at how the pod network is routed first, then measure how fast the pool follows Kubernetes, what a client sees while a pod goes
away, and what a graceful exit (preStop) changes. Then I declare HTTPS from a Kubernetes TLS Secret, the part 16 WAF policy and
X-Forwarded-For, all from Kubernetes resources. Day two, measured: readiness, persistence per pod, a route deleted by hand and a node
drained under load.

The numbers below are from my runs. Yours will differ (timings, pod addresses, pod CIDRs, how requests spread over pods).

## Starting state

- The end state of part 22: the cluster (3 nodes, `whoami` 3 replicas, NodePort 30080, `externalTrafficPolicy: Cluster`), CIS 2.20.4.1
  with `k8s/part22/cis.yaml` (NodePort members), VirtualServer `web/whoami` on 10.20.30.120:80, served from pc1 as k8s.f5lab.test.
- From earlier parts, on lb-f5a: the HTTP profile `/Common/http-xff` (part 4, inserts X-Forwarded-For) and the security policy
  `/Common/waf-app` (part 16, blocking, signatures enforced; ASM provisioned).
- The certificate for k8s.f5lab.test from the lab CA: `$S/tls/k8s.crt` and `$S/tls/k8s.key`. `gen.py` `TLS_NAMES` lists the name and
  `secrets-init.sh` issues it (`up.sh` runs it). If your secrets folder was made before the name was added, run `./secrets-init.sh`
  again: it issues only the missing certificates. pc1 trusts the lab CA (`shared/pc-up.sh`).
- Units used: lb-f5a only. To get here: the guide of part 22, or restore the UCS you saved at its end with `./f5-restore.sh` (the
  Kubernetes objects are not in the UCS: re-apply part 22's manifests). Save lb-f5a before you start (`./f5-save.sh`).

Every command runs **on the lab server, as root, in the repo's root folder, with the helper functions loaded**:

```bash
. demo/f5fn.sh
S=/root/f5-clos-dc-secrets                       # the lab's secrets folder (BUILD.md, section 4)
P=/f5lab_k8s/Shared/whoami_80_web_k8s_f5lab_test  # CIS's pool (part 22)
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` runs a command on lb-f5a (bash as admin); `pc1 '<cmd>'` runs it on pc1;
`node <node> <cmd...>` runs a command inside a Kubernetes node (`docker exec`); `kubectl ...` runs kubectl on the control plane
(`k8s-cp`, admin kubeconfig). Several commands below end with `2>&1 | grep -v api-status` in my recording only to hide a BIG-IP login
banner line; they are left out here.

## Values used in this part

| Object | Value |
|---|---|
| CIS | `k8s/part23/cis-cluster.yaml`: as part 22 plus `--pool-member-type=cluster` and `--static-routing-mode=true` |
| Pod network | 10.244.0.0/16, one /24 per node (`spec.podCIDR`); kindnet (`ptp` CNI, no overlay); in my lab k8s-cp 10.244.0.0/24, k8s-w1 10.244.3.0/24, k8s-w2 10.244.4.0/24 |
| CIS routes | partition `f5lab_k8s`: `k8s-<node>-<node IP>`, network = the node's pod CIDR, gateway = the node IP (10.20.0.31-33) |
| Application v2 | `k8s/part23/web-v2.yaml`: label `version: v2`, `terminationGracePeriodSeconds: 30`, preStop `sleep 15`, prints `x-forwarded-for` |
| TLS | Secret `web/k8s-tls` (type `kubernetes.io/tls`) from `$S/tls/k8s.crt` / `.key`; TLSProfile `web/k8s-tls`: host k8s.f5lab.test, edge, reference secret |
| Policy | `web/whoami-policy`: HTTP profile `/Common/http-xff` |
| VirtualServer v2 | `k8s/part23/vs-tls.yaml`: as part 22 plus `tlsProfileName: k8s-tls`, `httpTraffic: redirect`, `waf: /Common/waf-app`, `policyName: whoami-policy` |
| Helpers | `demo/k8s-member-watch.sh`, `demo/k8s-errors.sh`, `demo/k8s-route-watch.sh`, `demo/k8s-drain.sh` |

## Steps

### 1. Where part 22 left the BIG-IP: no way to a pod

```bash
f5 "tmsh list ltm pool $P members | grep -oE '[0-9.]+:[0-9]+ '"
kubectl -n web get pods -o wide
f5 "tmsh list net route one-line; tmsh -c 'cd /f5lab_k8s; list net route recursive one-line'"
POD=$(kubectl -n web get pods -o jsonpath='{.items[0].status.podIP}'); echo $POD
f5 "ip route get $POD" | head -1
f5 "ping -c 2 -W 1 $POD" | tail -2
```

You should see the NodePort members 10.20.0.31-33:30080, pods with 10.244.x.x addresses, and no route on lb-f5a for 10.244.0.0/16.
`ip route get` sends a pod address to the default route (10.20.30.1, the external side), and the ping gets 100% loss. Note that
`tmsh list net route` from `/Common` does not show routes in other partitions: list a partition's routes with
`tmsh -c 'cd /f5lab_k8s; list net route recursive'`.

### 2. How the pod network is routed

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,NODE-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR
node k8s-w1 ip route | grep 10.244
node k8s-cp ip route | grep 10.244
```

You should see each node with its own /24 (`spec.podCIDR`). On every node, kindnet adds a route to each other node's /24 through that
node's IP on bond0, and a host route per local pod (`/32 dev veth...`). No overlay, no tunnel. The BIG-IP needs the same routes, and
their next hop must be directly reachable: the nodes are in the BIG-IP's internal VLAN 120.

In my lab, k8s-cp also kept two stale routes (10.244.1.0/24 and 10.244.2.0/24 via 172.21.32.122 on eth0). They are left from the
plain `kubeadm join` of part 22, step 3, that registered k8s-w1 with its management address. That is also why my workers have
10.244.3.0/24 and 10.244.4.0/24. A cluster built by `k8s-up.sh` (which sets `--node-ip`) has neither.

CIS reads `spec.podCIDR` for its routes, so it must match the ranges the CNI really uses. kindnet takes its subnets from
`spec.podCIDR` (`/etc/cni/net.d/10-kindnet.conflist`, step 5), so here they match.

### 3. Cluster mode: two arguments

```bash
diff k8s/part22/cis.yaml k8s/part23/cis-cluster.yaml
```

- `--pool-member-type=cluster`: the members are the Service's ready endpoints (pod IP and target port), read from Kubernetes, instead
  of node IP and node port.
- `--static-routing-mode=true`: CIS also writes one BIG-IP route per node, `<node podCIDR>` via `<node IP>`, in its partition.

Everything else (partition, user Secret, namespace, custom-resource mode) is as in part 22.

```bash
kubectl apply -f - < k8s/part23/cis-cluster.yaml; kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr
for i in $(seq 30); do kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=90s | grep -q SUCCESS && break; sleep 2; done
kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=60s | grep -E 'Request|SUCCESS' | cut -c1-150
f5 "tmsh -c 'cd /f5lab_k8s; list net route recursive one-line'"
f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |status.availability' | grep -v 'pool '"
f5 "ping -c 2 -W 1 $POD" | tail -2
```

You should see the new controller post the tenant (`SUCCESS ... tenant:f5lab_k8s`, 11 s in my run), three routes in `/f5lab_k8s`
(`k8s-k8s-cp-10.20.0.31` for 10.244.0.0/24, `k8s-k8s-w1-10.20.0.32` and `k8s-k8s-w2-10.20.0.33` for the workers' /24s), exactly the
nodes' own routes. The pool members are now the three pod addresses on port 80, available. The ping that failed in step 1 answers
(about 3 ms in my run). If the pod in `$POD` was replaced in between, set `POD` again.

### 4. Traffic straight to the pods

```bash
pc1 'for i in 1 2 3 4 5 6; do curl -s -m 3 http://k8s.f5lab.test/ | tr "\n" " "; echo; done'
f5 "tmsh show ltm pool $P members field-fmt | grep -E 'addr |serverside.tot-conns' | grep -v 'pool '"
```

You should see each pod report `client seen: 10.20.0.240`, lb-f5a's floating self IP: the BIG-IP's SNAT is now the only NAT, and
kube-proxy is no longer in the path. My six requests split 3/3/0 over the three pods. lb-f5a runs four TMMs; that each keeps its own
round-robin position is my inference, not measured.

### 5. Under the hood: what CIS sent, and how kindnet wires a pod

```bash
f5 "curl -s -u admin: http://localhost:8100/mgmt/shared/appsvcs/declare/f5lab_k8s | jq -c '.f5lab_k8s.Shared.whoami_80_web_k8s_f5lab_test.members[] | {serverAddresses, servicePort}'"
f5 "curl -s -u admin: http://localhost:8100/mgmt/shared/appsvcs/declare/f5lab_k8s | jq '[.. | objects | select(.class? == \"Route\")] | length'"
node k8s-w1 cat /etc/cni/net.d/10-kindnet.conflist | grep -E 'type|subnet|ipMasq|mtu'
node k8s-w1 iptables -t nat -S KIND-MASQ-AGENT | cut -c1-150
```

You should see the members in the AS3 declaration as the pod addresses with service port 80, and `0` Route objects: CIS writes its
routes outside the declaration. The CNI configuration: plugin `ptp` (a veth pair per pod), `host-local` addresses from the node's
subnet (10.244.3.0/24 on k8s-w1 in my lab), `ipMasq: false`, MTU 1500, `portmap`. The `KIND-MASQ-AGENT` chain returns (no NAT) for
traffic to 10.244.0.0/16 and masquerades everything else leaving the pods. A reply from a pod to the BIG-IP's 10.20.0.240 is pod
traffic answering an incoming connection, so the pod sees the BIG-IP's address unchanged (step 4).

### 6. How fast the pool follows Kubernetes

```bash
sed -n '2,13p' demo/k8s-member-watch.sh
```

It prints, about once a second, the Service's ready endpoints (its EndpointSlice) next to the members of CIS's pool on lb-f5a.

```bash
(demo/k8s-member-watch.sh 32 &); sleep 4; kubectl -n web delete pod $(kubectl -n web get pods -o name | head -1 | cut -d/ -f2) --wait=false; sleep 31
(demo/k8s-member-watch.sh 32 &); sleep 4; kubectl -n web scale deploy/whoami --replicas=5; sleep 31
kubectl -n web scale deploy/whoami --replicas=3
```

You should see the pool trail Kubernetes. In my run the deleted pod left the pool about 5 s after the delete (it left the ready endpoints at
once); its replacement, ready 3 s after the delete, joined the pool about 12 s after it was ready. Scaling to five: both new pods were ready at
the same second and joined the BIG-IP 3 s and 12 s later, in two separate AS3 posts.

### 7. What a client sees while a pod goes away

```bash
sed -n '2,8p' demo/k8s-errors.sh
```

pc1 sends 150 requests, one every 0.1 s (about 20 s); 3 s in, one `whoami` pod is deleted. It prints how many answers had each HTTP
code (`000` = no answer: a reset or a timeout).

```bash
demo/k8s-errors.sh
```

Deleting a pod marks its endpoint terminating and sends SIGTERM at the same time. nginx stops at once, while the BIG-IP still sends to
it until CIS posts the change (step 6). In my run, 2 of 150 requests got `000`, the rest `200`. The same test in NodePort mode
(part 22's controller) gave one `000`.

### 8. Version 2: a graceful exit, and the X-Forwarded-For line

```bash
diff k8s/part22/web.yaml k8s/part23/web-v2.yaml | cut -c1-170
```

- `lifecycle.preStop: sleep 15`: on termination, Kubernetes runs the preStop hook first, and nginx gets SIGTERM only after it. The pod
  keeps serving for 15 s, long enough (normally) for CIS to take it out of the pool first.
- `terminationGracePeriodSeconds: 30`: the whole exit, preStop included, must fit in it.
- The answer gains a line `x-forwarded-for: $http_x_forwarded_for` (used in step 12), and the pods get the label `version: v2`.

```bash
kubectl apply -f - < k8s/part23/web-v2.yaml; kubectl -n web rollout status deploy/whoami
sleep 25; demo/k8s-errors.sh
```

Right after the rollout, my run lost 6 of 150 requests, more than without preStop. CIS's log explained it: CIS sends one AS3
declaration at a time, and after the rollout's changes one post took 45 s. The pod deleted during it left the pool only about 37 s
after the delete, longer than its 15 s preStop. Run `demo/k8s-errors.sh` again once the system is quiet (no posts in
`kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=60s`): my run answered 150 of 150. Size the graceful exit for CIS's worst
post, not its typical one.

### 9. A TLS Secret from the lab CA

```bash
echo $S; openssl x509 -in $S/tls/k8s.crt -noout -subject -issuer -ext subjectAltName
```

You should see subject `CN=k8s.f5lab.test`, issuer `CN=f5lab test CA`, and the DNS name k8s.f5lab.test.

The certificate and key go into the cluster as a TLS Secret. kubectl runs inside the control-plane node, so I stream both files into
it, create the Secret, and delete the copies. The key is written with `umask 077` and never leaves the lab server otherwise:

```bash
node k8s-cp sh -c 'cat > /root/k8s.crt' < $S/tls/k8s.crt
node k8s-cp sh -c 'umask 077; cat > /root/k8s.key' < $S/tls/k8s.key
kubectl -n web create secret tls k8s-tls --cert=/root/k8s.crt --key=/root/k8s.key
node k8s-cp rm -f /root/k8s.crt /root/k8s.key
kubectl -n web describe secret k8s-tls | tail -5
```

You should see the Secret `k8s-tls`, type `kubernetes.io/tls`, with `tls.crt` and `tls.key`. Stream the files, as above, rather than
`docker cp` to the node's `/tmp`: in these nodes `/tmp` is a separate tmpfs, and a file copied there with `docker cp` was not visible
inside.

### 10. A TLSProfile and a Policy

```bash
cat k8s/part23/tls.yaml k8s/part23/policy.yaml
```

- TLSProfile `k8s-tls`: host k8s.f5lab.test; `termination: edge` (TLS ends on the BIG-IP, the pods get plain HTTP);
  `clientSSL: k8s-tls` with `reference: secret`: CIS reads the Secret of step 9 and sends the certificate and key to the BIG-IP as a
  client-SSL profile.
- Policy `whoami-policy`: `profiles.http: /Common/http-xff`, part 4's HTTP profile that inserts X-Forwarded-For with the client's
  address, so the pods see who called although the BIG-IP source-NATs.
- Both carry `f5cr: "true"`, like every resource CIS should pick up.

```bash
kubectl apply -f - < k8s/part23/tls.yaml; kubectl apply -f - < k8s/part23/policy.yaml
```

Nothing changes on the BIG-IP yet: the VirtualServer does not name them.

### 11. The VirtualServer, version 2

```bash
diff k8s/part22/vs.yaml k8s/part23/vs-tls.yaml
```

Four lines added to part 22's VirtualServer:

- `tlsProfileName: k8s-tls`: HTTPS on 10.20.30.120:443 with the TLSProfile of step 10.
- `httpTraffic: redirect`: port 80 stays, and redirects to HTTPS.
- `waf: /Common/waf-app`: part 16's security policy, already on lb-f5a, attached by CIS.
- `policyName: whoami-policy`: the profiles of step 10.

```bash
kubectl apply -f - < k8s/part23/vs-tls.yaml; sleep 50
kubectl -n kube-system logs deploy/k8s-bigip-ctlr --since=55s | grep -E 'Request|SUCCESS' | cut -c1-150
kubectl -n web get virtualserver whoami
```

You should see one AS3 post and `SUCCESS` (10 s in my run), and the VirtualServer with TLS profile `k8s-tls`, HTTP traffic `redirect`,
10.20.30.120 and status OK.

### 12. The result from pc1

```bash
pc1 'curl -s -m 3 -o /dev/null -w "http: %{http_code} -> %{redirect_url}\n" http://k8s.f5lab.test/'
pc1 'for i in 1 2 3; do curl -s -m 3 https://k8s.f5lab.test/; done'
pc1 'echo | openssl s_client -connect k8s.f5lab.test:443 -servername k8s.f5lab.test 2>/dev/null | grep -E "subject=|issuer=|Verify return"'
pc1 'curl -s -m 3 "https://k8s.f5lab.test/?q=<script>alert(1)</script>"'; echo
demo/k8s-errors.sh https://k8s.f5lab.test/
```

You should see:

- HTTP: a `302` redirect to HTTPS.
- HTTPS: answers from the pods without `-k`. curl verified the certificate against the lab CA, and `openssl s_client` shows subject
  k8s.f5lab.test, issuer `f5lab test CA` and a verify return code of 0.
- Each answer shows `client seen: 10.20.0.240` (the SNAT) and `x-forwarded-for: 10.10.0.11`, pc1's address, inserted by `http-xff`.
- The script injection gets the WAF's "Request Rejected" page with a support ID: `waf-app` is blocking.
- The pod deletion test of step 7, now over HTTPS (I did not note its result: compare with step 8).

### 13. What CIS built on lb-f5a

```bash
f5 "tmsh -c 'cd /f5lab_k8s; list ltm recursive one-line' | grep -E '^ltm (virtual |pool|monitor|policy|profile)' | cut -c1-140"
f5 'tmsh list ltm virtual /f5lab_k8s/Shared/crd_10_20_30_120_443 destination profiles policies source-address-translation { type }'
f5 "tmsh -c 'cd /f5lab_k8s; list sys file ssl-cert recursive one-line' | cut -c1-140"
```

You should see, in `/f5lab_k8s/Shared`, after one post:

- a second virtual server `crd_10_20_30_120_443` on 10.20.30.120:443;
- a client-SSL profile `crd_10_20_30_120_443_tls_server`, its certificate `k8s-tls-clientside-crd_10_20_30_120_443_0.crt` from the
  Secret;
- two LTM policies controlling ASM, `_WAF_crd_10_20_30_120_80` and `_WAF_crd_10_20_30_120_443`;
- a forwarding policy `crd_10_20_30_120_443_k8s_f5lab_test_policy`;
- the pool with the pod members and the HTTP monitor.

On the 443 virtual server: the client-SSL profile (client side), `websecurity` and `ASM_waf-app`, `http-xff` (from the Policy),
`f5-tcp-progressive`, both policies, SNAT automap. The 80 virtual server has the WAF policy and the same profiles.

### 14. Readiness: a pod that fails its probe

```bash
kubectl -n web get deploy whoami -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'; echo
```

The probe: `GET /health` on port 80 every 5 s (failure threshold: Kubernetes' default, 3).

```bash
(demo/k8s-member-watch.sh 40 &); sleep 3; kubectl -n web exec $(kubectl -n web get pods -o name | head -1) -- rm /www/health; echo "$(date +%T) /health removed"; sleep 39
kubectl -n web get pods -o wide
kubectl -n web exec $(kubectl -n web get pods -o name | head -1) -- sh -c 'echo OK > /www/health'; sleep 25; kubectl -n web get pods
```

You should see the pod leave the ready endpoints about 17 s after `/health` was removed, and leave the BIG-IP pool in the same sample
of the watch. The pod stays `Running` (0/1 ready): it is not restarted, it just gets no traffic. With `/health` back, it is 1/1 again.

### 15. Persistence now pins a client to one pod

```bash
f5 'tmsh list ltm virtual /f5lab_k8s/Shared/crd_10_20_30_120_443 persist'
pc1 'rm -f /tmp/jar; for i in 1 2 3 4 5; do curl -s -m 3 -c /tmp/jar -b /tmp/jar https://k8s.f5lab.test/ | head -1; done; grep -o "BIGipServer.*" /tmp/jar | cut -c1-110'
pc1 'for i in 1 2 3 4 5; do curl -s -m 3 https://k8s.f5lab.test/ | head -1; done'
```

You should see cookie persistence as the default (AS3's `http` template, which the VirtualServer never asked for, as in part 22). With
a cookie jar, all five requests reach the same pod, and the jar holds the `BIGipServer...` cookie, which now encodes a pod. Without the
jar, every request arrives without a cookie and is balanced again.

### 16. A route is configuration too: one deleted by hand

```bash
sed -n '2,3p' demo/k8s-route-watch.sh
```

About every 5 s on lb-f5a, it prints whether CIS's route to k8s-w2's pod network is there, where the BIG-IP would send a packet to a
pod on k8s-w2, and the monitor state of each member.

```bash
f5 'tmsh delete net route /f5lab_k8s/k8s-k8s-w2-10.20.0.33'; echo "$(date +%T) route deleted"; demo/k8s-route-watch.sh 55
```

You should see the route gone and the k8s-w2 pod sent via the default route, then its member marked offline by the monitor. CIS put the
route back by itself, within about 15-25 s in my runs (17 s in the one I recorded), and the member came back. Routes are reconciled;
the pool objects of part 22, step 18 were not (a hand change there lasted until the next post).

### 17. A node out for maintenance, under load

```bash
sed -n '2,4p' demo/k8s-drain.sh
```

pc1 sends 300 HTTPS requests, one every 0.1 s; 3 s in, `kubectl drain k8s-w2` evicts its pods (each with its graceful exit). The script
prints the answers by HTTP code and where the pods ended up, then makes k8s-w2 schedulable again (`kubectl uncordon`).

```bash
demo/k8s-drain.sh
```

You should see all 300 requests answered in my run (the drain took 17 s), where the evicted pods were rescheduled, then k8s-w2
uncordoned.
The pods do not move back by themselves after the uncordon.

## Verify

| Test | What I measured |
|---|---|
| Before cluster mode | pod address via the default route (10.20.30.1); ping 100% loss |
| Cluster mode applied | 3 routes in `/f5lab_k8s` (pod CIDR via node IP); members = pod IPs; ping about 3 ms; 0 Route objects in the AS3 declaration |
| Traffic | pods see 10.20.0.240; 6 requests split 3/3/0 over 3 pods |
| Pool lag | pod deleted: member removed about 5 s later; replacement added about 12 s after ready; scale 3 > 5: +3 s and +12 s, two posts |
| Pod deleted under load (150 requests) | NodePort: 1 x 000; cluster mode, v1: 2 x 000; v2 right after rollout: 6 x 000 (one AS3 post of 45 s); v2 on a quiet system: 150/150 |
| TLS, WAF, Policy | one post (10 s): `crd_10_20_30_120_443`, client-SSL from the Secret, WAF on 80 and 443, redirect; HTTPS verifies with the lab CA; XFF 10.10.0.11; script injection rejected |
| Readiness | `/health` removed: not ready about 17 s later, member gone in the same sample; pod stays Running |
| Persistence | with a cookie: one pod for 5 requests |
| Route deleted by hand | member offline, route restored by CIS within about 15-25 s |
| Node drain (300 HTTPS requests) | 300/300, drain 17 s |

## Gotchas

- **The BIG-IP must route to every pod network.** Here the nodes share the BIG-IP's internal VLAN, so a static route per node works.
  Otherwise you need a tunnel or BGP. `--static-routing-mode` writes routes; it does not make the next hop reachable.
- **`spec.podCIDR` must match the CNI's real ranges.** CIS reads it for the routes. kindnet allocates from it; a CNI that uses its own
  IPAM can disagree, and the routes then point at the wrong node.
- **Switching CIS back to NodePort leaves its routes.** When I applied part 22's `cis.yaml` again, the three routes stayed in
  `/f5lab_k8s`, and I deleted them by hand (see Reset).
- **Partition routes are invisible from `/Common`.** `tmsh list net route` lists only `/Common`; use
  `tmsh -c 'cd /f5lab_k8s; list net route recursive'`.
- **A pool change is as fast as CIS's slowest post.** CIS posts one declaration at a time; one post took 45 s right after a rollout and
  turned a 15 s preStop into lost requests.
- **The key lives in Kubernetes too.** With edge TLS from a Secret, anyone who can read Secrets in `web` has the private key. Anyone who
  can create a VirtualServer in a watched namespace can publish an address on the BIG-IP. Restrict RBAC on Secrets and on the
  `cis.f5.com` resources accordingly.
- **The node's `/tmp` is a tmpfs.** A file copied with `docker cp` into a node's `/tmp` was not visible inside; stream files with
  `node <node> sh -c 'cat > /root/<file>' < <file>`.
- **Defaults you did not write.** As in part 22, AS3's `http` template adds `f5-tcp-progressive` and cookie persistence, which now pins
  a client to one pod.

## End state

- CIS running with `k8s/part23/cis-cluster.yaml` (cluster mode, static routes); on lb-f5a, three routes `k8s-<node>-<node IP>` in
  `/f5lab_k8s`.
- Application v2 (`web-v2.yaml`, 3 replicas, preStop), Secret `web/k8s-tls`, TLSProfile `web/k8s-tls`, Policy `web/whoami-policy`,
  VirtualServer `web/whoami` from `vs-tls.yaml` (status OK).
- On lb-f5a, in `/f5lab_k8s/Shared`: `crd_10_20_30_120_80` (WAF, redirect) and `crd_10_20_30_120_443` (client-SSL from the Secret, WAF,
  `http-xff`), the pool with the pod members, the monitor and the policies. k8s.f5lab.test answers over HTTPS from pc1. Everything from
  parts 1-22 unchanged.

Save it (lb-f5a; the Kubernetes objects live in the cluster, not in the UCS):

```bash
./f5-save.sh lb-f5a
```

## Reset

I did not run these reset commands in my lab as written: check each result. Back to the end of part 22 (NodePort, plain HTTP):

```bash
kubectl apply -f - < k8s/part22/vs.yaml; sleep 20
kubectl apply -f - < k8s/part22/cis.yaml; kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr
kubectl apply -f - < k8s/part22/web.yaml
kubectl -n web delete policy whoami-policy; kubectl -n web delete tlsprofile k8s-tls; kubectl -n web delete secret k8s-tls
```

Applying `web.yaml` over v2 brings back the v1 answer and label. kubectl apply removes fields that were set by an earlier apply and
are missing from the new file, so the preStop and the grace period should go too; check with
`kubectl -n web get deploy whoami -o yaml`. Then remove the routes CIS leaves behind in NodePort mode:

```bash
f5 "tmsh -c 'cd /f5lab_k8s; list net route recursive one-line'"
f5 'tmsh delete net route /f5lab_k8s/k8s-k8s-cp-10.20.0.31 /f5lab_k8s/k8s-k8s-w1-10.20.0.32 /f5lab_k8s/k8s-k8s-w2-10.20.0.33'
```

Or restore the UCS you saved at the start of this part (the end of part 22) on lb-f5a, after the Kubernetes side is back:

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
```

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `pc1`, `node`, `kubectl`.
- `k8s/part23/cis-cluster.yaml`: the CIS controller in cluster mode with static routes.
- `k8s/part23/web-v2.yaml`: the application, version 2 (preStop, grace period, X-Forwarded-For line).
- `k8s/part23/tls.yaml`: the TLSProfile (edge, certificate from the Secret).
- `k8s/part23/policy.yaml`: the Policy with `/Common/http-xff`.
- `k8s/part23/vs-tls.yaml`: the VirtualServer, version 2 (TLS, redirect, WAF, Policy).
- `demo/k8s-member-watch.sh`, `demo/k8s-errors.sh`, `demo/k8s-route-watch.sh`, `demo/k8s-drain.sh`: the measurements.
- `gen.py` `TLS_NAMES` and `secrets-init.sh`: the certificate for k8s.f5lab.test from the lab CA.
- From part 22: `k8s/part22/cis.yaml`, `web.yaml`, `vs.yaml` (compared with `diff`, and used by Reset).
- Not in the repository: the certificate's private key and the lab CA (`$S/tls/`), the CIS password, the Docker images (BUILD.md).
