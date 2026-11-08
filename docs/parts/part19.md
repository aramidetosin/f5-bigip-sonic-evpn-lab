# Part 19: GSLB failover between two sites, timed

| | |
|---|---|
| Video | [F5 GSLB Failover Between Two Data Centres, Timed (Part 19)](https://youtu.be/hdTepAkvKBc) (public from 2026-12-19 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-gslb-failover/) (from 2026-12-19 04:00 UTC) |
| Previous / next | [Part 18](part18.md) / [Part 20](part20.md) |

## Goal

I make site A fail and time, about twice a second from pc1 through the real resolver, how long clients take to stop noticing. A failure
reaches the client through a chain of clocks: the LTM monitor on site A, the bigip monitor that BIG-IP DNS polls over iQuery, the GSLB
pool and wide IP, and the resolver's TTL. I run the same failure with the defaults, with one pool setting fixed, and with the bigip
monitor and the TTL tuned. Then a planned drain done two ways, and a site that disappears entirely.

The numbers below are from my runs. Yours will differ from run to run: monitor polls and TTLs are not aligned with the moment of the
failure.

## Starting state

- The lab is up and `./validate.sh` passes.
- The end state of part 18: lb-f5a (site A, `vs-rhi` 10.20.5.10, pool `pool-rhi` with monitor `mon-rhi`) and lb-f5b (site B,
  `vs-siteb` 10.20.5.140) standalone; gtm provisioned on both, sync group `gslb-ab`, servers `site-a` / `site-b` with the default
  `bigip` monitor, listeners 10.20.5.53 and 10.20.5.153, GSLB pools `pool-a` / `pool-b`, wide IP `app.gslb.f5lab.test` in topology
  mode. pc1-3 resolve through the resolver on lan-switch (10.10.0.5).
- Units used: both. GSLB objects are changed on lb-f5a; the sync group carries them to lb-f5b. Timelines read BIG-IP DNS status from
  lb-f5b's log.
- To get here: the guide of part 18, or restore the UCS you saved at its end with `./f5-restore.sh`. Save both units before you start
  (`./f5-save.sh`).

Every command runs **on the lab server (root, in the repo's `demo` folder, with the helper functions loaded)**:

```bash
cd demo
. ./f5fn.sh
```

Helpers (from `demo/f5fn.sh`): `f5 '<cmd>'` / `f5b '<cmd>'` run a command on lb-f5a / lb-f5b (bash as admin); `pc1 '<cmd>'` runs it
on pc1.

## Values used in this part

| Object | Value |
|---|---|
| LTM monitors (unchanged) | `http-app` and `mon-rhi` (on `pool-rhi`, site A): interval 5 s, timeout 16 s |
| BIG-IP DNS monitor, default | `bigip` on servers site-a and site-b: interval 30 s, timeout 90 s |
| BIG-IP DNS monitor, tuned | `bigip-fast` (defaults-from bigip): interval 5 s, timeout 16 s |
| GSLB pool defaults (pool-a) | preferred round robin, alternate round robin, fallback return-to-dns, TTL 30 |
| Changed in this part | wide IP `pool-lb-mode global-availability` (pool-a order 0, pool-b order 1); `fallback-mode none` and `ttl 5` on pool-a and pool-b |
| Site A internal addresses | 10.20.0.240 (floating), 10.20.0.241 (lb-f5a self IP), 10.20.0.201-202 (SNAT pool) |
| Failures (`site-a.sh`) | `app-fail` / `app-ok`; `drain` / `undrain`; `dns-drain` / `dns-undrain`; `isolate` / `connect` |

## The measuring tools

- `site-a.sh <action>` makes one failure or repair and writes its start time (t0, epoch) to `/tmp/gslb-t0`:
  - `app-fail` adds blackhole routes on server1-3 for site A's four internal addresses, so the servers still receive but no reply
    reaches site A. Site B (10.20.0.242 and its automap) is untouched. `app-ok` removes them.
  - `drain` disables `vs-rhi` on lb-f5a; `undrain` enables it.
  - `dns-drain` disables the GSLB member `site-a:/Common/vs-rhi` of pool-a; `dns-undrain` enables it.
  - `isolate` disables lb-f5a's data interfaces 1.1-1.3 (fabric, servers and the link to site B that carries iQuery; management
    stays). `connect` enables them.
- `gslb-watch.sh <seconds> [log]` samples from pc1 about twice a second: the answer via the resolver and its TTL (what pc1 really
  gets, cached), the answer from site B's listener 10.20.5.153 (what BIG-IP DNS answers at that moment), and a fetch of
  `http://app.gslb.f5lab.test/` by name with a 1 s timeout (server name or FAIL).
- `gslb-timeline.sh [log] [t0]` merges that log with LTM's log on lb-f5a and BIG-IP DNS's log on lb-f5b, in seconds after t0. The
  BIG-IPs' clocks ran about 6 s behind the lab server in my lab (no reachable NTP): the script measures the offset and corrects it on
  every run.

Each measured run in the steps is the same pattern: start the action a few seconds into the watch, then print the timeline:

```bash
( (sleep 6; ./site-a.sh <action>) & ); ./gslb-watch.sh <seconds> /tmp/<log>.log
clear; ./gslb-timeline.sh /tmp/<log>.log
```

## Steps

### 1. Where part 18 left things

The wide IP, the two monitors in the chain, the GSLB pool's methods and TTL, and iQuery:

```bash
f5 'tmsh list gtm wideip a app.gslb.f5lab.test pool-lb-mode pools'
f5 'tmsh list ltm monitor http http-app interval timeout; tmsh list ltm pool pool-rhi monitor'
f5 'tmsh list gtm server site-a site-b monitor; tmsh list gtm monitor bigip bigip interval timeout'
f5 'tmsh list gtm pool a pool-a load-balancing-mode alternate-mode fallback-mode verify-member-availability ttl'
f5 "tmsh show gtm iquery | grep -E '^ *(Server|State) '"
```

You should see: topology, pool-a (order 0) and pool-b (order 1); `http-app` 5 s / 16 s, `pool-rhi` on `mon-rhi`; servers on `bigip`
(interval 30, timeout 90); pool-a preferred round robin, alternate round robin, fallback return-to-dns, verify member availability
enabled, TTL 30. None of these GSLB pool values were set in part 18: they are the defaults. iQuery: site-a and site-b connected.

With these defaults, the worst case before a client stops being sent to a dead site adds up to about 76 s (LTM 16 s, bigip monitor up to
30 s, resolver TTL 30 s), before anything the client itself caches.

### 2. Global availability

Global availability answers from the first pool that can answer: pool-a, and pool-b only when pool-a cannot.

```bash
f5 'tmsh modify gtm wideip a app.gslb.f5lab.test pool-lb-mode global-availability; tmsh list gtm wideip a app.gslb.f5lab.test pool-lb-mode pools'
sleep 3; for p in pc1 pc2 pc3; do ./gslb-dig.sh $p 10.20.5.53 4; done
```

You should see all three PCs on site A.

### 3. The tools

```bash
sed -n '2,12p;15,17p' site-a.sh
sed -n '2,6p' gslb-watch.sh
./gslb-watch.sh 3 /tmp/demo.log
sed -n '2,6p' gslb-timeline.sh
```

The 3 s sample: the resolver gives site A with its TTL counting down (30, 29), site B's listener also answers site A (pool-a is
first), and every fetch is answered.

