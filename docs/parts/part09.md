# Part 9: Priority groups, a sorry server and OneConnect

| | |
|---|---|
| Video | [F5 Priority Groups, Sorry Server and OneConnect (Part 9)](https://youtu.be/tMNOjrQ5N10) (public from 2026-11-26 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-priority-groups-oneconnect/) (from 2026-11-26 04:00 UTC) |
| Previous / next | [Part 8](part08.md) / [Part 10](part10.md) |

## Goal
I turn pool-web into a pool with preferred servers and a reserve: priority group activation with a minimum of two active members.
Then I add a sorry server as the last priority group, watch it fail for a reason that has nothing to do with the BIG-IP's pool logic,
and fix it with one SNAT address. I add the HTTP profile's fallback host as the last resort. Finally I put OneConnect on vs-web and
measure what it does to server-side connections.

## Starting state
- The lab is up and `./validate.sh` passes.
- lb-f5a carries the end state of [Part 8](part08.md):
  - vs-web 10.20.30.100:80: profiles tcp and http-xff (X-Forwarded-For insert, header-erase X-Forwarded-For), SNAT pool snat-web
    (10.20.0.201, 10.20.0.202), persistence persist-cookie, pool pool-web.
  - pool-web: server1:80, server2:80, server3:80, round robin, monitor http-app, every member priority group 0,
    min-active-members 0, slow-ramp-time 10.
  - vs-web-https 10.20.30.100:443 (clientssl-app, serverssl-lab, pool-web-https, persist-cookie, SNAT snat-web).
- Only lb-f5a is used. lb-f5b is not touched.
- To get there: the guides of parts 2 to 8. If you saved a UCS at the end of part 8 with `./f5-save.sh`, restore it with
  `./f5-restore.sh lb-f5a <file.ucs>`.

## Values used in this part
| Object | Value |
|---|---|
| Priority groups | server1:80 10, server2:80 10, server3:80 5, sorry-server:80 1 |
| min-active-members (pool-web) | 2 |
| slow-ramp-time (pool-web) | 10 (unchanged default) |
| Node sorry-server | 10.20.30.30 (external VLAN 10.20.30.0/24, gateway 10.20.30.1), container clab-f5-clos-dc-sorry-server |
| snat-web added member | 10.20.30.201 |
| Fallback host (http-xff) | http://sorry.f5lab.test/ |
| Test fallback status code | 503 (removed again) |
| OneConnect profile | built-in `oneconnect` on vs-web |
| Clients | pc1 10.10.0.11 (mgmt 172.21.32.111), pc2 10.10.0.12 (mgmt 172.21.32.112) |

## Steps
All commands run on the lab server (root, in the repo folder). They reach lb-f5a and the PCs over SSH as admin. To keep the lines
short I set two variables first:

```bash
LBA=admin@clab-f5-clos-dc-lb-f5a
PC1=admin@172.21.32.111
```

### 1. Baseline: all members equal
Every member is in priority group 0 and min-active-members is 0, so every request may go to any of the three servers.

```bash
ssh $LBA 'tmsh list ltm pool pool-web min-active-members members' | grep -E "server[0-9]|priority|min-active"
./demo/users.sh pc1 1 12 nojar
```

You should see priority-group 0 on each member, min-active-members 0, and twelve answers spread over server1, server2 and server3.
`nojar` means no cookie is sent back, so persist-cookie does not pin the requests.

### 2. Priority groups: server1 and server2 first, server3 in reserve
The highest priority group with enough available members takes all the traffic. min-active-members 2 means "group 10 needs at
least two available members, otherwise the next group joins".

```bash
ssh $LBA 'tmsh modify ltm pool pool-web min-active-members 2 members modify { server1:80 { priority-group 10 } server2:80 { priority-group 10 } server3:80 { priority-group 5 } }'
ssh $LBA 'tmsh list ltm pool pool-web min-active-members members' | grep -E "server[0-9]|priority|min-active"
./demo/users.sh pc1 1 12 nojar
./demo/users.sh pc2 1 12 nojar
```

You should see: twelve requests from pc1 and twelve from pc2, all on server1 and server2. server3 gets none.

### 3. A failure in the high group
I stop nginx on server1. After the monitor marks it down, group 10 has one available member, which is less than 2, so group 5
(server3) joins. Then I start server1 again and watch when server3 stops getting requests.

```bash
STATUS() { ssh $LBA 'tmsh show ltm pool pool-web members field-fmt' | grep -E "^ +(addr|status.availability-state) " | paste - -; }
docker exec clab-f5-clos-dc-server1 nginx -s stop; sleep 20; STATUS
./demo/users.sh pc1 1 12 nojar
docker exec clab-f5-clos-dc-server1 nginx; sleep 8; ./demo/users.sh pc1 1 12 nojar; sleep 6; ./demo/users.sh pc1 1 12 nojar
```

You should see: server1 offline, and the twelve requests on server2 and server3 only. After server1 returns: 8 s later server3
still serves some requests; 14 s later only server1 and server2 answer. With slow-ramp-time 10, the returning member ramps up, and
the lower group stays active while it does.

### 4. A sorry server as the last priority group
I add the sorry server as a pool member with priority group 1. Its page answers 200, so http-app marks it up. Then I stop all
three web servers, so the sorry server is the only available member.

```bash
ssh $LBA 'tmsh create ltm node sorry-server address 10.20.30.30; tmsh modify ltm pool pool-web members add { sorry-server:80 { priority-group 1 } }'
STATUS
docker exec clab-f5-clos-dc-server1 nginx -s stop; docker exec clab-f5-clos-dc-server2 nginx -s stop; docker exec clab-f5-clos-dc-server3 nginx -s stop; sleep 22; STATUS
ssh $PC1 'curl -sS --max-time 6 http://app.f5lab.test/ 2>&1 | head -2'
```

You should see: all four members available first; after the stop, server1-3 offline and sorry-server available. And yet the
request fails: `curl: (28)` timed out after 6 s, 0 bytes.

Now I look at the sorry server itself:

```bash
docker exec clab-f5-clos-dc-sorry-server tail -3 /var/log/nginx/access.log
docker exec clab-f5-clos-dc-sorry-server traceroute -n -w 1 -q 1 -m 4 10.20.0.201 2>&1 | tail -3
ssh $LBA 'tmsh list sys db connection.vlankeyed' | grep value
```

You should see:
- The sorry server's access log has only monitor probes from 10.20.30.11 (self-external). No user request.
- The traceroute to the SNAT address goes 10.20.30.1, `*`, 10.20.0.201.
- `connection.vlankeyed` value "enable".

The reason: user traffic is SNATed to snat-web, 10.20.0.201/.202, on the internal subnet. The BIG-IP sends the request to the
sorry server out of the EXTERNAL VLAN. The sorry server replies through its gateway 10.20.30.1. The fabric routes 10.20.0.0/24 in
Vrf-App, so the reply reaches the BIG-IP on the INTERNAL VLAN. With VLAN-keyed connections the reply does not match the
server-side flow, which left on external. The request hangs.

### 5. The fix: a SNAT address on the sorry server's subnet
I add 10.20.30.201 to snat-web. The BIG-IP then picks the SNAT address on the egress VLAN's subnet for the sorry member.

```bash
ssh $LBA 'tmsh modify ltm snatpool snat-web members add { 10.20.30.201 }; tmsh list ltm snatpool snat-web'
ssh $PC1 'curl -s http://app.f5lab.test/' | grep -E "^(maintenance|server|client seen|x-forwarded-for):"
```

You should see the red maintenance page from sorry-server, `client seen` 10.20.30.201 and `x-forwarded-for` 10.10.0.11.

Then I start the web servers again:

```bash
docker exec clab-f5-clos-dc-server1 nginx; docker exec clab-f5-clos-dc-server2 nginx; docker exec clab-f5-clos-dc-server3 nginx; sleep 10
ssh $PC1 'for i in 1 2 3 4; do curl -s http://app.f5lab.test/ | grep -E "^(server|client seen):"; done'
```

You should see server1 and server2 answering again, and they still see the internal SNAT addresses 10.20.0.201 / 10.20.0.202.

### 6. Fallback host: the HTTP profile's last resort
When no pool member is available at all, the HTTP profile can answer with a redirect to another site.

```bash
ssh $LBA 'tmsh modify ltm profile http http-xff fallback-host http://sorry.f5lab.test/; tmsh list ltm profile http http-xff fallback-host'
ssh $LBA 'tmsh modify ltm pool pool-web members modify { server1:80 { state user-down } server2:80 { state user-down } server3:80 { state user-down } sorry-server:80 { state user-down } }'
ssh $PC1 'curl -s -D- -o /dev/null http://app.f5lab.test/some/page' | grep -E "^(HTTP|Location)"
ssh $PC1 'curl -s -L http://app.f5lab.test/some/page' | grep -E "^(maintenance|server|host):"
```

You should see `HTTP/1.0 302 Found` and `Location: http://sorry.f5lab.test/`. The original path `/some/page` is not kept.
`curl -L` lands on the sorry page with `host: sorry.f5lab.test`.

The fallback host can also replace chosen status codes from a server. I bring every member back, set fallback-status-codes 503,
and make server2 return 503:

```bash
ssh $LBA 'tmsh modify ltm pool pool-web members modify { server1:80 { state user-up } server2:80 { state user-up } server3:80 { state user-up } sorry-server:80 { state user-up } }; tmsh modify ltm profile http http-xff fallback-status-codes replace-all-with { 503 }'
docker exec clab-f5-clos-dc-server2 sh -c 'sed -i "s|location / {|location / { return 503;|" /etc/nginx/http.d/default.conf && nginx -s reload'
ssh $PC1 'for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w "%{http_code} %header{x-server} %header{location}\n" http://app.f5lab.test/; done'
```

You should see 200 from server1, and 302 with Location http://sorry.f5lab.test/ for the requests that server2 answered with 503.

Then I restore server2's page and remove the status codes again:

```bash
docker exec clab-f5-clos-dc-server2 bash /shared/whoami-up.sh >/dev/null 2>&1; ssh $LBA 'tmsh modify ltm profile http http-xff fallback-status-codes none'
```

### 7. OneConnect, before
Without OneConnect, a client connection is tied to the server-side connection it opened. I test one keep-alive client with six
requests, then 30 separate client connections.

```bash
ssh $LBA 'tmsh list ltm virtual vs-web profiles' | grep -E "^        [a-z]"
ssh $PC1 'curl -s -o /dev/null -w "%{num_connects} %header{x-server}\n" "http://app.f5lab.test/[1-6]"' | tr "\n" " "; echo
ssh $LBA 'tmsh reset-stats ltm pool pool-web; tmsh reset-stats ltm virtual vs-web'; ssh $PC1 'for i in $(seq 30); do curl -s -o /dev/null http://app.f5lab.test/; done'; sleep 5; ssh $LBA 'tmsh show ltm virtual vs-web field-fmt' | grep clientside.tot-conns; ./demo/pool-count.sh
```

You should see: profiles http-xff and tcp. The keep-alive client: six requests, all server1 (one connection). 30 client
connections: 30 server-side connections, 15 on server1 and 15 on server2 (server3 is in the reserve group).

### 8. Add OneConnect in the web UI
In the web UI of lb-f5a (https://172.21.32.43): Local Traffic > Virtual Servers > vs-web. On the Properties page: OneConnect
Profile: oneconnect; Update.

The same in tmsh:

```bash
ssh $LBA 'tmsh modify ltm virtual vs-web profiles add { oneconnect }'
```

### 9. OneConnect, after
The same two tests, then the profile's statistics and settings.

```bash
ssh $LBA 'tmsh list ltm virtual vs-web profiles' | grep -E "^        [a-z]"
ssh $PC1 'curl -s -o /dev/null -w "%{num_connects} %header{x-server}\n" "http://app.f5lab.test/[1-6]"' | tr "\n" " "; echo
ssh $LBA 'tmsh reset-stats ltm pool pool-web; tmsh reset-stats ltm virtual vs-web'; ssh $PC1 'for i in $(seq 30); do curl -s -o /dev/null http://app.f5lab.test/; done'; sleep 5; ssh $LBA 'tmsh show ltm virtual vs-web field-fmt' | grep clientside.tot-conns; ./demo/pool-count.sh
ssh $LBA 'tmsh show ltm profile one-connect oneconnect' | grep -E "Current Idle|Total Reuses"
ssh $LBA 'tmsh list ltm profile one-connect oneconnect all-properties' | grep -E "source-mask|max-age|max-reuse|max-size|idle-timeout"
```

You should see: oneconnect in the profile list. The keep-alive client: the six requests alternate between server2 and server1 on
one client connection. 30 client connections: only 8 server-side connections, 4 on server1 and 4 on server2. The profile settings:
source-mask any, max-age 86400, max-reuse 1000, max-size 10000, idle-timeout-override disabled.

### 10. Check the end state and save

```bash
ssh $LBA 'tmsh list ltm pool pool-web min-active-members slow-ramp-time members' | grep -E "server[0-9]|sorry|priority|min-active|slow-ramp"
STATUS
ssh $LBA 'tmsh save sys config' | tail -1
```

You should see priority groups 10 / 10 / 5 / 1, min-active-members 2, slow-ramp-time 10, all four members available.

## Verify
- Priority groups: 12 + 12 requests from pc1 and pc2 on server1 and server2 only.
- server1 down: requests on server2 and server3. server1 back: server3 still served 8 s later, not 14 s later.
- Sorry server without the fix: available, yet `curl (28)` timed out; its log only shows monitor probes from 10.20.30.11.
- Sorry server with 10.20.30.201 in snat-web: the maintenance page, `client seen` 10.20.30.201, `x-forwarded-for` 10.10.0.11.
- Fallback host: `HTTP/1.0 302 Found`, `Location: http://sorry.f5lab.test/`.
- OneConnect: 30 client connections became 30 server-side connections without it (15 + 15) and 8 with it (4 + 4).

## Gotchas
- A sorry server on a different VLAN than the SNAT addresses times out, even though the BIG-IP shows it available. The monitor
  works (it comes from self-external 10.20.30.11), user traffic does not (its SNAT address is internal and the reply comes back on
  the internal VLAN; `connection.vlankeyed` is enable). Fix: a SNAT pool address on the sorry server's subnet (10.20.30.201).
- The fallback host redirect does not keep the original path: `/some/page` became `http://sorry.f5lab.test/`.
- OneConnect counters lag a few seconds after a burst. An immediate read showed 22-24 for 30 connections. Read the pool and virtual
  server statistics after `sleep 5`.
- The profile's Current Idle count includes connections left from earlier tests. In one run I read Current Idle 8 and Total Reuses
  21 right after the 30-connection test; in another, 18 idle connections.
- slow-ramp-time and priority groups interact: with slow-ramp-time 10, server3 still got requests about 8 s after server1 returned
  (gone by about 13 s). With slow-ramp-time 0, server3 got none 8 s after server1 returned.
- OneConnect changes when decisions are made: every request on a client connection is load balanced on its own. Test it with your
  application before you switch it on.

## End state
lb-f5a:
- pool-web: server1:80 and server2:80 priority group 10, server3:80 priority group 5, sorry-server:80 priority group 1,
  min-active-members 2, slow-ramp-time 10, round robin, monitor http-app.
- Node sorry-server 10.20.30.30.
- snat-web: 10.20.0.201, 10.20.0.202, 10.20.30.201.
- http-xff: fallback-host http://sorry.f5lab.test/, no fallback status codes.
- vs-web: profiles tcp, http-xff, oneconnect; SNAT pool snat-web; persistence persist-cookie; pool pool-web.
- vs-web-https unchanged from part 8.
- Configuration saved.

Save a UCS for the next part:

```bash
./f5-save.sh lb-f5a
```

## Reset
Restore the UCS saved at the end of part 8 (`./f5-restore.sh lb-f5a <file.ucs>`), or remove this part's changes in this order
(in tmsh on lb-f5a):

```bash
tmsh modify ltm virtual vs-web profiles delete { oneconnect }
tmsh modify ltm profile http http-xff fallback-host none
tmsh modify ltm pool pool-web members delete { sorry-server:80 }
tmsh delete ltm node sorry-server
tmsh modify ltm snatpool snat-web members delete { 10.20.30.201 }
tmsh modify ltm pool pool-web min-active-members 0 members modify { server1:80 { priority-group 0 } server2:80 { priority-group 0 } server3:80 { priority-group 0 } }
tmsh save sys config
```

## Files used
- `demo/users.sh`: several users on one PC send requests to the VIP and print which server answered.
- `demo/pool-count.sh`: server-side connections per pool member since the last reset-stats (total and peak).
