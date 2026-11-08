# Part 16: Advanced WAF: protecting the app, from attack to false positive

| | |
|---|---|
| Video | [F5 Advanced WAF Tutorial: Blocking Attacks on a Real Fabric (Part 16)](https://youtu.be/4L4cXzDv3ks) (public from 2026-12-12 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-advanced-waf/) (from 2026-12-12 04:00 UTC) |
| Previous / next | [Part 15](part15.md) / [Part 17](part17.md) |

## Goal

I provision Advanced WAF (the `asm` module) on both units of the HA pair, one unit at a time, while the app keeps answering. I build a
security policy from the Rapid Deployment template, attach it to vs-web, and walk a SQL injection from "passes, not logged" through
transparent mode and staging to a real block with a support ID. Then I hit a false positive and fix it for one parameter only, put the
same policy on HTTPS, measure what the WAF adds per request, and make sure the standby holds the same policy.

## Starting state

- The lab is up and `./validate.sh` passes.
- The end state of part 15 (which is part 14's BIG-IP configuration): the HA pair lb-f5a / lb-f5b in the sync-failover device group
  dg-lb (auto-sync on), vs-web (10.20.30.100:80, pool-web, SNAT snat-web) and vs-web-https (10.20.30.100:443) from the earlier parts,
  and the routed VIP vs-rhi from part 14 (not touched here).
- Both units licensed with **your own registration key, and that licence must include Advanced WAF**. Licensed is not provisioned:
  this part provisions it.
- Units used: both. Part 15 ended with lb-f5b active. I provisioned lb-f5a first while it was standby, then lb-f5a was active for the
  rest of the build (lb-f5b provisioned as the standby, policy built on lb-f5a). The last step fails over to lb-f5b.
- To get here: the guides of parts 13 to 15. If you saved a UCS at the end of part 15 with `./f5-save.sh`, `./f5-restore.sh` puts it
  back.

Save a copy of both units before you start (on the lab server, root, in the repo root; the Reset section uses it):

```bash
./f5-save.sh
```

Most commands run **on the lab server (root, in the repo's `demo` folder, with the helper functions loaded)**. The helpers read
`waf-rest.sh` from the current folder, so start every shell like this:

```bash
cd demo
. ./f5fn.sh
```

The helpers used here (all from `demo/f5fn.sh`):
- `f5 '<cmd>'` / `f5b '<cmd>'` run a command on lb-f5a / lb-f5b (bash as admin, over SSH).
- `pc1 '<cmd>'` runs a command on pc1 (the client).
- `waf <command>` runs `waf-rest.sh` on lb-f5a; `WAFU=lb-f5b waf <command>` runs it on lb-f5b. It talks to the unit's own iControl
  REST on `localhost:8100` with `jq`. tmsh shows very little of an ASM policy, so this is how I read and change it.
- `srvcount <text>` counts the requests containing `<text>` in the access logs of server1-3 (did a request reach the pool?).

## Values used in this part

| Object | Value |
|---|---|
| Module | `asm`, level `nominal` |
| Security policy | `waf-app`, template `POLICY_TEMPLATE_RAPID_DEPLOYMENT`, encoding `utf-8`, active |
| Signature set (from the template) | Generic Detection Signatures (High/Medium Accuracy), 2414 signatures |
| LTM policy | `l7-waf-app`: requires `http`, controls `asm`, rule `default`: `asm enable policy /Common/waf-app` (legacy) |
| Profiles on vs-web, vs-web-https | `websecurity` (the system adds `ASM_waf-app` itself) |
| Security log profile | `Log all requests` (built in) |
| Attack | `http://app.f5lab.test/?id=1%27%20OR%20%271%27=%271` (`id=1' OR '1'='1`) |
| False positive | POST `/ticket`, `note=Please run SELECT name FROM users WHERE id=42 and send me the result` |
| Signature override | parameter `note` (explicit, any location): signature 200002997 disabled |
| Device group | dg-lb, `asm-sync enabled` |

## Steps

### 1. Provision ASM on lb-f5a, the standby

Provisioning a module restarts TMM on that unit, so on a pair the standby goes first while the active unit carries the traffic. Part 15
left lb-f5b active, so lb-f5a goes first. Run a load from pc1 through the active unit while you do it (5 requests a second for 170 s),
provision, and follow ASM's own start-up log (`asm-wait.sh` prints each step of the unit's `/var/log/asm` with the seconds since it
started, until "ASM started successfully"):

```bash
./ha-status.sh
./ha-load.sh 170 /tmp/p16a.log > /tmp/p16a.sum &
f5 'tmsh modify sys provision asm level nominal' && ./asm-wait.sh lb-f5a
```

In my run lb-f5a logged "ASM started successfully" 101 s after the command, and the load through the active unit sent 2343 requests,
0 failed. The evidence from lb-f5a's own logs:

```bash
f5 "grep -h 'modify sys provision asm' /var/log/audit | cut -c1-16; grep -hE 'ASM starting|ASM started successfully' /var/log/asm | cut -c1-16,60-"
```

### 2. Make lb-f5a active, then provision lb-f5b

Make lb-f5b standby (on lb-f5b, the active unit) and check the pair:

```bash
f5b 'tmsh run sys failover standby'
./ha-status.sh
```

Check lb-f5b's memory split before:

```bash
f5b "tmsh show sys provision | grep -E '^ *(Module|asm|host|ltm|tmos) '"
```

Before, on lb-f5b: asm 0, host 1976 MB, tmos 14072 MB.

The load, the provisioning, and the start-up log:

```bash
./ha-load.sh 170 /tmp/p16.log > /tmp/p16.sum &
f5b 'tmsh modify sys provision asm level nominal' && ./asm-wait.sh lb-f5b
```

In my run: "ASM starting" at +83 s, `ASM started successfully` at +98 s.

Check the result and the load:

```bash
f5b "tmsh show sys provision | grep -E '^ *(Module|asm|host|ltm|tmos) '"
f5b 'bigstart status asm dwbld'
f5b "ps -eo etime,args | grep -E '^ *[0-9:]+ ./bd ' | cut -c1-60"
while pgrep -f '[h]a-load.sh 170' >/dev/null; do sleep 1; done; cat /tmp/p16.sum
./ha-status.sh
```

After: asm 3072 MB (plus 4610 MB host memory, 8050 MB disk), host 7166 MB, tmos 5810 MB. `asm` and `dwbld` run, and `bd` (the
process that inspects requests) is up. The memory comes out of TMOS: that is the cost of the module on a VE. The load: 654 requests,
2 failed in my run (see Gotchas).

### 3. Create the policy

tmsh cannot list the policy templates, so I read them from REST:

```bash
waf templates 12
```

Create the policy from Rapid Deployment, in transparent mode (`blocking-mode disabled`), on lb-f5a (the active unit). It takes about 10 s:

```bash
f5 'tmsh create asm policy waf-app policy-template POLICY_TEMPLATE_RAPID_DEPLOYMENT blocking-mode disabled encoding utf-8 active' && f5 'tmsh list asm policy waf-app'
```

What the helper can do (its header), then what the policy holds:

```bash
sed -n '2,22p' waf-rest.sh
waf info
```

You should see: enforcement transparent, template Rapid Deployment, 2414 attack signatures, **all 2414 flagged for staging**, and the
set "Generic Detection Signatures (High/Medium Accuracy)".

### 4. Attach it to vs-web

A policy on its own does nothing. The `websecurity` profile turns the ASM plugin on for the virtual server, and an LTM policy says which
security policy to use:

```bash
f5 'tmsh create ltm policy l7-waf-app strategy first-match requires add { http } controls add { asm } rules add { default { actions replace-all-with { 0 { asm enable policy /Common/waf-app } } ordinal 1 } } legacy'
f5 'tmsh list ltm policy l7-waf-app'
f5 'tmsh modify ltm virtual vs-web profiles add { websecurity } policies add { l7-waf-app }'
f5 'tmsh list ltm virtual vs-web profiles policies'
f5 'tmsh list asm policy waf-app virtual-servers'
```

vs-web now lists a profile I did not add: `ASM_waf-app`. The system adds it. `waf-app` lists vs-web as its virtual server.

### 5. Transparent mode, logging and staging

The attack, with the servers' count before and after:

```bash
srvcount OR%20
pc1 'curl -s "http://app.f5lab.test/?id=1%27%20OR%20%271%27=%271"'
srvcount OR%20
waf log 3; echo "(end of log)"
```

The page comes back from a server, the count goes up, and the event log is empty: the virtual server has no security log profile, so
nothing is logged.

Add "Log illegal requests" and send it again:

```bash
f5 'tmsh modify ltm virtual vs-web security-log-profiles add { "Log illegal requests" }'
pc1 'curl -s -o /dev/null -w "%{http_code}\n" "http://app.f5lab.test/?id=1%27%20OR%20%271%27=%271"'; sleep 5; waf log 3; echo "(end of log)"
```

Still nothing. A match on a **staged** signature does not make a request illegal: its status stays "legal".

Log everything instead:

```bash
f5 'tmsh modify ltm virtual vs-web security-log-profiles replace-all-with { "Log all requests" }'
pc1 'curl -s -o /dev/null -w "%{http_code}\n" "http://app.f5lab.test/?id=1%27%20OR%20%271%27=%271"'; sleep 5; waf log 1
```

You should see the request as `legal` with `VIOL_ATTACK_SIGNATURE`: signatures 200002883 and 200002835 (SQL-INJ expressions like
"OR 1=1", on the parameter `id`), both `STAGED`.

### 6. Blocking: mode, then enforcement

Blocking mode first (the helper patches the mode and applies the policy):

```bash
waf mode blocking
pc1 'curl -s "http://app.f5lab.test/?id=1%27%20OR%20%271%27=%271"' | head -2
```

The attack still reaches the server: every signature is still staged, and a staged signature never blocks.

Take every signature out of staging (PATCH `performStaging false` on all of them), then apply (more than 20 s in my run):

```bash
waf enforce
waf info
```

You should see: 0 staged, 2414 not.

Now the attack, with the servers' count around it, and the event behind the support ID:

```bash
srvcount OR%20
pc1 'curl -s -w "\nHTTP status %{http_code}\n" "http://app.f5lab.test/?id=1%27%20OR%20%271%27=%271"'
sleep 4; waf log 1
waf event $(waf log 1 | grep -o 'support ID [0-9]*' | cut -d' ' -f3)
srvcount OR%20
```

You should see the block page "Request Rejected" with a support ID, and **HTTP status 200**. The servers' count does not move (9 before,
9 after, in my run). `waf event` shows the full request as the WAF saw it and its violations, rating 5.

### 7. More attacks, and a normal request

```bash
pc1 'curl -s -o /dev/null -w "%{http_code} " "http://app.f5lab.test/?q=%3Cscript%3Ealert(1)%3C/script%3E"; curl -s "http://app.f5lab.test/?q=%3Cscript%3Ealert(1)%3C/script%3E" | grep -o "support ID is: [0-9]*"'
pc1 'curl -s --path-as-is "http://app.f5lab.test/static/../../etc/passwd" | grep -o "support ID is: [0-9]*"'
pc1 'curl -s "http://app.f5lab.test/?id=1%2527%2520OR%2520%25271%2527%253D%25271" | grep -o "support ID is: [0-9]*"'
pc1 'curl -s "http://app.f5lab.test/?q=load+balancer" | head -1'
sleep 4; waf log 3
```

In my run: the XSS (`<script>alert(1)</script>` in `q`) blocked with status 200, signatures 200001475, 200000098, 200101609; the path
traversal blocked by 200007029 (on the URI); the double-encoded injection blocked by 200002883 / 200002835. The normal search passes.

### 8. A false positive, and the narrow fix

A support ticket whose text happens to contain SQL words:

```bash
pc1 'curl -s -X POST --data-urlencode "note=Please run SELECT name FROM users WHERE id=42 and send me the result" http://app.f5lab.test/ticket | grep -o "support ID is: [0-9]*"'
sleep 4; waf log 1
```

Blocked by signature 200002997 (SQL-INJ "SELECT FROM WHERE" (Parameter)) on the parameter `note`.

Disabling that signature would remove it from every parameter of the application, and transparent mode would remove all protection.
Instead I add the parameter `note` to the policy (explicit, any location) with that one signature disabled on it, then apply:

```bash
waf override note 200002997
waf params
```

Test it both ways:

```bash
pc1 'curl -s -X POST --data-urlencode "note=Please run SELECT name FROM users WHERE id=42 and send me the result" http://app.f5lab.test/ticket | head -6'
pc1 'curl -s -X POST --data-urlencode "note=1%27 OR %271%27=%271" http://app.f5lab.test/ticket | grep -o "support ID is: [0-9]*"'
pc1 'curl -s -G --data-urlencode "q=SELECT name FROM users WHERE id=42" http://app.f5lab.test/ | grep -o "support ID is: [0-9]*"'
sleep 4; waf log 2
```

You should see: the ticket passes; `OR 1=1` in `note` is still blocked (200002883 / 200002835); the same SELECT text in `q` is still
blocked (200002997).

### 9. HTTPS

On the TLS virtual server the WAF sees the decrypted request (the client SSL profile from part 8 terminates TLS first). Same policy,
same profiles:

```bash
f5 'tmsh modify ltm virtual vs-web-https profiles add { websecurity } policies add { l7-waf-app } security-log-profiles add { "Log all requests" }'
pc1 'curl -sk "https://app.f5lab.test/?id=1%27%20OR%20%271%27=%271" | grep -o "support ID is: [0-9]*"'
sleep 4; waf log 1
```

Blocked, and logged against vs-web-https.

### 10. What the WAF costs per request

`latency.sh` makes pc1 fetch a URL 300 times, one after another, new connection each time, and prints the median, p95 and max of
`time_starttransfer` (request sent to first byte back):

```bash
cat latency.sh | sed -n '2,4p'
./latency.sh 'http://app.f5lab.test/?q=load+balancer'; ./latency.sh 'https://app.f5lab.test/?q=load+balancer'
```

Without the WAF, then with it back:

```bash
f5 'for v in vs-web vs-web-https; do tmsh modify ltm virtual $v policies delete { l7-waf-app } profiles delete { websecurity }; done'
./latency.sh 'http://app.f5lab.test/?q=load+balancer'; ./latency.sh 'https://app.f5lab.test/?q=load+balancer'
f5 'for v in vs-web vs-web-https; do tmsh modify ltm virtual $v profiles add { websecurity } policies add { l7-waf-app }; done'
f5 'tmsh list asm policy waf-app virtual-servers'
```

Medians in my runs (with / without WAF): HTTP 13.38 / 12.84 ms, HTTPS 34.94 / 34.22 ms. Over three rounds the WAF added 0.5-1.5 ms over
HTTP and 0.7-2.6 ms over HTTPS.

### 11. The standby: ASM sync, a full push, and a failover

```bash
./ha-status.sh
f5b 'tmsh list asm policy waf-app 2>&1 | head -3'
f5 'tmsh list cm device-group dg-lb asm-sync'
```

In my run `asm-sync` was disabled on dg-lb, and lb-f5b had the policy object only (the template's state: transparent, all staged).

Enable ASM sync and sync:

```bash
f5 'tmsh modify cm device-group dg-lb asm-sync enabled; tmsh run cm config-sync to-group dg-lb'; sleep 30; ./ha-status.sh
WAFU=lb-f5b waf info
```

Both units say In Sync, but lb-f5b still holds the template's state: enabling ASM sync does not carry the changes made before it. A full
load push does:

```bash
f5 'tmsh run cm config-sync force-full-load-push to-group dg-lb'; sleep 40; ./ha-status.sh
WAFU=lb-f5b waf info; WAFU=lb-f5b waf params | head -1
```

lb-f5b now: blocking, 0 staged, the `note` override.

Fail over under load and send the attack through the new active unit:

```bash
./ha-load.sh 40 /tmp/w16.log > /tmp/w16.sum &
sleep 5; f5 'tmsh run sys failover standby'; sleep 15; ./ha-status.sh
pc1 'curl -s "http://app.f5lab.test/?id=1%27%20OR%20%271%27=%271" | grep -o "support ID is: [0-9]*"'; sleep 4; WAFU=lb-f5b waf log 1
while pgrep -f '[h]a-load.sh 40' >/dev/null; do sleep 1; done; cat /tmp/w16.sum
```

In my run: 154 requests, 0 failed. lb-f5b blocks the attack with its own support-ID range.

## Verify

- `waf info` on both units (`waf info`, `WAFU=lb-f5b waf info`): enforcement blocking, 2414 signatures, 0 staged.
- `waf params` on both: parameter `note`, override 200002997 enabled=false.
- The attack on `http://` and `https://app.f5lab.test/` returns the "Request Rejected" page with a support ID (status 200), and
  `srvcount OR%20` does not change.
- The ticket with SELECT text passes; `OR 1=1` in `note` and the SELECT text in `q` are blocked.
- `./ha-status.sh`: both In Sync, lb-f5b active.
- What I measured: ASM started 98 s / 101 s after the provisioning command; latency +0.5-1.5 ms (HTTP), +0.7-2.6 ms (HTTPS); failover
  under load 154 requests, 0 failed.

## Gotchas

- Provisioning restarts TMM: always the standby first. While lb-f5b was provisioned, 654 requests through lb-f5a, 2 failed (at 151.8 s
  and 161.6 s, about 50 s after ASM was up), with nothing in either unit's logs at those times; not reproduced. I report it as
  unexplained. On lb-f5a: 2343 requests, 0 failed.
- `tmsh` cannot list policy templates and shows little of a policy: use iControl REST (`waf templates`, `waf info`).
- My first policy take overran its wait: the create takes about 10 s; wait for the `tmsh list` output.
- No security log profile on the virtual server = nothing in the event log, whatever happens.
- "Log illegal requests" does not show staged matches: a staged signature match leaves the request "legal". Use "Log all requests" while
  you tune.
- Blocking mode alone blocks nothing while the signatures are staged (all 2414 start staged). Take them out of staging and apply.
- The Rapid Deployment block page comes with **HTTP status 200**: monitoring that counts 4xx/5xx sees no blocks.
- Not every attack is flagged: `?host=8.8.8.8;cat /etc/passwd` was not blocked in my dry run.
- dg-lb had `asm-sync` disabled. Enabling it later did not carry the earlier changes, while both units said In Sync. Check what the peer
  holds (`WAFU=lb-f5b waf info`), not only the sync status. `tmsh run cm config-sync force-full-load-push to-group dg-lb` fixed it. In
  the dry run, that full push under load lost 1 of 229 requests.
- Do not sync `datasync-global-dg` by hand. In my dry run, `tmsh run cm config-sync to-group datasync-global-dg` from the standby
  restarted datasyncd on the active unit; its HA action is "go offline and down links", so the active unit went offline and the standby
  took over.

## End state

- ASM provisioned (nominal) on both units; dg-lb `asm-sync enabled`.
- `waf-app`: blocking, all 2414 signatures enforced, parameter `note` with signature 200002997 disabled; identical on both units.
- `l7-waf-app` LTM policy; vs-web and vs-web-https carry `websecurity`, `l7-waf-app` and the `Log all requests` security log profile.
- lb-f5b active.

Save it for part 17 (from the repo root):

```bash
cd ..
./f5-save.sh
```

## Reset

The UCS restore is the path I tested. I did not run the delete commands below in my lab: check each result.

The simplest way back is the UCS saved before you started: `./f5-restore.sh <unit> <file.ucs>` on each unit (it is saved by
`./f5-save.sh` under `/root/f5-clos-dc-secrets/ucs/`). Then check `tmsh show sys provision`: provisioning is part of the configuration.

By hand: the LTM and ASM objects on the active unit (lb-f5b at the end of this part; auto-sync and ASM sync carry the changes to the
peer):

```bash
f5b 'for v in vs-web vs-web-https; do tmsh modify ltm virtual $v policies delete { l7-waf-app } profiles delete { websecurity } security-log-profiles delete { "Log all requests" }; done'
f5b 'tmsh delete ltm policy l7-waf-app'
f5b 'tmsh delete asm policy waf-app'
f5b 'tmsh modify cm device-group dg-lb asm-sync disabled'
```

Then deprovision ASM unit by unit, standby first (it restarts TMM). With lb-f5b active, lb-f5a goes first:

```bash
f5 'tmsh modify sys provision asm level none'
```

Then fail over (`f5b 'tmsh run sys failover standby'`) and do the same on lb-f5b.

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `f5b`, `pc1`, `waf`, `srvcount`.
- `demo/waf-rest.sh`: Advanced WAF over the unit's local iControl REST (templates, info, enforce, mode, apply, log, event, override, params).
- `demo/asm-wait.sh`: follows ASM's start-up log on a unit after provisioning.
- `demo/ha-load.sh`: pc1 asks the app 5 times a second and reports failures.
- `demo/ha-status.sh`: failover state and sync status of both units.
- `demo/latency.sh`: median / p95 / max time to first byte over 300 sequential requests.