### 4. Run 1: the defaults

Site A loses its servers 8 s into a 110 s watch:

```bash
( (sleep 8; ./site-a.sh app-fail) & ); ./gslb-watch.sh 110 /tmp/f1.log
clear; ./gslb-timeline.sh /tmp/f1.log
```

In my run: fetches failed from +0.9 s. LTM marked the three servers down at +18.7 to +21.7 s, and the virtual server unavailable.
BIG-IP DNS on site B marked `vs-rhi`, the pool member and pool-a red at +46.7 s, 25 s after LTM (the bigip monitor polls every 30 s).
From then on, the resolver and site B's listener **alternated** between the two sites with a **TTL of 0**, and the fetches were
answered again from +47.7 s: 54 failed fetches, about 47 s. Site A stays failed for the next step.

### 5. Why the answers alternate

```bash
f5b "tmsh show gtm wideip a app.gslb.f5lab.test field-fmt | grep -E ' (requests|preferred|alternate|fallback|return-to-dns|return-from-dns) '"
pc1 'dig @10.20.5.153 app.gslb.f5lab.test' | grep -EA3 'ANSWER S|AUTHORITY S'
f5b 'ls -l --time-style=+%H:%M:%S /var/named/config/namedb/ | grep gslb; cat /var/named/config/namedb/db.external.gslb.f5lab.test.'
f5b "grep -h 'Wide IP /Common/app' /var/log/gtm | tail -1 | cut -c1-120"
f5 'tmsh list gtm pool a pool-a fallback-mode'
```

