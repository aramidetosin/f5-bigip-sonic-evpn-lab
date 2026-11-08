# Part 12: iRules for network engineers

| | |
|---|---|
| Video | [F5 iRules for Network Engineers, Tested on the Wire (Part 12)](https://youtu.be/D5afvw1MLIg) (public from 2026-12-03 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-irules/) (from 2026-12-03 04:00 UTC) |
| Previous / next | [Part 11](part11.md) / [Part 13](part13.md) |

## Goal
I write small iRules and prove each one on the wire: the order of events for one request, header insert and remove seen on both
sides of the proxy, pool selection by URI (and the trap a missing `else` sets without OneConnect), an HTTP to HTTPS redirect, a
maintenance answer from the BIG-IP itself, and what happens when a rule fails. For each, I also show the non-iRule way where one
exists: the HTTP profile, an LTM policy, the built-in redirect rule.

## Starting state
- The lab is up and `./validate.sh` passes.
- lb-f5a carries the end state of [Part 11](part11.md) (the same as part 10's): vs-web 10.20.30.100:80 with profiles tcp,
  http-xff, oneconnect and reqlog-web, SNAT pool snat-web, persist-cookie, pool pool-web (server1-3 and sorry-server with priority
  groups 10 / 10 / 5 / 1), no iRules, no policies. vs-web-https 10.20.30.100:443 from part 8. Part 10's logging objects.
- Used: lb-f5a and pc1. lb-f5b is not touched.
- To get there: the guides of parts 2 to 11, or restore the UCS saved at the end of part 11 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Values used in this part
| Object | Value |
|---|---|
| iRules (loaded from demo/irules/) | ir-events, ir-headers, ir-api-pool, ir-api-noelse, ir-https-redirect, ir-maintenance, ir-broken, ir-badpool |
| Pool | pool-api: server3:80 (10.20.0.13), monitor http-app (deleted at the end) |
| HTTP profile (test) | http-hdr-test, defaults-from http-xff, header-insert `"X-Client-Port: [TCP::client_port]"` (deleted again) |
| LTM policy | pol-api-pool (created as Drafts/pol-api-pool, published; deleted again) |
| Client | pc1 10.10.0.11 (mgmt 172.21.32.111) |
| Server response header | X-Server: <server name> (set by the lab's web servers) |

## Steps
All commands run on the lab server (root, in the repo folder), after loading the shortcuts in `demo/f5fn.sh`:

```bash
. ./demo/f5fn.sh
```

- `f5 <command>` runs a command on lb-f5a (bash, as admin) over SSH.
- `pc1 <command>` runs a command on pc1 over SSH.
- `irule <file.tcl>` wraps the file as `ltm rule <name> { ... }`, named after the file, and loads it with
  `tmsh load sys config merge`. Loading the same file again replaces the rule's text. It prints `loaded ltm rule <name>`.

### 1. Events: what TMM runs for one request
`ir-events` logs one line per event to /var/log/ltm:

```tcl
# ir-events: log every event of one request, in the order TMM runs them
when CLIENT_ACCEPTED {
    log local0. "[IP::client_addr]:[TCP::client_port] to [IP::local_addr]:[TCP::local_port]"
}
when HTTP_REQUEST {
    log local0. "[HTTP::method] [HTTP::host][HTTP::uri]"
}
when LB_SELECTED {
    log local0. "pool member [LB::server addr]:[LB::server port]"
}
when SERVER_CONNECTED {
    log local0. "[IP::local_addr]:[TCP::local_port] to [IP::server_addr]:[TCP::server_port]"
}
when HTTP_RESPONSE {
    log local0. "status [HTTP::status]"
}
when CLIENT_CLOSED {
    log local0. "client connection closed"
}
```

```bash
cat demo/irules/ir-events.tcl
irule demo/irules/ir-events.tcl
f5 tmsh modify ltm virtual vs-web rules { ir-events }
pc1 'curl -s http://app.f5lab.test/' | head -2
f5 tail -n 6 /var/log/ltm
```

You should see six lines `Rule /Common/ir-events <EVENT>: ...` in this order: CLIENT_ACCEPTED (10.10.0.11:port to
10.20.30.100:80), HTTP_REQUEST, LB_SELECTED, SERVER_CONNECTED, HTTP_RESPONSE, CLIENT_CLOSED. In my run server2 answered, and
SERVER_CONNECTED showed the SNAT address 10.20.0.201 with the SAME source port as the client (39376).

### 2. Two requests on one connection, and the rule's statistics
```bash
pc1 'curl -s http://app.f5lab.test/a http://app.f5lab.test/b' | grep -E "^(server|client seen):"
f5 tail -n 10 /var/log/ltm
f5 tmsh show ltm rule ir-events | grep -E 'Event:|Total|Failures|Average'
f5 tmsh modify ltm virtual vs-web rules none; f5 tmsh delete ltm rule ir-events
```

You should see CLIENT_ACCEPTED and CLIENT_CLOSED once, and HTTP_REQUEST, LB_SELECTED, SERVER_CONNECTED and HTTP_RESPONSE twice:
with OneConnect each request is load balanced on its own (/a server1 from 10.20.0.201, /b server2 from 10.20.0.202 in my run).
`show ltm rule` lists per event: priority 500, executions total, failures, aborts and CPU cycles. In my run HTTP_REQUEST averaged
122.2K cycles and CLIENT_ACCEPTED 1.7M (two runs; its first run costs more).

### 3. Insert and remove headers, seen on both sides
`ir-headers` adds two request headers for the server, adds one response header for the client and removes the server's X-Server:

```tcl
# ir-headers: add two request headers for the server, add one response header for the client, remove one
when HTTP_REQUEST {
    HTTP::header insert X-Forwarded-Proto "http"
    HTTP::header insert X-Client-Port [TCP::client_port]
}
when HTTP_RESPONSE {
    HTTP::header insert X-Pool-Member [LB::server addr]
    HTTP::header remove X-Server
}
```

`demo/f5headers.sh` reads a `tcpdump -A` capture and prints, per packet, source > destination and the request line, status line,
Host and every X- header. The filter catches the client and the SNAT range 10.20.0.200/29.

```bash
cat demo/irules/ir-headers.tcl
irule demo/irules/ir-headers.tcl && f5 tmsh modify ltm virtual vs-web rules { ir-headers }
(sleep 3; pc1 'curl -s -o /dev/null http://app.f5lab.test/demo') & f5 "timeout 7 tcpdump -nni 0.0 -A -l 'tcp port 80 and (host 10.10.0.11 or net 10.20.0.200/29)' 2>/dev/null" | ./demo/f5headers.sh
pc1 'curl -s -D - -o /dev/null http://app.f5lab.test/demo' | grep -iE '^(HTTP|x-)'
f5 tmsh modify ltm virtual vs-web rules none; f5 tmsh delete ltm rule ir-headers
```

You should see:
- Client side: the request without the new headers.
- Server side: the request with X-Forwarded-For (from the http-xff profile), then X-Forwarded-Proto and X-Client-Port.
- The server's response with `X-Server: server2`.
- The client's response with `X-Pool-Member: 10.20.0.12` and no X-Server.
- The second curl, seen from pc1, was answered by 10.20.0.11 (X-Pool-Member) in my run.

### 4. The same kind of header from the HTTP profile
The HTTP profile's `header-insert` takes ONE header string, and evaluates an iRule expression inside it. It has no response header
insert.

```bash
f5 tmsh create ltm profile http http-hdr-test defaults-from http-xff header-insert '"X-Client-Port: [TCP::client_port]"'
f5 tmsh list ltm profile http http-hdr-test
f5 tmsh modify ltm virtual vs-web profiles delete { http-xff } profiles add { http-hdr-test }
(sleep 3; pc1 'curl -s -o /dev/null http://app.f5lab.test/demo') & f5 "timeout 7 tcpdump -nni 0.0 -A -l 'tcp port 80 and (host 10.10.0.11 or net 10.20.0.200/29)' 2>/dev/null" | ./demo/f5headers.sh
f5 tmsh modify ltm virtual vs-web profiles delete { http-hdr-test } profiles add { http-xff }; f5 tmsh delete ltm profile http http-hdr-test
```

You should see X-Forwarded-For and `X-Client-Port: 51610` (a real port number) on the server side, and X-Server reaching the client:
the profile cannot remove a response header.

### 5. Pool selection by URI
A new pool with server3 only, and a rule that sends /api/ there:

```tcl
# ir-api-pool: /api/ to pool-api, everything else to pool-web
when HTTP_REQUEST {
    if { [HTTP::path] starts_with "/api/" } {
        pool pool-api
    } else {
        pool pool-web
    }
}
```

```bash
f5 tmsh create ltm pool pool-api members add { server3:80 { address 10.20.0.13 } } monitor http-app
cat demo/irules/ir-api-pool.tcl
irule demo/irules/ir-api-pool.tcl && f5 tmsh modify ltm virtual vs-web rules { ir-api-pool }
pc1 'curl -s http://app.f5lab.test/ http://app.f5lab.test/api/users http://app.f5lab.test/ http://app.f5lab.test/api/orders' | grep -E "^(server|client seen):"
```

You should see, on one client connection: / server1, /api/users server3, / server2, /api/orders server3.

### 6. The missing-else trap
`ir-api-noelse` is the same rule without the `else`:

```tcl
# ir-api-noelse: the same rule without the else (a trap without OneConnect)
when HTTP_REQUEST {
    if { [HTTP::path] starts_with "/api/" } {
        pool pool-api
    }
}
```

```bash
diff demo/irules/ir-api-pool.tcl demo/irules/ir-api-noelse.tcl
irule demo/irules/ir-api-noelse.tcl && f5 tmsh modify ltm virtual vs-web rules { ir-api-noelse }
pc1 'curl -s http://app.f5lab.test/api/1 http://app.f5lab.test/ http://app.f5lab.test/ http://app.f5lab.test/x' | grep -E "^(server|client seen):"
f5 tmsh modify ltm virtual vs-web profiles delete { oneconnect }
pc1 'curl -s http://app.f5lab.test/api/1 http://app.f5lab.test/ http://app.f5lab.test/ http://app.f5lab.test/x' | grep -E "^(server|client seen):"
f5 tmsh modify ltm virtual vs-web rules { ir-api-pool }
pc1 'curl -s http://app.f5lab.test/api/1 http://app.f5lab.test/ http://app.f5lab.test/ http://app.f5lab.test/x' | grep -E "^(server|client seen):"
f5 tmsh modify ltm virtual vs-web profiles add { oneconnect } rules none; f5 tmsh delete ltm rule ir-api-noelse
```

You should see:
- With OneConnect, no else: server3, server1, server2, server1. / went back to pool-web.
- Without OneConnect, no else: server3 four times. After /api/1, the requests stayed on the same server-side connection to server3.
- Without OneConnect, with the else: server3, then server1 three times. Naming a pool on every path re-balances when the pool
  changes.

### 7. The same selection without an iRule: an LTM policy
```bash
f5 tmsh create ltm policy Drafts/pol-api-pool strategy first-match requires add { http } controls add { forwarding } rules add { api { conditions add { 0 { http-uri path starts-with values { /api/ } } } actions add { 0 { forward select pool pool-api } } } }
f5 tmsh publish ltm policy Drafts/pol-api-pool && f5 tmsh modify ltm virtual vs-web rules none policies add { pol-api-pool }
pc1 'curl -s http://app.f5lab.test/ http://app.f5lab.test/api/users http://app.f5lab.test/ http://app.f5lab.test/api/orders' | grep -E "^(server|client seen):"
f5 tmsh delete ltm pool pool-api
f5 tmsh modify ltm virtual vs-web policies delete { pol-api-pool }; f5 tmsh delete ltm policy pol-api-pool
```

You should see server1, server3, server2, server3, the same as the iRule. Deleting pool-api is refused while the policy uses it
(01070265:3), so pool-api stays for the next steps.

### 8. HTTP to HTTPS: my own 301, then the built-in 302
```tcl
# ir-https-redirect: every HTTP request answered by the BIG-IP with a permanent redirect to the same URL over HTTPS
when HTTP_REQUEST {
    HTTP::respond 301 Location "https://[getfield [HTTP::host] ":" 1][HTTP::uri]" Connection close
}
```

```bash
cat demo/irules/ir-https-redirect.tcl
irule demo/irules/ir-https-redirect.tcl && f5 tmsh modify ltm virtual vs-web rules { ir-https-redirect }
pc1 'curl -sI http://app.f5lab.test/demo?x=1'
pc1 'curl -sL --cacert /run/f5lab/ca.crt http://app.f5lab.test/demo?x=1' | grep -E '^(server|scheme|request):'
f5 tmsh modify ltm virtual vs-web rules { _sys_https_redirect }; pc1 'curl -sI http://app.f5lab.test/demo?x=1'
f5 tmsh modify ltm virtual vs-web rules none; f5 tmsh delete ltm rule ir-https-redirect
```

You should see:
- `HTTP/1.0 301 Moved Permanently`, `Location: https://app.f5lab.test/demo?x=1`, `Server: BigIP`, `Connection: close`,
  `Content-Length: 0`.
- curl -L followed to vs-web-https: a server on :443, `scheme: https TLSv1.3`, request line `GET /demo?x=1 HTTP/1.0` (server3 in
  my run).
- The built-in `_sys_https_redirect` (it uses HTTP::redirect): `HTTP/1.0 302 Moved Temporarily`, `Connection: Keep-Alive`.

### 9. A maintenance answer from the BIG-IP itself
When pool-api has no active member, the rule answers 503 with a JSON body instead of sending the request anywhere:

```tcl
# ir-maintenance: /api/ to pool-api; when pool-api has no active member, the BIG-IP answers 503 itself
when HTTP_REQUEST {
    if { [HTTP::path] starts_with "/api/" } {
        if { [active_members pool-api] < 1 } {
            HTTP::respond 503 content "{\"error\":\"maintenance\",\"retry_after\":300}\n" \
                Content-Type "application/json" Retry-After 300
            return
        }
        pool pool-api
    } else {
        pool pool-web
    }
}
```

```bash
cat demo/irules/ir-maintenance.tcl
irule demo/irules/ir-maintenance.tcl && f5 tmsh modify ltm virtual vs-web rules { ir-maintenance }
pc1 'curl -s http://app.f5lab.test/api/v1' | head -1
f5 tmsh modify ltm pool pool-api members modify { server3:80 { session user-disabled } }
f5 tmsh show ltm pool pool-api field-fmt | grep -E 'active-member-cnt|availability-state'
pc1 'curl -s -i http://app.f5lab.test/api/v1; curl -s http://app.f5lab.test/ | head -1'
f5 tmsh modify ltm pool pool-api members modify { server3:80 { session user-enabled } }
```

You should see /api/v1 served by pool-api first. With server3 disabled: active-member-cnt 0 while availability-state is still
"available"; then `HTTP/1.0 503` with Content-Type application/json, Retry-After 300 and the 42-byte JSON body; and / still served
from pool-web (server2 in my run). Forcing the member offline gives the same 503. The rule stays attached for the next step.

### 10. When an iRule goes wrong
`ir-broken` fails at runtime when the request has no X-Api-Version header: `expr` gets an empty string.

```tcl
# ir-broken: a runtime error on purpose: without an X-Api-Version header, expr gets an empty string
when HTTP_REQUEST {
    set version [expr {[HTTP::header value X-Api-Version] + 1}]
    HTTP::header insert X-Next-Version $version
}
```

```bash
cat demo/irules/ir-broken.tcl
irule demo/irules/ir-broken.tcl && f5 tmsh modify ltm virtual vs-web rules { ir-broken }
pc1 "curl -sS -H 'X-Api-Version: 2' http://app.f5lab.test/ | head -1; curl -sS http://app.f5lab.test/ | head -1"
f5 'grep 01220001 /var/log/ltm | tail -n 1'
f5 tmsh show ltm rule ir-broken | grep -E 'Total|Failures'
```

You should see: with the header, the page (server1 in my run); without it, `curl: (56)` connection reset. /var/log/ltm:
`01220001:3: TCL error: /Common/ir-broken <HTTP_REQUEST> - can't use empty string as operand of "+" while executing ...`.
`show ltm rule`: Total 2, Failures 1. A runtime error resets the client's connection.

`ir-badpool` names a pool that does not exist:

```tcl
# ir-badpool: names a pool that does not exist
when HTTP_REQUEST {
    pool pool-nothere
}
```

```bash
irule demo/irules/ir-badpool.tcl && f5 tmsh modify ltm virtual vs-web rules { ir-badpool }
f5 tmsh modify ltm virtual vs-web rules { ir-maintenance }; f5 tmsh delete ltm pool pool-api
```

You should see `loaded ltm rule ir-badpool`: the rule loads. Attaching it to vs-web is refused: `01070151:3 ... Unable to find pool
(pool-nothere) referenced at line 3` (the comment line counts). Then, with ir-maintenance attached, deleting pool-api is refused:
`01070340:3 ... referenced by one or more rules`. An unattached rule does not protect a pool.

### 11. Clean up, check and save
```bash
f5 tmsh modify ltm virtual vs-web rules none; f5 tmsh delete ltm rule ir-maintenance ir-broken ir-badpool ir-api-pool; f5 tmsh delete ltm pool pool-api
f5 tmsh list ltm virtual vs-web rules policies profiles
pc1 'curl -s http://app.f5lab.test/' | grep -E "^(server|client seen):"
f5 tmsh save sys config | tail -1
```

You should see vs-web with rules none, policies none, profiles http-xff, oneconnect, reqlog-web and tcp, and a request answered
(server2 in my run).

## Verify
- ir-events: six events per request in order; two requests on one connection run the HTTP events twice and CLIENT_ACCEPTED once.
- ir-headers: the inserted request headers only on the server side; X-Pool-Member added and X-Server removed on the client side.
- ir-api-pool: /api/ to server3, everything else to pool-web, on one client connection.
- Missing else without OneConnect: server3 four times; with the else: server3 then server1 three times.
- pol-api-pool gives the same result as ir-api-pool.
- ir-https-redirect: 301 with the path and query kept; curl -L ends on vs-web-https with TLSv1.3.
- ir-maintenance: 503 JSON (42 bytes) for /api/ when pool-api has no active member, / still served.
- ir-broken: Total 2, Failures 1, and a TCL error 01220001:3 in /var/log/ltm.

## Gotchas
- Without OneConnect, an iRule that names a pool only on one branch keeps later requests on the same server-side connection: name a
  pool on every path (`else { pool pool-web }`).
- A disabled member makes active-member-cnt 0 while the pool's availability-state stays "available". `active_members` counts
  members that can take new connections.
- HTTP::respond answers with HTTP/1.0.
- A runtime TCL error resets the client connection. Watch `tmsh show ltm rule <name>` Failures and /var/log/ltm 01220001.
- A rule naming a missing pool loads with `load sys config merge`; the error only appears when it is attached (01070151:3). The
  line number counts the comment line.
- A pool used by an attached rule (01070340:3) or by a published policy action (01070265:3) cannot be deleted. Detach first.
- The HTTP profile's header-insert takes one header and cannot remove response headers; an iRule can.
- `_sys_https_redirect` is built in, signature-verified and cannot be changed or deleted. It answers 302, not 301.

## End state
lb-f5a is the same as at the start of this part: vs-web with rules none, policies none, profiles http-xff, oneconnect, reqlog-web
and tcp; no test iRules, no pool-api, no http-hdr-test, no pol-api-pool. Configuration saved.

```bash
./f5-save.sh lb-f5a
```

## Reset
Every object in this part is removed inside the part. If a step was interrupted, put the starting state back with the commands
for what is still there (on the lab server, with `demo/f5fn.sh` loaded), in this order:

```bash
f5 tmsh list ltm virtual vs-web rules policies profiles     # what is attached now
f5 tmsh modify ltm virtual vs-web rules none
f5 tmsh modify ltm virtual vs-web policies delete { pol-api-pool }                          # only if pol-api-pool is attached
f5 tmsh delete ltm policy pol-api-pool                                                      # only if it exists
f5 tmsh modify ltm virtual vs-web profiles delete { http-hdr-test } profiles add { http-xff }   # only if http-hdr-test is attached
f5 tmsh delete ltm profile http http-hdr-test                                               # only if it exists
f5 tmsh modify ltm virtual vs-web profiles add { oneconnect }                               # only if oneconnect is missing
f5 tmsh delete ltm rule <name>                                                              # for each ir-* rule still listed by: f5 tmsh list ltm rule | grep 'rule ir-'
f5 tmsh delete ltm pool pool-api                                                            # only if it exists
f5 tmsh save sys config
```

Or restore the UCS saved at the end of part 11.

## Files used
- `demo/f5fn.sh`: shortcuts `f5`, `pc1` and `irule` (loads a .tcl file as an iRule named after the file).
- `demo/f5headers.sh`: prints the HTTP lines per packet from a BIG-IP `tcpdump -A` capture.
- `demo/irules/ir-events.tcl`: logs every event of one request.
- `demo/irules/ir-headers.tcl`: inserts two request headers and one response header, removes X-Server.
- `demo/irules/ir-api-pool.tcl`: /api/ to pool-api, everything else to pool-web.
- `demo/irules/ir-api-noelse.tcl`: the same without the else.
- `demo/irules/ir-https-redirect.tcl`: 301 to the same URL over HTTPS.
- `demo/irules/ir-maintenance.tcl`: 503 JSON when pool-api has no active member.
- `demo/irules/ir-broken.tcl`: a runtime TCL error on purpose.
- `demo/irules/ir-badpool.tcl`: names a pool that does not exist.
