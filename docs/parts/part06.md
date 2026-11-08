# Part 6: Health monitors that catch real failures

| | |
|---|---|
| Video | [F5 Health Monitors That Catch Real Failures: ICMP vs TCP vs HTTP (Part 6)](https://youtu.be/OW_ALKZ-2M4) (public from 2026-11-19 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-health-monitors/) (from 2026-11-19 04:00 UTC) |
| Previous / next | [Part 5](part05.md) / [Part 7](part07.md) |

## Goal

I put five monitors side by side on the same servers (icmp, tcp, the built-in http, and two HTTP monitors of my own) and break
server2 in three different ways. Each failure shows which monitor notices and which one stays green while users get errors. The
pool ends with the one monitor that checks what users actually get: `http-app`.

## Starting state

- The lab is up and `./validate.sh` passes.
- lb-f5a only, in the end state of [Part 5](part05.md):
  - nodes `server1`, `server2`, `server3` (10.20.0.11-.13), no node monitor of their own;
  - pool `pool-web`: server1:80, server2:80, server3:80, monitor `http`, round robin, every ratio 1;
  - virtual server `vs-web` 10.20.30.100:80 with `tcp`, `http-xff` and SNAT pool `snat-web` (10.20.0.201, .202);
  - server3 at full speed (no netem delay).
- To get there: the guides of parts 2-5, or restore the UCS saved at the end of part 5 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Values used in this part

| Object | Value |
|---|---|
| BIG-IP | lb-f5a, web UI `https://172.21.32.43` (user admin; password: `sudo sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5a.env`) |
| Server I break | server2, 10.20.0.12 (container `clab-f5-clos-dc-server2`) |
| Monitor `http-app` (web UI) | type HTTP, send `GET / HTTP/1.1\r\nHost: app.f5lab.test\r\nConnection: close\r\n\r\n`, receive `200 OK` |
| Monitor `http-health` (tmsh) | parent http, send `GET /health HTTP/1.1\r\nHost: app.f5lab.test\r\nConnection: close\r\n\r\n`, receive `200 OK` |
| Built-in monitors | `icmp`, `tcp`, `http`: interval 5 s, timeout 16 s |
| Health page | `/health` on every server answers `OK` (file `/www/health`) |
| Client | pc1 (management 172.21.32.111) |

## Steps

All commands run on the lab server (root, in the repo folder) unless a step says otherwise.

### 1. What the built-in monitors really do

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm monitor http http all-properties' | grep -E 'monitor|interval|timeout|send|recv |time-until-up'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm monitor tcp tcp all-properties; tmsh list ltm monitor icmp icmp all-properties' | grep -E 'monitor|interval|timeout|send|recv '
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm pool pool-web monitor; tmsh list ltm node one-line'
```

You should see: `http` with interval 5, timeout 16, send `GET /\r\n` and `recv none`. With no receive string, any answer counts as
up, a 503 included. `tcp` and `icmp`: interval 5, timeout 16. `pool-web` has monitor `http`.

### 2. Create `http-app` in the web UI

In the web UI of lb-f5a (https://172.21.32.43): Local Traffic > Monitors > Create...

- Name: `http-app`
- Type: **HTTP**
- Send String: `GET / HTTP/1.1\r\nHost: app.f5lab.test\r\nConnection: close\r\n\r\n`
- Receive String: `200 OK`
- Everything else as the defaults (interval 5, timeout 16).
- Finished.

### 3. Create `http-health` in tmsh and put every monitor in place

`http-health` checks a dedicated health page instead of the application page. Then icmp goes on the three nodes, and all four HTTP/TCP
monitors go on the pool, so each one's verdict can be watched side by side.

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh create ltm monitor http http-health defaults-from http send "GET /health HTTP/1.1\r\nHost: app.f5lab.test\r\nConnection: close\r\n\r\n" recv "200 OK"'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm monitor http http-app http-health' | grep -E 'monitor|send|recv '
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm node server1 server2 server3 monitor icmp; tmsh modify ltm pool pool-web monitor tcp and http and http-health and http-app; tmsh list ltm pool pool-web monitor'
sleep 6
./demo/monitor-watch.sh 10.20.0.12 3 icmp:icmp tcp:tcp http:http http:http-health http:http-app
```

You should see the four monitors joined by `and` on `pool-web`, then three lines of
`./demo/monitor-watch.sh` with every monitor `up` for server2 and `member available`.

`./demo/monitor-watch.sh <ip> <samples> <type:name> ...` prints, about once a second, each monitor's state for one server as lb-f5a
sees it, plus the pool member's availability. The left column is real elapsed seconds.

### 4. Failure 1: the web server process stops

```bash
docker exec clab-f5-clos-dc-server2 nginx -s stop; ssh admin@172.21.32.111 'for i in 1 2 3; do curl -s -o /dev/null -w "pc1: HTTP %{http_code} from %header{x-server}\n" http://app.f5lab.test/; done'
./demo/monitor-watch.sh 10.20.0.12 22 icmp:icmp tcp:tcp http:http http:http-health http:http-app
ssh admin@clab-f5-clos-dc-lb-f5a 'grep -h "server2:80 monitor status" /var/log/ltm | tail -1'
docker exec clab-f5-clos-dc-server2 nginx
./demo/monitor-watch.sh 10.20.0.12 6 icmp:icmp tcp:tcp http:http http:http-health http:http-app
```

In my run: 2 of pc1's 3 requests got no HTTP response (`HTTP 000`) before the monitors reacted. icmp stayed up (the host still
answers ping). tcp, http, http-health and http-app all went down about 15-19 s after the stop, and the member went offline. The
`/var/log/ltm` line names the monitor that failed and says `No successful responses received before deadline`. After `nginx` started
again, every monitor was up within about 4 s.