In my run: wide IP statistics preferred 981, alternate 0, fallback 537 = return-to-dns 537 = return-from-dns 537. The answer from
site B's listener had two A records (10.20.5.140 and 10.20.5.10), TTL 0, and an authority section naming `this.name.is.invalid.`.

That answer comes from BIND, the DNS server inside the BIG-IP. Its zone `db.external.gslb.f5lab.test.` holds `app` with both
application addresses, TTL 0, and no notion of health. The zone's journal was written in the same second the wide IP was created in
part 18; I never wrote that zone. pool-a was down, so its preferred and alternate methods had nothing, and the fallback method,
`return-to-dns`, handed the query to that BIND. BIND rotates the two records, so the first address alternates, and with TTL 0 the
resolver keeps nothing. Clients got two addresses, one of them dead: the fetches recovered only because curl tries the second address
when the first fails.

### 6. The fix: no fallback

With `fallback-mode none`, a pool with nothing to offer says nothing, and global availability moves on to the next pool:

```bash
f5 'tmsh modify gtm pool a pool-a pool-b fallback-mode none; tmsh list gtm pool a pool-a pool-b fallback-mode'
sleep 3; pc1 'for i in 1 2 3; do dig +noall +answer @10.20.5.153 app.gslb.f5lab.test; dig +noall +answer @10.20.5.53 app.gslb.f5lab.test; done'
```

Site A is still cut off. You should see 10.20.5.140 (site B) only, from both listeners, TTL 30.

### 7. Failback, timed

Site A repaired, 6 s into a 50 s watch:

```bash
( (sleep 6; ./site-a.sh app-ok) & ); ./gslb-watch.sh 50 /tmp/b1.log
clear; ./gslb-timeline.sh /tmp/b1.log
```

In my run: LTM marked the first member up and the virtual server available at +1.2 s; BIG-IP DNS turned pool-a green at +21.2 s (its
next poll); the resolver handed out site A at +22.7 s, TTL 30. No failed fetch in either direction: site B kept answering throughout.

### 8. Run 2: fallback fixed, other defaults

```bash
( (sleep 6; ./site-a.sh app-fail) & ); ./gslb-watch.sh 100 /tmp/f2.log
clear; ./gslb-timeline.sh /tmp/f2.log
./site-a.sh app-ok
```

In my run: fetches failed from +0.4 to +49.9 s (56 failed). LTM +17.7 to +20.7 s; BIG-IP DNS red +45.7 s (25 s after LTM again); site
B's listener on site B +47.5 s; the resolver on site B +52.0 s with a fresh TTL of 30. Then site B only, every fetch answered, no
alternation: about 51 s without an answer.

That is slightly longer than run 1, because in run 1 curl recovered as soon as it was handed both addresses. The fix gives every client a
correct answer; it does not make the failover faster. Tuning does.

### 9. Tune the two clocks BIG-IP DNS owns

How often BIG-IP DNS asks site A (a bigip monitor with interval 5 s, timeout 16 s, on both servers), and how long resolvers may keep an
answer (TTL 5 s on both pools):

```bash
f5 'tmsh create gtm monitor bigip bigip-fast defaults-from bigip interval 5 timeout 16; tmsh modify gtm server site-a site-b monitor bigip-fast'
f5 'tmsh modify gtm pool a pool-a pool-b ttl 5; tmsh list gtm monitor bigip bigip-fast interval timeout; tmsh list gtm pool a pool-a pool-b ttl'
sleep 30; f5b "tmsh show gtm pool a field-fmt | grep -E '^gtm|availability'"
```

