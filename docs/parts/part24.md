# Part 24: the BIG-IP as the front door of an AI inference service

| | |
|---|---|
| Video | [F5 BIG-IP in Front of an AI Inference Fabric on Kubernetes (Part 24)](https://youtu.be/qrujtDtevKM) (public from 2026-12-31 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-ai-inference/) (from 2026-12-31 04:00 UTC) |
| Previous / next | [Part 23](part23.md) / this is the last part |

## Goal

An inference request is one long stream: a prefill, then tokens one by one, holding a GPU slot all the while. I put the BIG-IP in front
of such a service and measure the four jobs the front door has: count open streams, cap them per replica, ease new replicas in, and
drain old ones without cutting answers.

There is **no real model** here. `k8s/part24/llm.yaml` is a stand-in: a shell script in the lab's web image that streams "tokens" as
Server-Sent Events, with 4 "GPU slots" per pod and a cold start. Every timing below is the script's, not a GPU's.

A CIS VirtualServer resource cannot set per-member connection limits or slow ramp; AS3 can. So a second CIS runs in AS3 ConfigMap
mode, for the namespace `ai` only, and the front door is a whole AS3 declaration in a ConfigMap. I change it in four versions:
round robin, least connections, a connection limit of 4 per pod, slow ramp 30 s.

The numbers below are from my runs. Yours will differ.

## Starting state

- The end state of part 23: the first CIS in cluster mode with static routes (its routes to the pod networks are what lets lb-f5a reach
  any pod, including the ones of this part), the BIG-IP user `cis` and its Secret `kube-system/bigip-login`, AS3 3.56.0 on lb-f5a. No namespace
  `ai`, no second CIS, no tenant `f5lab_ai`.
- The name is part of the lab: `gen.py` `AI` (ai.f5lab.test, 10.20.30.130, tenant `f5lab_ai`, namespace `ai`; `shared/ai-values.sh`).
  `shared/pc-up.sh` puts it in the PCs' `/etc/hosts`. On a lab built before this was added, run `python3 gen.py`, then add the line
  `10.20.30.130 ai.f5lab.test` to pc1's `/etc/hosts` (check with `pc1 'grep ai.f5lab /etc/hosts'`). 10.20.30.130 is in the published
  10.20.30.0/24, so the fabric and the firewall need no change.
- Units used: lb-f5a only. Save it before you start (`./f5-save.sh lb-f5a`).

Every command runs **on the lab server, as root, in the repo's root folder, with the helper functions loaded**:

```bash
. demo/f5fn.sh
A=/f5lab_ai/ai/llm_pool      # the front door's pool (step 2)
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` runs a command on lb-f5a (bash as admin); `pc1 '<cmd>'` runs it on pc1; `node <node>
<cmd...>` runs a command inside a Kubernetes node; `kubectl ...` runs kubectl on the control plane; `aistream <url> [from]` sends one
streaming request and prints every event line with a timestamp: from pc1 (default, through the BIG-IP), or from a node such as `k8s-cp`
(straight to a pod). In my recording, `f5` commands end with `2>&1 | grep -v api-status` only to hide a login banner line.

## Values used in this part

| Object | Value |
|---|---|
| Inference stand-in | namespace `ai`, Deployment `llm` (3 replicas, `f5lab/web:1`, busybox httpd CGI on 8080), ConfigMap `llm-cgi` (the scripts) |
| Its behaviour | `GET /cgi-bin/generate?tokens=N`: SSE, prefill 400 ms, a token every 100 ms, then `[DONE]`; `SLOTS=4` (more streams slow every stream on the pod); `WARMUP=60` (3x slower for 60 s after start); `/cgi-bin/stats`; `/health` |
| Removal | preStop waits until the pod's own streams are done (at most 100 s); `terminationGracePeriodSeconds: 120` |
| Smaller pod | `llm-small.yaml`: Deployment `llm-small`, 1 replica, `SLOTS=1`, same `app: llm` label |
| Service | `ai/llm` port 8080, labels `cis.f5.com/as3-tenant: f5lab_ai`, `cis.f5.com/as3-app: ai`, `cis.f5.com/as3-pool: llm_pool` |
| Second CIS | `cis-ai.yaml`: Deployment `kube-system/k8s-bigip-ctlr-ai`, AS3 ConfigMap mode (no `--custom-resource-mode`), `--namespace=ai`, `--bigip-partition=f5lab_ai_cis`, `--pool-member-type=cluster`; same user and Secret as the first CIS |
| Front door | ConfigMap `ai/llm-as3` (labels `f5type: virtual-server`, `as3: "true"`): tenant `f5lab_ai`, application `ai`, `serviceMain` on 10.20.30.130:80, SNAT auto, TCP profile `tcp_stream` (idle timeout 300 s), no persistence, pool `llm_pool` (members port 8080 from the Service), HTTP monitor `/health` |
| Versions | v1 round robin; v2 `least-connections-member`; v3 + `connectionLimit: 4` per member; v4 + `slowRampTime: 30` |
| Helpers | `demo/ai-load.sh`, `demo/ai-watch.sh`, `demo/ai-drain.sh`, `aistream` in `demo/f5fn.sh` |

## Steps

### 1. The stand-in for an inference service

```bash
sed -n '1,6p' k8s/part24/llm.yaml
sed -n '/generate: |/,/stats: |/p' k8s/part24/llm.yaml
```

The `generate` script: one file per active stream in `/tmp/active`; it reads `tokens=N`, sends the SSE headers
(`Content-Type: text/event-stream`), sleeps the prefill, then sends one `data:` event per token with the pod name, the token number and
the number of active streams. Each token waits `TOKEN_MS x ceil(active / SLOTS)`, times 3 while the pod is cold. Last comes
`data: [DONE]`. The rest of the file: the Deployment (env `SLOTS`, `TOKEN_MS`, `PREFILL_MS`, `WARMUP`; the preStop; grace 120 s) and the
Service with the three `cis.f5.com/as3-*` labels (step 2).

```bash
kubectl apply -f - < k8s/part24/llm.yaml; kubectl -n ai rollout status deploy/llm
kubectl -n ai get pods -o wide; kubectl -n ai get svc llm --show-labels
aistream "http://$(kubectl -n ai get pods -o jsonpath='{.items[0].status.podIP}'):8080/cgi-bin/generate?tokens=6" k8s-cp
sleep 55; aistream "http://$(kubectl -n ai get pods -o jsonpath='{.items[0].status.podIP}'):8080/cgi-bin/generate?tokens=6" k8s-cp
```

You should see three `llm` pods and the Service with its labels. The first stream, straight to a pod from k8s-cp while the pod is cold,
shows a token about every 0.3 s; the second, after the 60 s warm-up, about every 0.1 s.

### 2. A second CIS in AS3 ConfigMap mode, and the front door's first version

```bash
diff k8s/part23/cis-cluster.yaml k8s/part24/cis-ai.yaml
```

- Name `k8s-bigip-ctlr-ai`: a second controller beside the first one.
- No `--custom-resource-mode`: CIS reads ConfigMaps labelled `f5type: virtual-server` and `as3: "true"`, each holding a whole AS3
  declaration. For every pool it finds the Service labelled with that tenant, application and pool, and fills the pool's members with
  the Service's ready endpoints (`--pool-member-type=cluster`: pod IP and port).
- `--namespace=ai`: this controller watches only `ai`.
- `--bigip-partition=f5lab_ai_cis`: CIS's own partition. It may not be a tenant in a ConfigMap: CIS refuses it (see Gotchas), so
  the declaration's tenant is `f5lab_ai`.
- No `--static-routing-mode`: the routes to the pod networks already come from the first CIS (part 23).

```bash
kubectl apply -f - < k8s/part24/cis-ai.yaml; kubectl -n kube-system rollout status deploy/k8s-bigip-ctlr-ai
sed -n '/"f5lab_ai"/,$p' k8s/part24/llm-as3-v1.yaml
```

The declaration (version 1): tenant `f5lab_ai`, application `ai` (template `http`), `serviceMain` on 10.20.30.130:80 with pool
`llm_pool`, SNAT auto, the TCP profile `tcp_stream` (idle timeout 300 s: a stream may be silent for a long time), no persistence;
`llm_pool` with `round-robin`, `slowRampTime: 0`, the monitor `llm_health` (`GET /health`, receive `OK`, 5 s / 16 s), and one member
template: port 8080, `serverAddresses: []` (CIS fills them), `connectionLimit: 0` (none).

```bash
kubectl apply -f - < k8s/part24/llm-as3-v1.yaml; sleep 35
kubectl -n kube-system logs deploy/k8s-bigip-ctlr-ai --since=50s | grep -E 'AS3|ERROR' | cut -c1-150
f5 "tmsh list ltm virtual /f5lab_ai/ai/serviceMain destination pool profiles; tmsh list ltm pool $A load-balancing-mode slow-ramp-time members | grep -E 'mode|ramp|[0-9]:[a-z0-9]+ |connection-limit'"
```

You should see CIS post the declaration without an error, and on lb-f5a `serviceMain` on 10.20.30.130:80 with `llm_pool`, the profiles
`tcp_stream` and `http`, and the pool in round robin with the three pod addresses on port 8080 as members.

### 3. One stream through the BIG-IP, then a first load

```bash
aistream 'http://ai.f5lab.test/cgi-bin/generate?tokens=10'
sed -n '2,9p' demo/ai-load.sh
```

You should see the stream arrive event by event through the BIG-IP, from pc1: the full proxy forwards each event as it comes.
`demo/ai-load.sh <streams> [tokens] [spacing_ms]` opens that many streams from pc1, records for each the pod, the time to first token
(TTFT), the total time, the tokens received and whether `[DONE]` arrived, writes one line per stream to `/tmp/ai-load.txt` on pc1, and
prints a summary: streams per pod, TTFT and total (median / max) of the completed streams, and how many did not complete.

```bash
demo/ai-load.sh 6 20
```

You should see six streams of 20 tokens, all completed, over the three pods.

### 4. Round robin or least connections

```bash
demo/ai-load.sh 24 40 200
diff k8s/part24/llm-as3-v1.yaml k8s/part24/llm-as3-v2.yaml
kubectl apply -f - < k8s/part24/llm-as3-v2.yaml; sleep 35; kubectl -n kube-system logs deploy/k8s-bigip-ctlr-ai --since=50s | grep -E 'AS3|ERROR' | cut -c1-150
demo/ai-load.sh 24 40 200
```

Version 2 changes one line: `loadBalancingMode: least-connections-member`. 24 streams of 40 tokens, one every 200 ms, on three equal
pods. My run: round robin 8/8/8, median 7.35 s, max 8.9 s; least connections 10/8/6, median 7.45 s, max 10.7 s. No win for least
connections here: equal pods and evenly spaced arrivals leave nothing to fix, and lb-f5a's four TMMs each decide with their own view
(my explanation, not measured).

### 5. A pod on a smaller GPU

```bash
sed -n '1,2p;/SLOTS/p' k8s/part24/llm-small.yaml
kubectl apply -f - < k8s/part24/llm-small.yaml; kubectl -n ai rollout status deploy/llm-small; sleep 65; kubectl -n ai get pods
demo/ai-load.sh 24 40 200
pc1 'grep small /tmp/ai-load.txt; grep -v small /tmp/ai-load.txt | sort -t= -k3 -n | tail -2'
```

`llm-small` is one more pod with `SLOTS=1` and the same `app: llm` label, so the Service, and the pool, include it. The 65 s wait lets it
warm up. Under least connections it still got 4 of 24 streams, which ran up to 15.6 s against a median of 6.5 s (in the dry run: 5 of
24 and about 19 s, under both methods). The BIG-IP balances connections; it cannot see that a member is slower per connection. The last
line lists the small pod's streams and the two slowest of the others. I did not run it in this exact form: the command in my recording
had a quoting error.

### 6. Admission control: at most 4 streams per pod

```bash
kubectl -n ai scale deploy/llm-small --replicas=0; sleep 40; demo/ai-load.sh 18 40 0
diff k8s/part24/llm-as3-v2.yaml k8s/part24/llm-as3-v3.yaml
kubectl apply -f - < k8s/part24/llm-as3-v3.yaml; sleep 35; kubectl -n kube-system logs deploy/k8s-bigip-ctlr-ai --since=50s | grep -E 'AS3|ERROR' | cut -c1-150
demo/ai-load.sh 18 40 0
pc1 'grep done=no /tmp/ai-load.txt | head -4'
f5 "tmsh show ltm pool $A members field-fmt | grep -E 'addr |serverside.max-conns' | grep -v 'pool '"
```

Version 3: `connectionLimit: 4` on the members, one per GPU slot. 18 streams at once, on the three equal pods. Without a limit: all
served, median 8.7 s (every pod oversubscribed). With the limit: 12 served at a median of 4.7 s, 6 refused within about 40 ms (pod `-`,
no token). The BIG-IP's statistics show a maximum of 4 concurrent connections on every member. AS3 has no queue on connection limit;
a 429 or 503 with Retry-After would need an iRule. Clients should retry a refusal after a short random delay.

### 7. Slow ramp for a new, cold pod

```bash
diff k8s/part24/llm-as3-v3.yaml k8s/part24/llm-as3-v4.yaml
kubectl apply -f - < k8s/part24/llm-as3-v4.yaml; sleep 35; kubectl -n kube-system logs deploy/k8s-bigip-ctlr-ai --since=50s | grep -E 'AS3|ERROR' | cut -c1-150
(demo/ai-load.sh 100 40 450 > /tmp/ramp.txt &); sleep 3; kubectl -n ai scale deploy/llm --replicas=4; sleep 60; cat /tmp/ramp.txt
N=$(kubectl -n ai get pods --sort-by=.metadata.creationTimestamp -o name | tail -1 | sed 's/.*-//'); echo new pod: $N; pc1 "grep ' '$N' ' /tmp/ai-load.txt"
kubectl -n ai scale deploy/llm --replicas=3
```

Version 4: `slowRampTime: 30`: a new member's share of new connections grows over 30 s. 100 streams, one every 450 ms (about ten in
flight), and a fourth pod added 3 s in. If the load is still running after the 60 s sleep, wait and `cat /tmp/ramp.txt` again. My
run: the cold new pod served 7 of 100, each about 3x slower (9 of 100 without slow ramp in the dry run); 26 streams were refused at
about 10 in flight against 12 slots. The limit already caps a cold pod at 4 streams, so slow ramp mattered little here; without a
limit it is the only thing between a cold replica and a flood.