### 5. Failure 2: the application answers 503, the health page still answers OK

nginx keeps running, but its main page returns `503 maintenance`. `/health` is a separate location, so it keeps answering OK.

```bash
docker exec clab-f5-clos-dc-server2 sh -c 'sed -i "s|location / {|location / { return 503 \"maintenance\\\\n\";|" /etc/nginx/http.d/default.conf && nginx -s reload'
ssh admin@172.21.32.111 'for i in 1 2 3; do curl -s -o /dev/null -w "pc1: HTTP %{http_code} from %header{x-server}\n" http://app.f5lab.test/; done'
./demo/monitor-watch.sh 10.20.0.12 20 icmp:icmp tcp:tcp http:http http:http-health http:http-app
ssh admin@clab-f5-clos-dc-lb-f5a 'grep -h "server2:80 monitor status" /var/log/ltm | tail -1'
docker exec clab-f5-clos-dc-server2 bash /shared/whoami-up.sh; sleep 8
./demo/monitor-watch.sh 10.20.0.12 3 icmp:icmp tcp:tcp http:http http:http-health http:http-app
```

In my run: 1 of the 3 user requests got the 503 from server2. icmp, tcp, http and http-health all stayed **up**. Only `http-app`
went down (about 12-18 s later), which is what takes server2 out of the pool. Re-running `whoami-up.sh` rewrites server2's nginx
configuration and brings the page back.

### 6. Failure 3: only the health page breaks

The application is fine; only `/health` is gone.

```bash
docker exec clab-f5-clos-dc-server2 rm /www/health; ssh admin@172.21.32.111 'for i in 1 2 3; do curl -s -o /dev/null -w "pc1: HTTP %{http_code} from %header{x-server}\n" http://app.f5lab.test/; done'
./demo/monitor-watch.sh 10.20.0.12 20 icmp:icmp tcp:tcp http:http http:http-health http:http-app
ssh admin@clab-f5-clos-dc-lb-f5a 'grep -h "server2:80 monitor status" /var/log/ltm | tail -1'
docker exec clab-f5-clos-dc-server2 sh -c 'echo OK > /www/health'; sleep 8
./demo/monitor-watch.sh 10.20.0.12 3 icmp:icmp tcp:tcp http:http http:http-health http:http-app
```

In my run: users kept getting 200. Only `http-health` went down, and because every monitor on the pool must pass, it took a working
server out of the pool.

### 7. Keep only `http-app` on the pool, in the web UI

In the web UI of lb-f5a: Local Traffic > Pools > `pool-web` (Properties) > Health Monitors: in the Active list select `tcp`, `http`
and `http-health`, move them to Available (`>>`), so only `http-app` stays Active > Update.

### 8. Nodes back to the default monitor, check, save

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm node server1 server2 server3 monitor default; tmsh list ltm pool pool-web monitor; tmsh list ltm node one-line'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm pool pool-web members field-fmt' | grep -E '^ +addr |availability-state|status-reason'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh save sys config' | tail -1
```

You should see `monitor http-app` on `pool-web`, the three nodes on the default node monitor, and all three members `available`.

## Verify

What each monitor said for server2 in each failure, in my run:

| Failure | icmp | tcp | http (built-in) | http-health | http-app | Users |
|---|---|---|---|---|---|---|
| nginx stopped | up | down | down | down | down | 2 of 3 requests no response before the monitors reacted |
| `/` returns 503, `/health` OK | up | up | up | up | down | 1 of 3 requests got the 503 |
| `/health` removed, app fine | up | up | up | down | up | all 200, but server2 taken out |

- Time to mark down: about 15-19 s after nginx stopped (interval 5, timeout 16); about 12-18 s for the 503 case.
- Time to mark up again after nginx restarted: within about 4 s.
- `/var/log/ltm` names the failing monitor and gives the reason.

## Gotchas

- The built-in `http` monitor has no receive string: any HTTP answer counts as up, a 503 page included. It only proves that something
  answers on port 80.
- icmp proves the host is alive, nothing more: it stayed up through every failure.
- A dedicated health page can lie both ways: it stayed OK while users got a 503 (failure 2), and it failed while the application was
  fine (failure 3), taking a working server out.
- Between the failure and the monitor's verdict (up to the 16 s timeout), users are still sent to the broken server: in my run 2 of
  3 requests failed in that window.
- The HTTP monitors come from lb-f5a's internal self IP 10.20.0.241, not from the SNAT pool addresses (seen in part 4's server logs).
- When several monitors are on a pool, all must pass. A monitor added "to be safe" adds a way to take a good server out.

## End state

- `pool-web`: monitor `http-app` only; round robin, ratios 1, server1-3:80, all available.
- Nodes server1-3: the default node monitor.
- Monitors `http-app` and `http-health` exist (`http-health` is kept, unused).
- server2 healthy again (nginx running, `/` and `/health` normal).
- `vs-web` unchanged. Configuration saved.

```bash
./f5-save.sh lb-f5a
```

## Reset

Repair server2 if a failure is still in place, then remove what this part created:

```bash
docker exec clab-f5-clos-dc-server2 bash /shared/whoami-up.sh
docker exec clab-f5-clos-dc-server2 sh -c 'echo OK > /www/health'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm pool pool-web monitor http; tmsh modify ltm node server1 server2 server3 monitor default; tmsh delete ltm monitor http http-app; tmsh delete ltm monitor http http-health; tmsh save sys config'
```

Or restore the UCS saved at the end of part 5 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Files used

- `demo/monitor-watch.sh`: about once a second, each monitor's verdict on one server as lb-f5a sees it, plus the pool member's availability.
