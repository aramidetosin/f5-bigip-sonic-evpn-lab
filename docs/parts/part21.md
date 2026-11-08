# Part 21: AS3: declaring BIG-IP configuration as code

| | |
|---|---|
| Video | [F5 AS3 Explained: BIG-IP Configuration as Code (Part 21)](https://youtu.be/rfPtbYQP4Hc) (public from 2026-12-24 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-as3/) (from 2026-12-24 04:00 UTC) |
| Previous / next | [Part 20](part20.md) / [Part 22](part22.md) |

## Goal

I take part 3's application (a pool of server1-3, an HTTP monitor, a virtual server with SNAT), built there by hand with a dozen tmsh
commands, and declare it as one JSON file with AS3 (F5 Application Services 3 Extension). I install AS3 on lb-f5a through the
BIG-IP's package-management API, then send the declaration into its own partition and watch what AS3 does with it: validation before
anything changes, the first deploy, a repeat that changes nothing, a hand change undone by the next post, a new version applied as a
difference, the defaults AS3 chose for me, a dry-run plan, an asynchronous rollback, what `updateMode` does to tenants a declaration
leaves out, and one DELETE that removes all of it.

The numbers below are from my runs. Yours will differ (deploy times, how many times the async task reports "in progress").

## Starting state

- The lab is up and `./validate.sh` passes. The AS3 name is part of the lab: `gen.py` `AS3` (as3.f5lab.test, 10.20.30.110,
  tenant `f5lab_as3`, AS3 3.56.0; `shared/as3-values.sh`); the PCs have the name in `/etc/hosts` (`shared/pc-up.sh`).
  10.20.30.110 is in the published 10.20.30.0/24 (part 3's BASIC VIPs), so the fabric and the firewall need no change.
- The end state of part 20. What this part uses: lb-f5a with part 3's `vs-web` (10.20.30.100:80 > `pool-web`) and part 6's monitor
  `/Common/http-app`. AS3 is not installed. Nothing in this part touches `vs-web`, `/Common`, the anycast, RHI or GSLB configuration.
- Units used: lb-f5a only (`F5U=lb-f5b ./as3.sh ...` would target lb-f5b). To get here: the guide of part 20, or restore the UCS you
  saved at its end with `./f5-restore.sh`. Save lb-f5a before you start (`./f5-save.sh`).
- The AS3 RPM on the lab server (it is F5's binary, not in this repository): see step 2.

Every command runs **on the lab server (root, in the repo's `demo` folder, with the helper functions loaded)**:

```bash
cd demo
. ./f5fn.sh
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` runs a command on lb-f5a (bash as admin); `pc1 '<cmd>'` runs it on pc1.

`demo/as3.sh <command>` does every AS3 call. Each one is plain `curl` run on the BIG-IP itself, to the BIG-IP's own REST API
(`http://localhost:8100/mgmt`, restjavad, no TLS) as the admin user:

| Command | What it sends |
|---|---|
| `install` | `scp` the RPM from `/root/as3` to the BIG-IP's `/var/config/rest/downloads/`, then `POST /mgmt/shared/iapp/package-management-tasks` with `{"operation":"INSTALL","packageFilePath":...}`; polls the task until FINISHED, then waits until AS3 answers |
| `info` | `GET /mgmt/shared/appsvcs/info` |
| `post <file>` | `POST /mgmt/shared/appsvcs/declare` with the file; prints each tenant's result (message, HTTP code, run time) |
| `get` | `GET /mgmt/shared/appsvcs/declare`: the declaration AS3 holds now |
| `delete <tenant>` | `DELETE /mgmt/shared/appsvcs/declare/<tenant>` |
| `plan <file>` | the same POST with `"controls": {"class": "Controls", "dryRun": true, "traceResponse": true}` added; prints the planned changes |
| `async <file>` | `POST /mgmt/shared/appsvcs/declare?async=true`, then polls `GET /mgmt/shared/appsvcs/task/<id>` |
| `expanded` | `GET /mgmt/shared/appsvcs/declare?show=expanded`: the held declaration with AS3's defaults filled in |

## Values used in this part

| Object | Value |
|---|---|
| AS3 | 3.56.0, `f5-appsvcs-3.56.0-10.noarch.rpm`, on the lab server in `/root/as3` |
| Name and address | as3.f5lab.test, 10.20.30.110:80 |
| Tenant (partition) | `f5lab_as3`, application `web` (template `http`) |
| Objects | `serviceMain` (Service_HTTP, SNAT auto), `web_pool` (server1-3 10.20.0.11-13:80), `http_app` (HTTP monitor, interval 5 s, timeout 16 s) |
| Declarations | `demo/as3/app-v1.json` (part 3's app), `app-invalid.json`, `app-v2.json`, `app-v3.json`, `app-teamb.json`, `app-v1-complete.json` |
| Second tenant (step 14) | `f5lab_teamb`, application `shared`, `api_pool` (10.20.0.11-12:8080, monitor `/Common/http-app`) |

## Steps

### 1. Where part 20 left lb-f5a

```bash
f5 'tmsh list ltm virtual vs-web destination pool; tmsh list auth partition | grep partition'
f5 'curl -s -o /dev/null -w "AS3 info: HTTP %{http_code}\n" -u admin: http://localhost:8100/mgmt/shared/appsvcs/info'
pc1 'getent hosts as3.f5lab.test'
```

You should see `vs-web` (10.20.30.100:80, `pool-web`), one partition (`Common`), `AS3 info: HTTP 404` (AS3 is not installed), and
as3.f5lab.test resolving to 10.20.30.110 on pc1.

### 2. Get AS3 and install it

AS3 comes from F5's GitHub release v3.56.0:
<https://github.com/F5Networks/f5-appsvcs-extension/releases/tag/v3.56.0>. Download `f5-appsvcs-3.56.0-10.noarch.rpm` and its
published `.sha256` file from that page into `/root/as3` on the lab server, then check the checksum:

```bash
ls -l /root/as3
cat /root/as3/*.sha256
sha256sum /root/as3/f5-appsvcs-3.56.0-10.noarch.rpm
```

The two values must match, and must be
`69a9779a724edb9705ec22eb466f39a34d8facbc2f92336ce4ec088296d3530d`. Do not install a file that does not match.

Installing it is two steps. First copy the RPM to the BIG-IP's REST downloads folder; then ask the package-management API to install
it. That is what `./as3.sh install` runs; by hand it is:

```bash
scp /root/as3/f5-appsvcs-3.56.0-10.noarch.rpm admin@clab-f5-clos-dc-lb-f5a:/var/config/rest/downloads/
f5 'curl -s -u admin: -H Content-Type:application/json -X POST http://localhost:8100/mgmt/shared/iapp/package-management-tasks -d "{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/f5-appsvcs-3.56.0-10.noarch.rpm\"}"'
# then GET .../package-management-tasks/<id> until "status": "FINISHED", and GET /mgmt/shared/appsvcs/info
```

I used the helper, which does the same and waits for each stage:

```bash
./as3.sh install
f5 "curl -s -u admin: http://localhost:8100/mgmt/shared/iapp/global-installed-packages | jq -r '.items[].packageName'"
```

You should see `install task <id>`, `task status: FINISHED`, then `AS3 answers: {"version":"3.56.0","release":"10",...}`. The
installed packages are `f5-appsvcs-3.56.0-10` and `f5-service-discovery-1.24.0-7`: the install adds the service-discovery package
too (AS3 uses it to take pool members from outside sources).

### 3. The declaration

```bash
cat as3/app-v1.json
```

Part 3's application, as data. From the outside in:

- `"class": "AS3"`, `"action": "deploy"`: the request. `"declaration"` with `"class": "ADC"` is the BIG-IP configuration;
  `schemaVersion` 3.56.0 is the schema it is written against, `id` and `label` are mine.
- `"f5lab_as3": {"class": "Tenant"}`: a tenant is a BIG-IP partition that AS3 creates and owns.
- `"web": {"class": "Application", "template": "http"}`: an application (a folder in the partition). The `http` template means its
  main service is an HTTP virtual server.
- `serviceMain` (`Service_HTTP`): the virtual server on 10.20.30.110:80, pool `web_pool`, `"snat": "auto"` (automap, as in part 3).
- `web_pool` (`Pool`): round robin, server1-3 on port 80, monitored by `http_app` (`"use"` points at an object in the same application).
- `http_app` (`Monitor`): HTTP, the send string with Host as3.f5lab.test, receive `200 OK`, interval 5 s, timeout 16 s.

### 4. What the helper sends

`as3.sh` is the only tool in this part; read it before you use it:

```bash
sed -n '2,8p;11p;18,22p' as3.sh
```

Every call is `curl -s -u admin: -H Content-Type:application/json` on the BIG-IP to `http://localhost:8100/mgmt/...`: POST to
`/shared/appsvcs/declare` deploys, GET reads, DELETE `/shared/appsvcs/declare/<tenant>` removes. It authenticates as admin because AS3
refuses anonymous calls: `restcurl` on the box (which calls anonymously) got 404 "URI path /shared/appsvcs/info not registered".

### 5. Validation: a broken declaration

```bash
diff as3/app-v1.json as3/app-invalid.json
./as3.sh post as3/app-invalid.json
f5 'tmsh list auth partition f5lab_as3'
```

The only real difference is the missing `"template": "http"` line (the rest of the diff is layout). You should see HTTP 422,
"declaration is invalid", `serviceMain/class: should be equal to constant Service_Generic`: without a template the application
defaults to `generic`, which accepts only a `Service_Generic`. And the partition does not exist: the declaration was rejected whole,
before anything was changed.

### 6. Deploy

```bash
./as3.sh post as3/app-v1.json
f5 'tmsh list auth partition f5lab_as3; tmsh list ltm virtual /f5lab_as3/web/serviceMain'
f5 "tmsh show ltm pool /f5lab_as3/web/web_pool members field-fmt | grep -E 'members |availability'; tmsh list ltm monitor http /f5lab_as3/web/http_app interval timeout recv"
pc1 'for i in 1 2 3 4 5 6; do curl -s http://as3.f5lab.test/ | head -1; done'
```

You should see `f5lab_as3` `success`, code 200, with a run time (1,187 ms in my run). The partition exists (its description says AS3
updated it); the virtual server `/f5lab_as3/web/serviceMain` has 10.20.30.110:80, the pool, SNAT automap, and two things not in the
file: the TCP profile `f5-tcp-progressive` and cookie persistence (step 11). The pool's three members are available, the monitor has
interval 5, timeout 16, recv `200 OK`, and pc1 is answered by server1, server2 and server3. (curl does not return the cookie, so
persistence does not show here.)

### 7. The same declaration again

```bash
./as3.sh post as3/app-v1.json
```

You should see `no change`: AS3 compared the declaration with the box and did nothing.

### 8. A hand change inside AS3's tenant

```bash
f5 'tmsh modify ltm pool /f5lab_as3/web/web_pool load-balancing-mode ratio-member'
f5 'tmsh list ltm pool /f5lab_as3/web/web_pool load-balancing-mode'
./as3.sh post as3/app-v1.json
f5 'tmsh list ltm pool /f5lab_as3/web/web_pool load-balancing-mode'
```

You should see `ratio-member` after the hand change; then the unchanged declaration returns `success` (not "no change": AS3 found a
difference), and the pool is `round-robin` again. The hand change is gone, with no warning.

### 9. Version 2: change the file, not the box

```bash
diff as3/app-v1.json as3/app-v2.json
./as3.sh post as3/app-v2.json
f5 "tmsh list ltm pool /f5lab_as3/web/web_pool load-balancing-mode members | grep -E 'mode|address'"
pc1 'for i in 1 2 3 4 5 6; do curl -s http://as3.f5lab.test/ | head -1; done'
```

Version 2 changes the pool to `least-connections-member` and removes server3 (the rest of the diff is layout). You should see
`success`; the pool with `least-connections-member` and members 10.20.0.11 and 10.20.0.12 only; and pc1 answered by server1 and
server2 only. Only the pool changed.

### 10. Where AS3 keeps its declarations

```bash
./as3.sh get | head -24
f5 "tmsh list ltm data-group internal one-line | grep -o '____appsvcs_declaration-[0-9]*'"
f5 "grep -h 'appsvcs_declaration' /var/log/audit | grep -E 'cmd_data=(create|delete)' | tail -2 | grep -o 'cmd_data=[a-z]* ltm data-group internal [^ ]*'"
```

You should see the declaration AS3 holds (version 2, as posted); internal data-groups `/Common/____appsvcs_declaration-<epoch ms>`,
one per deploy, the last four kept (I had four); and in the audit log, the last deploy creating a new one and deleting the oldest.

### 11. The defaults AS3 chose

```bash
./as3.sh expanded
f5 'tmsh list ltm virtual /f5lab_as3/web/serviceMain profiles persist'
```

`?show=expanded` returns the held declaration with every default filled in. You should see `profileTCP` `normal`, `profileHTTP`
`basic`, `persistenceMethods` `["cookie"]`, `snat` `auto`; and on the box, the profiles `f5-tcp-progressive` and `http` and
`persist` cookie. The `http` template's defaults are not part 3's settings (part 3 used `/Common/tcp` and no persistence).

### 12. Version 3: match part 3, plan first

```bash
diff <(jq -S . as3/app-v2.json) <(jq -S . as3/app-v3.json)
```

(`jq -S` sorts the keys, so only real differences show.) Version 3 points at existing `/Common` objects instead of AS3's defaults (part 3's TCP profile, part 6's monitor):
`"profileTCP": {"bigip": "/Common/tcp"}`, `"persistenceMethods": []` (no persistence), monitor `{"bigip": "/Common/http-app"}` instead
of its own `http_app`; round robin again, server3 back.

Before applying it, a dry run. `./as3.sh plan` posts the same declaration with a `controls` object, `dryRun` true (validate and
compute, change nothing) and `traceResponse` true (return the differences):

```bash
sed -n '9p;25,27p' as3.sh
./as3.sh plan as3/app-v3.json
f5 'tmsh list ltm virtual /f5lab_as3/web/serviceMain profiles persist; tmsh list ltm pool /f5lab_as3/web/web_pool load-balancing-mode'
```

You should see `dryRun: true` and one line per planned change, `N` new, `E` edit, `D` delete, each with its path: the `http_app`
monitor deleted, the mode edited to round robin, server3 new, cookie persistence and `f5-tcp-progressive` deleted, `/Common/tcp` and
`/Common/http-app` new. On the box nothing changed yet: still cookie persistence, `f5-tcp-progressive`, least connections. Then apply it:

```bash
./as3.sh post as3/app-v3.json
f5 'tmsh list ltm virtual /f5lab_as3/web/serviceMain profiles persist; tmsh list ltm pool /f5lab_as3/web/web_pool load-balancing-mode monitor'
```

You should see `success`; `persist none`, profiles `http` and `tcp`, `round-robin`, monitor `min 1 of { /Common/http-app }`:
exactly the changes the plan listed.

### 13. Asynchronous deploy, and a rollback

A rollback is posting the previous file. Here it goes in asynchronously, the way a pipeline would post: AS3 answers at once with a
task id, and the result is read from the task.

```bash
sed -n '10p;28,29p' as3.sh
./as3.sh async as3/app-v1.json
f5 "tmsh list ltm pool /f5lab_as3/web/web_pool load-balancing-mode monitor members | grep -E 'mode|monitor|address'"
```

You should see `accepted, task <id>`, `in progress` a few times (four in my run), then `success` with code 200; and the pool back at
version 1: round robin, server1-3, monitor `/f5lab_as3/web/http_app`.

### 14. Two tenants, and `updateMode`

A second tenant, as another team would deploy it (`app-teamb.json`: tenant `f5lab_teamb`, one pool):

```bash
./as3.sh post as3/app-v1.json; ./as3.sh post as3/app-teamb.json
f5 'tmsh list auth partition | grep partition'
```

You should see both succeed and three partitions: `Common`, `f5lab_as3`, `f5lab_teamb`. Now post part 21's declaration alone again,
in the default update mode (`selective`):

```bash
./as3.sh post as3/app-v1.json; f5 'tmsh list auth partition | grep partition'
```

You should see `no change`, and `f5lab_teamb` still there: in selective mode a declaration changes only the tenants it names. The same
declaration with one more line, `"updateMode": "complete"`:

```bash
diff <(jq -S . as3/app-v1.json) <(jq -S . as3/app-v1-complete.json)
./as3.sh post as3/app-v1-complete.json
f5 'tmsh list auth partition | grep partition'
```

You should see two results: `f5lab_as3` `no change` and `f5lab_teamb` `success`, which here means removed; the partitions are `Common`
and `f5lab_as3`. In complete mode a declaration describes every AS3 tenant on the device, so any tenant not in it is deleted.

### 15. Delete the tenant

```bash
./as3.sh delete f5lab_as3
f5 'tmsh list auth partition f5lab_as3; tmsh list ltm virtual-address 10.20.30.110'
pc1 'curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://as3.f5lab.test/'
f5 'tmsh list ltm virtual vs-web destination'
```

You should see `success`; the partition and the virtual address 10.20.30.110 not found; pc1 gets `000` (no answer); and part 3's
`vs-web` exactly as it was.

## Verify

| Test | What I measured |
|---|---|
| Install | task FINISHED; `info` 3.56.0; packages f5-appsvcs-3.56.0-10 and f5-service-discovery-1.24.0-7 |
| Declaration without template | HTTP 422 "serviceMain/class: should be equal to constant Service_Generic"; partition not created |
| Deploy v1 | success, HTTP 200, 1,187 ms; three members available; pc1 answered by server1-3 |
| Same file again | no change |
| Hand change (ratio-member), then v1 again | success; pool round-robin again |
| v2 | success; least-connections-member, server1-2 only |
| Stored declarations | four data-groups `____appsvcs_declaration-<epoch ms>`; each deploy creates one and deletes the oldest |
| Defaults (`?show=expanded`) | profileTCP normal (f5-tcp-progressive), profileHTTP basic, persistenceMethods [cookie] |
| Plan for v3 | D http_app, E round-robin, N server3, D cookie, D f5-tcp-progressive, N /Common/tcp, N /Common/http-app; nothing changed |
| v3 | success; persist none, tcp + http, round-robin, monitor /Common/http-app |
| Async rollback to v1 | task id at once, in progress x4, success |
| updateMode selective / complete | f5lab_teamb kept / removed |
| DELETE f5lab_as3 | partition and 10.20.30.110 gone; pc1 000; vs-web unchanged |

## Gotchas

- **AS3 owns its tenants.** A hand change inside an AS3 partition lasts only until the next post: the next deploy puts the declared
  state back, silently. Change the declaration, not the box. Partitions AS3 did not create (`Common` here) are never touched.
- **The template sets the main service's class.** An application with no `template` is `generic` and accepts only `Service_Generic`;
  `Service_HTTP` needs `"template": "http"`. AS3 rejects the whole declaration (HTTP 422) and changes nothing.
- **Defaults you did not write.** The `http` template gave the virtual server `f5-tcp-progressive` and cookie persistence. Check with
  `?show=expanded`, and name the objects you want (`{"bigip": "/Common/..."}`) when they matter.
- **`updateMode: complete` deletes every AS3 tenant not in the declaration.** Keep the default (`selective`) whenever more than one
  team or pipeline declares to the same BIG-IP.
- **Anonymous calls are refused.** `restcurl` on the BIG-IP got 404 "URI path /shared/appsvcs/info not registered"; call the API as an
  authenticated user (here `curl -u admin:` to localhost:8100).
- **The install adds more than AS3.** It also installed `f5-service-discovery-1.24.0-7`, and left files behind in
  `/var/config/rest/downloads`.
- **Listing the virtual server.** `tmsh list ltm virtual ... source-address-translation` on its own is a syntax error; list the whole
  virtual server.

## End state

- AS3 3.56.0 and f5-service-discovery 1.24.0 installed on lb-f5a.
- No AS3 tenant: `f5lab_as3` deleted in step 15, `f5lab_teamb` removed in step 14.
- Part 3's `vs-web` and everything else from parts 1-20 unchanged.

Save it (from the repo root):

```bash
cd ..
./f5-save.sh
```

## Reset

Restore the UCS you saved at the start of this part (the end of part 20) on lb-f5a:

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
```

Or remove what this part left. If a run stopped half way, delete the tenants first (`./as3.sh delete f5lab_teamb`,
`./as3.sh delete f5lab_as3`). Then uninstall the two packages through the same package-management API. I uninstalled both in my lab,
but not with these exact commands: check the result (`./as3.sh info` should then give no version, and the installed-packages call in
step 2 should list neither):

```bash
f5 'curl -s -u admin: -H Content-Type:application/json -X POST http://localhost:8100/mgmt/shared/iapp/package-management-tasks -d "{\"operation\":\"UNINSTALL\",\"packageName\":\"f5-appsvcs-3.56.0-10.noarch\"}"'
f5 'curl -s -u admin: -H Content-Type:application/json -X POST http://localhost:8100/mgmt/shared/iapp/package-management-tasks -d "{\"operation\":\"UNINSTALL\",\"packageName\":\"f5-service-discovery-1.24.0-7.noarch\"}"'
f5 'ls /var/config/rest/downloads'
```

Remove the leftover files you see in `/var/config/rest/downloads` (keep `tmp`).

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `pc1`.
- `demo/as3.sh`: every AS3 call (install, info, post, get, delete, plan, async, expanded).
- `demo/as3/app-v1.json`: part 3's application as a declaration.
- `demo/as3/app-invalid.json`: version 1 without `"template": "http"`.
- `demo/as3/app-v2.json`: least connections, server3 removed.
- `demo/as3/app-v3.json`: matches part 3 (`/Common/tcp`, no persistence, `/Common/http-app`).
- `demo/as3/app-teamb.json`: a second tenant, `f5lab_teamb`.
- `demo/as3/app-v1-complete.json`: version 1 with `"updateMode": "complete"`.
- `shared/as3-values.sh`: the name, address, tenant and AS3 version from `gen.py`.
- Not in the repository: `f5-appsvcs-3.56.0-10.noarch.rpm` (F5's release, step 2), in `/root/as3` on the lab server.