### 8. Watching the open streams per pod

```bash
sed -n '2,3p;6,10p' demo/ai-watch.sh
(demo/ai-load.sh 30 40 300 > /tmp/obs.txt &); sleep 2; demo/ai-watch.sh 12; sleep 8; cat /tmp/obs.txt
```

`demo/ai-watch.sh` prints, about once a second, the open server-side connections (the active streams) on each member of `llm_pool`
and the total. 30 streams, one every 300 ms, under version 4: in my run 11 were refused while the one-second samples never showed more
than 9 open of 12. Most likely the limit is applied per TMM; I did not prove it.

### 9. The finished front door

```bash
f5 "tmsh list ltm pool $A load-balancing-mode slow-ramp-time members monitor | grep -E 'mode|ramp|monitor|[0-9]:[a-z0-9]+ |connection-limit'"
f5 "curl -s -u admin: http://localhost:8100/mgmt/shared/appsvcs/declare/f5lab_ai | jq -c '.f5lab_ai.ai.llm_pool | {loadBalancingMode, slowRampTime, members: [.members[] | {serverAddresses, servicePort, connectionLimit}]}'"
kubectl -n ai get configmap llm-as3 --show-labels; kubectl -n kube-system get deploy | grep bigip
```

You should see `llm_pool` in least connections (member), slow ramp 30, the monitor, and each pod member with connection limit 4; the
declaration CIS posted, with the pod addresses that CIS filled in; the ConfigMap with its two labels; and two controllers,
`k8s-bigip-ctlr` (part 23) and `k8s-bigip-ctlr-ai`.