You should see both pools available 30 s later. The LTM monitor stays at 5 s / 16 s, as chosen for this application in part 14.

### 10. Run 3: tuned

```bash
( (sleep 6; ./site-a.sh app-fail) & ); ./gslb-watch.sh 60 /tmp/f3.log
clear; ./gslb-timeline.sh /tmp/f3.log
./site-a.sh app-ok; sleep 40
```

In my run: fetches failed from +0.8 to +25.4 s (22 failed). LTM +16.0 to +20.0 s; BIG-IP DNS red +24.0 s (4 s after LTM, instead of
25); the resolver on site B +25.9 s, TTL 5. About 25 s without an answer, half of run 2; LTM's own timeout is now the largest share. One
more fetch failed 4 s before t0, with nothing changed yet: a single stray timeout, not counted in the 22 above.

### 11. Planned maintenance, the wrong way round: drain at LTM

The virtual server on site A disabled first:

```bash
( (sleep 6; ./site-a.sh drain) & ); ./gslb-watch.sh 35 /tmp/d1.log
clear; ./gslb-timeline.sh /tmp/d1.log
./site-a.sh undrain; sleep 20
```

In my run: 8 failed fetches, +0.4 to +3.9 s. BIG-IP DNS knew at +1.4 s ("Parent server site-a marked VS unavailable": a disabled
virtual server is reported straight away), but the resolver's copy still pointed at site A until +4.4 s, and a disabled virtual server
refuses. With TTL 5 that is 3.5 s of failures; with the default TTL 30 it can be up to 30 s.

### 12. Planned maintenance, the right way round: drain at DNS

The GSLB member for site A disabled first, on BIG-IP DNS:

```bash
( (sleep 6; ./site-a.sh dns-drain) & ); ./gslb-watch.sh 35 /tmp/d2.log
clear; ./gslb-timeline.sh /tmp/d2.log
./site-a.sh dns-undrain; sleep 20
```

In my run: pool-a red at +0.2 s, site B's listener on site B at +0.9 s, the resolver on site B at +4.4 s, and **no failed fetch**.
Cached answers still went to site A, which was still fully working. From there, wait the TTL (longer for clients that cache), watch
site A's connections fall, and only then work on it.

### 13. A site that disappears

All of lb-f5a's data interfaces down, with the tuned monitor:

```bash
( (sleep 6; ./site-a.sh isolate) & ); ./gslb-watch.sh 60 /tmp/i1.log
clear; ./gslb-timeline.sh /tmp/i1.log
f5b "grep -h 'sync group' /var/log/gtm | tail -1 | cut -c1-120"
./site-a.sh connect; sleep 60
f5b "grep -h 'sync group' /var/log/gtm | tail -1 | cut -c1-120; tmsh show gtm iquery | grep -E '^ *(Server|State) '"
f5b "tmsh show gtm pool a field-fmt | grep -E '^gtm|availability'"
```

In my run: 17 failed fetches, +0.5 to +13.4 s. BIG-IP DNS logged "no reply from big3d: timed out" (bigip-fast) at +13.0 s with pool-a
red, and the whole server site-a red at +15.0 s; the resolver and the fetches on site B at +14.9 s. LTM lines on site A followed at
+18.1 to +22.1 s: site A was still running and logging, it simply could not reach anything. No LTM is involved in this detection:
nobody replies to the bigip monitor. lb-f5b's log showed site-a leaving the sync group `gslb-ab`. After `connect`, site-a joined the
sync group again and iQuery was connected to both; pool-a and pool-b available.

With the default 90 s timeout I would expect a much longer outage here; I did not run that case.

## Verify

