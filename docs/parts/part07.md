# Part 7: Persistence: source address and cookies

| | |
|---|---|
| Video | [F5 Persistence Explained: Source Address vs Cookie (Part 7)](https://youtu.be/2ewjhrSylmo) (public from 2026-11-21 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-persistence/) (from 2026-11-21 04:00 UTC) |
| Previous / next | [Part 6](part06.md) / [Part 8](part08.md) |

## Goal

I make `vs-web` send each client back to the same server, first by source address, then with a BIG-IP cookie. I read the
persistence records on the box, shrink the timeout and widen the mask to see what they do, drain a member, decode the cookie by hand,
and forge one. Many users behind one address (what a shared NAT looks like to the BIG-IP) show the difference: source address piles
them on one server; cookies spread them. Fallback persistence brings the pile-up back.

## Starting state

- The lab is up and `./validate.sh` passes.
- lb-f5a only, in the end state of [Part 6](part06.md):
  - pool `pool-web`: server1:80, server2:80, server3:80, round robin, ratios 1, monitor `http-app` only, all three members available;
  - nodes server1-3 on the default node monitor; monitors `http-app` and `http-health` exist;
  - virtual server `vs-web` 10.20.30.100:80 with `tcp`, `http-xff`, SNAT pool `snat-web`, pool `pool-web`, **no persistence**
    (`persist none`).
- To get there: the guides of parts 2-6, or restore the UCS saved at the end of part 6 with `./f5-restore.sh lb-f5a <file.ucs>`.

The firewall between the users and the BIG-IP does no NAT. Several "users" on pc1 therefore share one source address, 10.10.0.11:
that is what many users behind one NAT look like to the BIG-IP. pc2 (10.10.0.12) and pc3 (10.10.0.13) are the different-address cases.

## Values used in this part

| Object | Value |
|---|---|
| BIG-IP | lb-f5a, web UI `https://172.21.32.43` (user admin; password: `sudo sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5a.env`) |
| Source-address profile | `persist-src`, parent `source_addr`, defaults kept (timeout 180 s, mask none) |
| Cookie profile | `persist-cookie`, parent `cookie`, method HTTP Cookie Insert, defaults kept (session cookie, timeout 180) |
| Cookie name | `BIGipServerpool-web` (the default: `BIGipServer` + pool name) |
| Clients | pc1 10.10.0.11, pc2 10.10.0.12, pc3 10.10.0.13 (management 172.21.32.111-.113) |
| Member I drain | server2:80 (10.20.0.12) |
| Test VS (refused) | `vs-test` 10.20.30.199:81, tcp only |

## Steps

All commands run on the lab server (root, in the repo folder) unless a step says otherwise. `./demo/users.sh <pc> <users> <requests>
jar|nojar` runs several users on one PC and prints which server answered each request: with `jar` every user keeps its own cookie jar,
like a browser; with `nojar` no cookie is ever sent back.

### 1. Profiles: what vs-web has, and the persistence types

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm virtual vs-web profiles persist fallback-persistence'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm profile http http-xff defaults-from insert-xforwarded-for'
ssh admin@clab-f5-clos-dc-lb-f5a 'for t in source-addr cookie dest-addr hash host msrdp sip ssl universal; do tmsh list ltm persistence $t one-line; done' | awk '{print $3": "$4}'
```

You should see `vs-web` with its `tcp` and `http-xff` profiles and no persistence; `http-xff` is a child of `http` with
`insert-xforwarded-for enabled` (the parent / child model every profile follows); then the built-in persistence profiles of each type.

### 2. Baseline: no persistence

```bash
for pc in pc1 pc2 pc3; do ./demo/users.sh $pc 1 12 nojar; done
```

In my run every PC's 12 requests spread over all three servers. Short runs on one server happen (each TMM keeps its own round-robin
pointer, part 5): a few requests in a row on one server is not persistence.

### 3. Create `persist-src` in the web UI and put it on vs-web

In the web UI of lb-f5a (https://172.21.32.43):

1. Local Traffic > Profiles > Persistence > Create...: Name `persist-src`; Persistence Type **Source Address Affinity**. Keep the
   defaults (timeout 180 seconds, mask none). Finished.
2. Local Traffic > Virtual Servers > `vs-web` > Resources tab: Default Persistence Profile **persist-src** > Update.

### 4. Source address persistence: records

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm virtual vs-web persist'
for pc in pc1 pc2 pc3; do ./demo/users.sh $pc 1 12 nojar; done
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm persistence persist-records' | grep -E 'source-address|Total'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm persistence persist-records client-addr 10.10.0.11 all-properties' | grep -E 'Mode|Value|Age|Node|Pool|Client'
./demo/users.sh pc1 6 3 jar
```

In my run: pc1 > server3, pc2 > server2, pc3 > server1, 12 of 12 each. One record per client address (Mode source-address, Value =
the client IP, the node address, the age). The 6 users on pc1, each with their own cookie jar, all landed on the same server: one
source address, one record.

### 5. Timeout and mask

A 15 s timeout, then a /24 mask; then back to the defaults.

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm persistence source-addr persist-src timeout mask'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm persistence source-addr persist-src timeout 15; tmsh delete ltm persistence persist-records'
./demo/users.sh pc1 1 1 nojar; S=$SECONDS; for i in 1 2 3 4 5; do sleep 3; echo "$((SECONDS-S)) s idle: $(ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm persistence persist-records' | grep -E 'source-address|Total' | grep -c source-address) record(s)"; done
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm persistence source-addr persist-src timeout 180 mask 255.255.255.0; tmsh delete ltm persistence persist-records'
for pc in pc1 pc2 pc3; do ./demo/users.sh $pc 1 4 nojar; done
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm persistence persist-records' | grep -E 'source-address|Total'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm persistence source-addr persist-src mask none; tmsh delete ltm persistence persist-records; tmsh list ltm persistence source-addr persist-src timeout mask'
```

In my run: with timeout 15 the idle record was gone between 13 and 17 s after the last request (the timer counts idle time). With
mask 255.255.255.0 there was ONE record, value 10.10.0.0, and all three PCs went to server2. The last command shows timeout 180 and
mask none again.

### 6. Draining: disabled versus forced offline

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh delete ltm persistence persist-records'
for pc in pc1 pc2 pc3; do ./demo/users.sh $pc 1 4 nojar; done
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web members modify { server2:80 { session user-disabled } }'
for pc in pc1 pc2 pc3; do ./demo/users.sh $pc 1 4 nojar; done; ./demo/users.sh pc1 2 3 jar
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web members modify { server2:80 { state user-down } }'
for pc in pc1 pc2 pc3; do ./demo/users.sh $pc 1 4 nojar; done
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web members modify { server2:80 { session user-enabled state user-up } }'
for pc in pc1 pc2 pc3; do ./demo/users.sh $pc 1 4 nojar; done
```

In my run: pc2 was on server2. With server2 **disabled** (`session user-disabled`), pc2 stayed on it: a client with a persistence
record keeps going to a disabled member, new clients avoid it. With server2 **forced offline** (`state user-down`), pc2 moved to
server1 at once. After re-enabling, pc2 stayed on server1: its record had been rewritten.

### 7. Create `persist-cookie` in the web UI and put it on vs-web

In the web UI of lb-f5a:

1. Local Traffic > Profiles > Persistence > Create...: Name `persist-cookie`; Persistence Type **Cookie**. Keep the defaults (Cookie
   Method HTTP Cookie Insert, default cookie name, cookie encryption disabled). Finished.
2. Local Traffic > Virtual Servers > `vs-web` > Resources tab: Default Persistence Profile **persist-cookie** > Update. This replaces
   `persist-src`.

### 8. Cookie persistence: the header, decoded

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm virtual vs-web persist'
ssh admin@172.21.32.111 'curl -s -D- -o /dev/null http://app.f5lab.test/' | grep -i -E '^(HTTP|x-server|set-cookie)'
./demo/bigip-cookie.py $(ssh admin@172.21.32.111 'curl -s -D- -o /dev/null http://app.f5lab.test/' | grep -i set-cookie | sed 's/.*BIGipServerpool-web=//; s/;.*//')
./demo/users.sh pc1 1 6 nojar; ./demo/users.sh pc1 1 6 jar
ssh admin@172.21.32.111 'curl -s -b /tmp/user1.jar http://app.f5lab.test/' | grep -E '^(server|cookie):'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm persistence persist-records' | grep -E 'source-address|Total'
./demo/users.sh pc1 6 3 jar
```

In my run the header was `Set-Cookie: BIGipServerpool-web=201331722.20480.0000; path=/; Httponly` (server2). The decoder prints:

```text
201331722.20480.0000
  address 201331722 = 0x0C00140A -> bytes reversed -> 10.20.0.12
  port    20480 = 0x5000 -> bytes swapped -> 80
  member  10.20.0.12:80
```

(server1's value is 184554506, server3's 218108938.) Without a cookie jar the requests spread: nothing is sent back. With a jar: 6 of
6 on server2. The whoami page's `cookie:` line shows the cookie reaching the server. There are no persistence records on the box: the
state lives in the client. And the 6 users on pc1 (one address) spread: server2, server3, server1, server1, server3, server1.

### 9. Cookies the BIG-IP did not just give out

A forged cookie, a cookie for a member forced offline, the HTTP profile requirement, and an encrypted cookie.

```bash
ssh admin@172.21.32.111 'for i in 1 2 3 4; do curl -s -H "Cookie: BIGipServerpool-web=218108938.20480.0000" -o /dev/null -w "%header{x-server} " http://app.f5lab.test/; done; echo'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web members modify { server2:80 { session user-disabled state user-down } }'
ssh admin@172.21.32.111 'curl -s -D- -o /dev/null -H "Cookie: BIGipServerpool-web=201331722.20480.0000" http://app.f5lab.test/' | grep -i -E '^(x-server|set-cookie)'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web members modify { server2:80 { session user-enabled state user-up } }'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh create ltm virtual vs-test destination 10.20.30.199:81 ip-protocol tcp profiles replace-all-with { tcp } persist replace-all-with { persist-cookie { default yes } }'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm persistence cookie persist-cookie cookie-encryption required cookie-encryption-passphrase <a-passphrase-of-your-own>'
ssh admin@172.21.32.111 'curl -s -D- -o /dev/null http://app.f5lab.test/' | grep -i -E '^(HTTP|x-server|set-cookie)'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm persistence cookie persist-cookie cookie-encryption disabled cookie-encryption-passphrase none'
```

In my run:
- A hand-made server3 cookie (`218108938.20480.0000`): 4 of 4 requests on server3. The BIG-IP trusts any valid unencrypted value.
- A server2 cookie while server2 was forced offline: answered by server1, with a new `Set-Cookie` value 184554506 (server1).
- `vs-test` was refused: `01070309:3: Cookie persistence requires an HTTP or FastHTTP profile ...`. The BIG-IP must parse HTTP to
  insert or read a cookie. The virtual server is not created.
- With cookie encryption required, the cookie value became opaque (it starts with `!`). Then encryption is switched off again.

### 10. Fallback persistence

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web fallback-persistence persist-src; tmsh delete ltm persistence persist-records; tmsh list ltm virtual vs-web persist fallback-persistence'
./demo/users.sh pc1 4 3 jar
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm persistence persist-records' | grep -E 'source-address|Total'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web fallback-persistence none; tmsh delete ltm persistence persist-records'
./demo/users.sh pc1 4 3 jar
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh save sys config' | tail -1
```

In my run, with fallback `persist-src`: all 4 users on server2. The first request of every new user carries no cookie yet, so it matches
the fallback's source-address record, and all of them get the same server's cookie. Without the fallback: server3, server3, server2,
server1.

## Verify

- Source address: one record per client address; pc1 > server3, pc2 > server2, pc3 > server1, 12 of 12 each.
- Timeout 15: record gone between 13 and 17 s idle. Mask /24: one record, value 10.10.0.0.
- Disabled member keeps persistent clients; forced offline moves them at once.
- Cookie: `Set-Cookie: BIGipServerpool-web=201331722.20480.0000; path=/; Httponly`, decoded to 10.20.0.12:80; jar 6 of 6 on one
  server; no records on the box.
- Six users behind one address: source address put all 6 on one server; cookie spread them over all three (server2, server3,
  server1, server1, server3, server1 in the run in the video; 2 / 2 / 2 in a dry run).
- Cookie + fallback source address: 4 of 4 users on one server again.

## Gotchas

- No persistence still shows short runs on one server (per-TMM round robin). Check the records before you call it persistence.
- source_addr defaults: timeout 180, mask none, mirror disabled, match-across-* disabled, map-proxies enabled.
- The timeout counts idle time: a client that keeps sending keeps its record.
- A mask of 255.255.255.0 turns a whole subnet into one record: everyone in it lands on one server.
- Disabling a member does not drain persistent clients quickly: they keep coming until their record (or cookie) stops matching. Forced
  offline moves them at once, and they stay on the new server after you re-enable it, because the record or cookie is rewritten.
- Right after `user-down` > `user-up` the member may not be marked up yet; a test at that moment moves the client anyway. Wait for the
  member to show available before testing.
- Cookie defaults: insert, expiration 0 (a session cookie), httponly enabled, secure enabled but NOT added on this plain-HTTP virtual
  server, always-send disabled (no new Set-Cookie while the cookie matches), timeout 180.
- An unencrypted cookie reveals the member's address and port, and anyone can forge one for any member. Cookie encryption makes the
  value opaque.
- A garbage cookie value is ignored: the request is load balanced and gets a new cookie.
- Cookie persistence needs an HTTP profile on the virtual server (error 01070309).
- curl without a cookie jar never sends the cookie back, so it looks as if persistence does not work.
- Fallback persistence by source address brings back the shared-NAT pile-up for every new user.
- Expiration `1:0` (one minute) adds an `expires=` attribute about one minute ahead (dry run, not in the video).

## End state

- `vs-web`: persistence `persist-cookie` (default), fallback persistence none; otherwise unchanged (`tcp`, `http-xff`, SNAT pool
  `snat-web`, pool `pool-web`).
- Profiles `persist-src` (timeout 180, mask none) and `persist-cookie` (insert, encryption disabled) exist.
- server2:80 enabled and up. `vs-test` does not exist. Configuration saved.

```bash
./f5-save.sh lb-f5a
```

## Reset

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web members modify { server2:80 { session user-enabled state user-up } }'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web persist none fallback-persistence none'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh delete ltm persistence cookie persist-cookie; tmsh delete ltm persistence source-addr persist-src; tmsh save sys config'
```

Or restore the UCS saved at the end of part 6 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Files used

- `demo/users.sh`: several users on one PC (one source address), each sending N requests; prints which server answered each; `jar` or `nojar`.
- `demo/bigip-cookie.py`: decodes an unencrypted BIG-IP persistence cookie value to the member's address and port.