### 10. Taking a pod away without cutting its streams

```bash
sed -n '2,5p' demo/ai-drain.sh; grep -B1 -A3 'preStop:' k8s/part24/llm.yaml
sleep 30; demo/ai-drain.sh graceful
sleep 40; demo/ai-drain.sh force
```

`demo/ai-drain.sh` sends 9 streams of 200 tokens (about 21 s each) and, 6 s in, deletes the pod with the most active streams: normally
(`graceful`: CIS takes it out of the pool so no new stream goes to it, and its preStop waits for its own streams), or with
`--grace-period=0 --force` (`force`: killed at once, like a crash). The sleeps let the pool settle between runs. My run: graceful, all 9
completed, including the deleted pod's 4; forced, that pod's 3 streams were cut mid-answer (and one more was refused).

## Verify

| Test | What I measured |
|---|---|
| Stand-in | warm 0.1 s per token, cold 0.3 s; one pod: 4 streams x 20 tokens 2.54 s, 8 streams 4.54 s (slots shared) |
| Second CIS | its own partition refused as a ConfigMap tenant; with `f5lab_ai_cis` / `f5lab_ai`: members filled from the Service labels |
| RR vs LC (24 x 40 tokens, 200 ms) | RR 8/8/8, max 8.9 s; LC 10/8/6, max 10.7 s |
| 1-slot pod | LC: 4/24, up to 15.6 s (dry run: 5/24 under RR and LC, about 19 s) |
| 18 at once | no limit: all served, median 8.7 s; limit 4: 12 served, 4.7 s, 6 refused in about 40 ms; max 4 connections per member |
| 30 streams, 300 ms apart | 11 refused while samples showed at most 9 of 12 open |
| Slow ramp 30 s | cold new pod 7/100 (dry run without: 9/100); 26 refused |
| Drain | graceful: 0 of 9 cut; force: 3 cut, 1 refused |

