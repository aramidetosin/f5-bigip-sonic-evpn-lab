# Part 17: Advanced WAF for APIs: a policy from the OpenAPI contract

| | |
|---|---|
| Video | [F5 Advanced WAF for APIs: A Policy From Your OpenAPI File (Part 17)](https://youtu.be/bSC-BC7Ysyg) (public from 2026-12-15 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-waf-for-apis/) (from 2026-12-15 04:00 UTC) |
| Previous / next | [Part 16](part16.md) / [Part 18](part18.md) |

## Goal

I put a small JSON API behind its own virtual server and show that, without a WAF, it accepts calls its description never allows. Then
I build an Advanced WAF policy from the API's OpenAPI file with a declarative import, so the description becomes the allow-list:
undocumented paths and methods, wrong types and bodies that break the JSON schema are blocked, and the documented calls still work.
Then I look at what positive security cannot see (an injection that fits the schema), at API drift (a new endpoint before a new
description), at the policy file as the source of truth, and at what the standby really holds.

## Starting state

- The lab is up and `./validate.sh` passes. The test API is part of the lab: server1-3 run it on port 8080 (`shared/api-up.sh`, started
  by the servers' startup script), and the PCs resolve `api.f5lab.test` to 10.20.30.101. The firewall needs no change: the VIP is in the
  published 10.20.30.0/24 on port 80.
- The end state of part 16: ASM provisioned on both units, dg-lb with `asm-sync enabled`, `waf-app` on vs-web and vs-web-https (not
  changed here), the SNAT pool `snat-web`, and the nodes server1-3 (created in part 3). Your licence must include Advanced WAF.
- Units used: both. All objects are created on lb-f5a, which was the active unit for this whole part in my run (the WAF event log I read
  on lb-f5a held every test request). Part 16 ended with lb-f5b active: make lb-f5a active first (on lb-f5b:
  `tmsh run sys failover standby`) and check with `./demo/ha-status.sh`.
- To get here: the guide of part 16, or restore the UCS you saved at its end with `./f5-restore.sh`.

Most commands run **on the lab server (root, in the repo's `demo` folder, with the helper functions loaded)**. The helpers read
`waf-rest.sh` and the policy files from the current folder, and `POLICY` names the WAF policy the `waf` helper works on:

```bash
cd demo
. ./f5fn.sh
export POLICY=waf-api
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` / `f5b '<cmd>'` run a command on lb-f5a / lb-f5b; `pc1 '<cmd>'` runs it on pc1;
`f5merge <file>` merges a tmsh config file into lb-f5a; `waf <command>` runs `waf-rest.sh` on lb-f5a (`WAFU=lb-f5b waf ...` on lb-f5b);
`wafimport <file.json>` copies a declarative policy file to the unit and imports it; `oapiserve [s]` serves the lab's `shared/` folder
over HTTP on the lab server's management address, 172.21.32.1:8099, so a BIG-IP can fetch the OpenAPI file.

`oapiserve` serves the `shared/` folder of your clone (found from where `f5fn.sh` lives; `up.sh` writes the OpenAPI files there).
172.21.32.1 is the lab server's address on the management network (`MGMT` in `gen.py`, `.1`). To run the same server by hand:
`timeout 2400 python3 -m http.server 8099 --bind 172.21.32.1 -d <repo>/shared &`.

## Values used in this part

| Object | Value |
|---|---|
| API | `api.f5lab.test`, base `/api/v1`, nginx on server1-3 (10.20.0.11-.13) port 8080 |
| Documented (OpenAPI 1.0.0) | GET /health, GET /items, POST /items, GET /items/{id} (`id` integer 1-9999) |
| Schema `Item` | `name` string 1-40, `qty` integer 1-100, both required, `additionalProperties: false` |
| Added in release 1.1 | GET /version (in `openapi-f5lab-api-v1.1.json`) |
| Answered but NOT documented | GET /admin/users, DELETE /items/{n} |
| Monitor | `mon-api`: GET /api/v1/health, Host api.f5lab.test, recv `"status":"ok"`, interval 5, timeout 16 |
| Pool | `pool-api`: server1:8080, server2:8080, server3:8080 |
| Virtual server | `vs-api` 10.20.30.101:80, `http`, `tcp`, SNAT pool `snat-web` |
| WAF policy | `waf-api`, template `POLICY_TEMPLATE_API_SECURITY`, blocking, link to the OpenAPI file |
| LTM policy | `l7-waf-api`: `asm enable policy /Common/waf-api` |
| On vs-api | `websecurity`, `l7-waf-api`, security log profile `Log all requests` |
| OpenAPI file server | http://172.21.32.1:8099 (the lab server's management address) |

## Steps

### 1. The API and its description

The values, how the servers serve the API, and every endpoint straight from server1 (no BIG-IP in the path):

```bash
cat ../shared/api-values.sh
sed -n '3,13p' ../shared/api-up.sh
docker exec clab-f5-clos-dc-server1 sh -c 'for p in health items items/7 version admin/users; do wget -qO- http://10.20.0.11:8080/api/v1/$p; done'
```

Every endpoint answers, including the undocumented admin one. Every answer carries an `X-Server` header with the server's name.

What the OpenAPI file allows:

```bash
jq -c '.paths | to_entries[] | [.key, (.value | keys)]' ../shared/openapi-f5lab-api.json
jq '.components.schemas.Item' ../shared/openapi-f5lab-api.json
```

You should see `/health` get, `/items` get and post, `/items/{id}` get, and the `Item` schema: `name` 1-40 characters, `qty` 1-100,
no other properties.

### 2. The LTM side, and the API with no WAF

```bash
cat api/ltm-api.conf
f5merge api/ltm-api.conf
sleep 12; f5 "tmsh show ltm pool pool-api" | grep -E 'Availability|Current Active Members'
```

You should see `merged ltm-api.conf`, then the pool available with 3 active members.

The test script (13 requests from pc1, one line each: what was sent, the HTTP status, and who answered: a server's `X-Server` or
"BLOCKED" with the support ID):

```bash
sed -n '2,4p' api-tests.sh
./api-tests.sh
```

Without a WAF, all 13 reach a server: `admin/users` 200, `DELETE` 204, `qty 500` 201, the extra property 201, the 200 KB name 201,
the non-JSON body 201, `?q=' OR '1'='1` 200.

### 3. A policy built from the OpenAPI file

The declarative policy is a few lines: a name, the API Security template, blocking mode, and a link to the OpenAPI file. The BIG-IP
fetches the file itself, so serve it first (2400 s covers the rest of the part), then import (REST
`/mgmt/tm/asm/tasks/import-policy`, the file inline):

```bash
cat api/waf-api.json
oapiserve 2400
wafimport api/waf-api.json
```

You should see `import: COMPLETED`.

What it built:

```bash
waf urls
waf info
```

In my run: URLs `GET /health`, `POST /items`, `GET /items`, `GET /items/*` (method-specific, from the file), allowed methods POST GET
HEAD, template API Security, 2414 attack signatures, **all staged**. The import also creates the parameter `id` (integer) and a JSON
profile with the schema.

### 4. Attach it to vs-api

The same two pieces as in part 16 (an LTM policy that enables ASM with this policy, and the `websecurity` profile), plus the log profile:

```bash
f5 'tmsh create ltm policy l7-waf-api strategy first-match requires add { http } controls add { asm } rules add { default { actions replace-all-with { 0 { asm enable policy /Common/waf-api } } ordinal 1 } } legacy'
f5 'tmsh modify ltm virtual vs-api profiles add { websecurity } policies add { l7-waf-api } security-log-profiles add { "Log all requests" }'
sleep 15; ./api-tests.sh
```

You should see the 4 documented calls (GET /items, GET /items/7, POST with qty 3, GET /health) answered by a server, and the other 9
blocked with 403. HEAD /items shows "BLOCKED" without a support ID: a HEAD reply has no body. The API Security template answers with a
JSON body `{"supportID": "..."}` (part 16's Rapid Deployment page came with status 200).

### 5. Why each one was blocked

```bash
waf log 9
```

In my run, none of these is a signature match:

| Request | Violation |
|---|---|
| HEAD /items | VIOL_URL (no HEAD entity for that URL) |
| GET /admin/users | VIOL_URL |
| DELETE /items/3 | VIOL_URL and VIOL_METHOD |
| GET /items/abc | VIOL_PARAMETER_DATA_TYPE |
| POST qty 500 | VIOL_JSON_SCHEMA "Value is greater than maximum at $.qty, expected 100, got 500" |
| POST + role:admin | VIOL_JSON_SCHEMA "Illegal additional property" |
| POST 200 KB name | VIOL_JSON_SCHEMA "Value length is greater than maximum at $.name, expected 40, got 200000" |
| POST not JSON | VIOL_JSON_SCHEMA "Failed to parse" and VIOL_JSON_MALFORMED |
| GET /items?q=... | VIOL_PARAMETER (`q` is not declared) |

### 6. An injection the schema allows

`{"name":"x' OR '1'='1","qty":3}` is a valid `Item`: `name` is a string of 11 characters. Positive security has nothing to object to;
only signatures look inside an allowed value:

```bash
sed -n '2,3p' api-inject.sh
./api-inject.sh
sleep 5; waf log 1
```

You should see the server's `{"result":"created",...}`: it passes (201). The log has it as illegal, but only with an alarm
(VIOL_PARAMETER_VALUE_METACHAR) and signature 200002883 `STAGED`. All signatures are still in staging.

### 7. API drift: a new endpoint before a new description

Release 1.1 of the API (already on the servers) added GET /version. Under the 1.0 policy:

```bash
pc1 'curl -s http://api.f5lab.test/api/v1/version'; echo; sleep 5; waf log 1
```

Blocked: VIOL_URL. The new description, and the policy file that links it:

```bash
diff <(jq -c '.paths | keys' ../shared/openapi-f5lab-api.json) <(jq -c '.paths | keys' ../shared/openapi-f5lab-api-v1.1.json)
diff api/waf-api.json api/waf-api-v1.1.json
```

Re-import with the 1.1 file:

```bash
wafimport api/waf-api-v1.1.json
waf urls
pc1 'curl -s http://api.f5lab.test/api/v1/version'; echo
```

`/version` is now an entity, but the request is **still blocked**: the import does not apply the policy. Apply it (about 70 s in one
run; the helper waits up to 180 s):

```bash
waf apply
pc1 'curl -s http://api.f5lab.test/api/v1/version'; echo
./api-inject.sh
waf info
```

`/version` passes (`{"version":"1.1",...}`). The injection is created again, and `waf info` shows signature staging on again: a
re-import **replaces** the whole policy, so anything changed by hand since the last import (for example a manual signature
enforcement) is gone.

### 8. The policy file as the source of truth

Put the enforcement in the file instead. The only difference is `signature-settings`:

```bash
diff api/waf-api-v1.1.json api/waf-api-v1.1-enforced.json
wafimport api/waf-api-v1.1-enforced.json
waf apply
waf info
```

You should see "signature staging (policy-wide): OFF". With `signatureStaging: false` no signature is staged, whatever its own flag says
(the per-signature `performStaging` flags still read true).

```bash
./api-inject.sh; echo; sleep 5; waf log 1
./api-tests.sh
```

The schema-valid injection is now blocked by 200002883 (enforced). The 13 tests give the same result as in step 4.

### 9. The standby: what ASM sync carried

```bash
./ha-status.sh
WAFU=lb-f5b waf info | head -1; WAFU=lb-f5b waf urls
f5b "grep -h swagger /var/log/asm | tail -2 | cut -c1-16,120-200"
```

In my run both units said In Sync, yet lb-f5b's `waf-api` had only wildcard URLs and signature staging on. Its own log said "Failed to
read swagger file content" and a rollback: when the sync arrived, lb-f5b tried to rebuild the policy from the file and failed. If
lb-f5b took over, the admin endpoint, the DELETE and the oversized bodies would be accepted again.

The fix that worked: import the same file on lb-f5b directly (it fetches the link itself, so `oapiserve` must still be running), and
apply there:

```bash
WAFU=lb-f5b wafimport api/waf-api-v1.1-enforced.json
WAFU=lb-f5b waf apply
WAFU=lb-f5b waf info | head -1; WAFU=lb-f5b waf urls
./ha-status.sh
```

lb-f5b now holds the five URLs of release 1.1 with signature staging off, and the pair is In Sync.

## Verify

- `waf urls` and `WAFU=lb-f5b waf urls`: the same five URLs (GET /health, GET /items, POST /items, GET /items/*, GET /version).
- `waf info` and `WAFU=lb-f5b waf info | head -1`: blocking, template API Security, signature staging (policy-wide) OFF.
- `./api-tests.sh`: the 4 documented calls answered by a server, the other 9 blocked with 403.
- `./api-inject.sh`: blocked (200002883).
- `pc1 'curl -s http://api.f5lab.test/api/v1/version'`: answered by a server.
- `./ha-status.sh`: both units In Sync.

## Gotchas

- Pool members by name: the nodes server1-3 already exist (created in part 3), so `ltm-api.conf` uses `server1:8080` etc. A member
  given by bare IP failed with "cannot use the same IP Address".
- Requests sent 3 s after attaching the log profile were blocked but never stored in the event log (dry run); later ones were. Wait
  (I wait 15 s) before reading the log.
- A HEAD request to a GET-only URL is blocked (no HEAD entity), even though HEAD is an allowed method.
- The import does not apply the policy: run `waf apply` after every import.
- A re-import replaces the policy: manual changes (here, signature enforcement) are lost. Keep every setting in the file
  (`signature-settings`), and treat the file as the source of truth.
- `signatureStaging: false` is policy-wide: the per-signature `performStaging` flags still read true. Read the policy-wide setting
  (`waf info`).
- ASM sync carried a manual edit (`waf enforce`, dry run) to lb-f5b, but not the imports: lb-f5b logged "Failed to read swagger file
  content" and rolled back while every device group said In Sync. A `force-full-load-push` did not fix it; importing the same file on
  lb-f5b directly did. The cause of lb-f5b's failure is unknown: the file was being served, and the web server logged no request from
  lb-f5b at those moments. Deploy a declarative policy to every unit and compare what each unit holds, not only the sync status.
- The JSON schema stops shape and size; it does not stop a malicious value inside an allowed field. That is the signatures' job, and they
  start staged.

## End state

- server1-3 serve the API on port 8080; the PCs resolve `api.f5lab.test` (lab).
- `mon-api`, `pool-api` (server1-3:8080), `vs-api` 10.20.30.101:80 with SNAT pool `snat-web`.
- `waf-api` from `api/waf-api-v1.1-enforced.json`: blocking, signature staging off, five URLs; the same on both units.
- `l7-waf-api`; vs-api carries `websecurity`, `l7-waf-api`, `Log all requests`.
- Part 16's `waf-app` on vs-web and vs-web-https, unchanged. lb-f5a active.

Save it (from the repo root):

```bash
cd ..
./f5-save.sh
```

## Reset

The UCS restore is the path I tested. I did not run the delete commands below in my lab: check each result.

Restore the UCS you saved at the end of part 16 (`./f5-restore.sh <unit> <file.ucs>` on each unit), or delete this part's objects on
lb-f5a (the active unit; auto-sync and ASM sync carry the changes), the virtual server first:

```bash
f5 'tmsh delete ltm virtual vs-api'
f5 'tmsh delete ltm policy l7-waf-api'
f5 'tmsh delete asm policy waf-api'
f5 'tmsh delete ltm pool pool-api'
f5 'tmsh delete ltm monitor http mon-api'
```

Then check that lb-f5b no longer lists the policy (`f5b 'tmsh list asm policy waf-api'`): in this part the two units' copies of
`waf-api` did not always follow ASM sync.

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `f5b`, `pc1`, `f5merge`, `waf`, `wafimport`, `oapiserve`.
- `demo/waf-rest.sh`: Advanced WAF over the unit's local iControl REST (import, urls, info, apply, log).
- `demo/api/ltm-api.conf`: mon-api, pool-api and vs-api, merged with `f5merge`.
- `demo/api/waf-api.json`: the declarative policy linking the OpenAPI 1.0 file.
- `demo/api/waf-api-v1.1.json`: the same, linking the 1.1 file.
- `demo/api/waf-api-v1.1-enforced.json`: the 1.1 policy with `signatureStaging: false`.
- `demo/api-tests.sh`: the 13 test requests from pc1.
- `demo/api-inject.sh`: the schema-valid SQL injection from pc1.
- `demo/ha-status.sh`: failover state and sync status of both units.