| Run | Failed fetches | Without an answer | BIG-IP DNS red | Resolver on site B |
|---|---|---|---|---|
| 1, defaults | 54 | about 47 s, then both sites with TTL 0 | +46.7 s | alternating |
| 2, fallback none | 56 | about 51 s | +45.7 s | +52.0 s |
| 3, tuned (bigip-fast, TTL 5) | 22 | about 25 s | +24.0 s | +25.9 s |
| Drain at LTM (tuned) | 8 | about 3.5 s | +1.4 s | +4.4 s |
| Drain at DNS (tuned) | 0 | 0 | +0.2 s | +4.4 s |
| Isolate (tuned) | 17 | about 13 s | +13.0 s | +14.9 s |

Failback with the defaults: site A answering again at +22.7 s, no failed fetch. After the last step, `tmsh show gtm iquery` shows site-a
and site-b connected and both GSLB pools are available.

## Gotchas

- **`return-to-dns` hands a dead site to clients.** The GSLB pool's default fallback method sends the query to the BIG-IP's own BIND,
  which holds a zone for the wide IP's domain with every application address, TTL 0 and no health. With global availability that means
  both sites alternate instead of moving to pool-b. `fallback-mode none` on the pools fixes it.
- **A client that tries the second address hides the bug.** curl recovered in run 1 because it was given both addresses. A client
  that uses only the first one gets the dead site half the time.
- **The bigip monitor's 30 s interval is the largest default delay.** In runs 1 and 2 BIG-IP DNS saw the failure about 25 s after LTM.
- **Drain from the top.** Disable the GSLB member first, wait the TTL, then touch the site. Disabling the virtual server first fails
  every cached answer until the TTL runs out.
- **BIG-IP clocks.** The BIG-IPs' clocks ran about 6 s behind the lab server with no reachable NTP. `gslb-timeline.sh` corrects it
  per run; compare raw log times only after that correction.
- **t0 lag.** `site-a.sh app-fail` makes 12 `docker exec` calls, which took about 1.5 s; t0 is when the action starts.
- **Isolation takes the unit out of the sync group.** It rejoined on its own after its links came back.

## End state

- Site A and site B both up (after `app-ok`, `undrain`, `dns-undrain` and `connect`), both GSLB pools available, iQuery connected,
  lb-f5a back in sync group `gslb-ab`.
- Wide IP `app.gslb.f5lab.test` in global-availability mode (pool-a order 0, pool-b order 1).
- pool-a and pool-b: `fallback-mode none`, `ttl 5`. GSLB monitor `bigip-fast` (interval 5, timeout 16) on servers site-a and site-b.

Save it (from the repo root):

```bash
cd ..
./f5-save.sh
```

## Reset

Restore the UCS you saved at the start of this part (the end of part 18) on both units, as in part 18:

```bash
./f5-restore.sh lb-f5a /root/f5-clos-dc-secrets/ucs/<lb-f5a-file>.ucs
./f5-restore.sh lb-f5b /root/f5-clos-dc-secrets/ucs/<lb-f5b-file>.ucs
```

Or undo this part's changes on lb-f5a (the sync group carries them). I did not run these commands in my lab: check each result.
Restoring `fallback-mode return-to-dns` brings back the behaviour of run 1.

```bash
f5 'tmsh modify gtm server site-a site-b monitor bigip'
f5 'tmsh delete gtm monitor bigip bigip-fast'
f5 'tmsh modify gtm pool a pool-a pool-b ttl 30 fallback-mode return-to-dns'
f5 'tmsh modify gtm wideip a app.gslb.f5lab.test pool-lb-mode topology'
```

If a run was interrupted, repair site A first: `./site-a.sh app-ok`, `./site-a.sh undrain`, `./site-a.sh dns-undrain`,
`./site-a.sh connect`.

## Files used

- `demo/f5fn.sh`: the helpers `f5`, `f5b`, `pc1`.
- `demo/site-a.sh`: one failure or repair of site A, with its start time (t0).
- `demo/gslb-watch.sh`: pc1's samples: the answer via the resolver and its TTL, site B's listener's answer, a fetch by name.
- `demo/gslb-timeline.sh`: the samples merged with lb-f5a's LTM log and lb-f5b's BIG-IP DNS log, clocks corrected.
- `demo/gslb-dig.sh`: n queries from a PC to a DNS server, counted per answer and site.