## Gotchas

- **CIS refuses its own partition as a ConfigMap tenant.** With `--bigip-partition=f5lab_ai` and tenant `f5lab_ai` in the ConfigMap,
  CIS logged that its managed partition should not be used in ConfigMaps as a tenant, and posted nothing. Give CIS a partition of its
  own (`f5lab_ai_cis`) and use another name as the tenant.
- **The members come from Service labels.** In ConfigMap mode, CIS fills a pool only from a Service labelled with the matching
  `cis.f5.com/as3-tenant`, `as3-app` and `as3-pool`. The member template's `serverAddresses` stays empty in the file.
- **The BIG-IP sees connections, not tokens.** Least connections counts open streams, which here equal busy slots; it cannot see that a
  member is slower per stream. One pool per capacity class, each with its own limit.
- **A limit refuses; it does not queue.** Over the limit, new streams were refused at once. A 429 / 503 with Retry-After needs an iRule.
- **The limit looks per TMM.** With spaced arrivals, refusals started before all 12 slots were busy (inference, not proven).
- **Timeouts along a stream.** The TCP idle timeout must outlast the longest silence (300 s here); the grace period must outlast the
  longest answer (120 s, preStop at most 100 s).
- **Building the stand-in** (only if you change it): busybox httpd gives CGI scripts a minimal `PATH` (no awk: the script exports
  `PATH`); `usleep` is missing (use `sleep` with fractions); without the `trap ... PIPE HUP`, a client that hangs up leaves its file in
  `/tmp/active` and the preStop waits for nothing; `grep` in a pipe buffers SSE, so token timestamps look bunched (`aistream` reads
  line by line instead).

## End state

- Namespace `ai`: Deployment `llm` (3 replicas), `llm-small` (0 replicas), Service `llm` with the CIS labels, ConfigMap `llm-as3` at
  version 4.
- The second CIS `kube-system/k8s-bigip-ctlr-ai` (ConfigMap mode, partition `f5lab_ai_cis`) beside the first one (part 23).
- On lb-f5a, tenant `f5lab_ai`: `serviceMain` on 10.20.30.130:80, `llm_pool` (least connections, limit 4 per member, slow ramp 30 s,
  the pods as members), monitor `llm_health`, profile `tcp_stream`. Everything from parts 1-23 unchanged.

Save it (lb-f5a; the Kubernetes objects live in the cluster, not in the UCS):

```bash
./f5-save.sh lb-f5a
```

## Reset

I did not run these reset commands in my lab: check each result. Delete the ConfigMap first, so CIS removes the tenant while it still
runs:

```bash
kubectl -n ai delete configmap llm-as3; sleep 30
f5 "tmsh list auth partition | grep -E 'f5lab_ai'"
kubectl delete -f - < k8s/part24/cis-ai.yaml
kubectl delete -f - < k8s/part24/llm-small.yaml
kubectl delete -f - < k8s/part24/llm.yaml
```

Then check lb-f5a for what is left in `f5lab_ai` and `f5lab_ai_cis`, or restore the UCS you saved at the start of this part:

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
```

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `pc1`, `node`, `kubectl`, `aistream`.
- `k8s/part24/llm.yaml`: the inference stand-in (namespace, CGI scripts, Deployment, Service with the CIS labels).
- `k8s/part24/llm-small.yaml`: the one-slot pod.
- `k8s/part24/cis-ai.yaml`: the second CIS, AS3 ConfigMap mode.
- `k8s/part24/llm-as3-v1.yaml` to `llm-as3-v4.yaml`: the front door's four versions.
- `demo/ai-load.sh`, `demo/ai-watch.sh`, `demo/ai-drain.sh`: the load, the open streams per pod, the drain test.
- `gen.py` `AI`; it writes `shared/ai-values.sh`, read by `shared/pc-up.sh` for pc1's `/etc/hosts`.
- From part 23: `k8s/part23/cis-cluster.yaml` (compared with `diff`).
- Not in the repository: the CIS password and the Docker images (BUILD.md).
