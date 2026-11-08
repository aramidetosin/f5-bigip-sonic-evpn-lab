#!/usr/bin/env python3
"""any-conns.py <connections> <seconds> (runs on pc1, part 20): opens <connections> keep-alive HTTP connections to http://any.f5lab.test/
and sends one request on each about twice a second for <seconds>, on the SAME connection as long as it lives. Each connection has its
own source port, so with a 5-tuple ECMP hash each may land on a different site. Prints one line per second: every connection's site
(A or B, from the SNAT address the server saw), 'x' when its request failed (reset, timeout), then a summary of every break:
when it happened and which site the connection had been using. A broken connection is reopened (new source port) and counted again."""
import http.client, socket, sys, time
N, D = int(sys.argv[1]), float(sys.argv[2])
HOST, IP = "any.f5lab.test", "10.20.5.200"

def site(body):
    for line in body.decode(errors="replace").splitlines():
        if line.startswith("client seen:"):
            return "B" if line.split()[2].startswith("10.20.0.242:") else "A"
    return "?"

def opened():
    c = http.client.HTTPConnection(IP, 80, timeout=1.0); c.connect(); return c

conns = [None] * N; last = ["-"] * N; breaks = []
t0 = time.time(); next_print = t0
while time.time() - t0 < D:
    for i in range(N):
        try:
            if conns[i] is None: conns[i] = opened()
            conns[i].request("GET", "/", headers={"Host": HOST, "Connection": "keep-alive"})
            r = conns[i].getresponse(); s = site(r.read())
            last[i] = s
        except (OSError, http.client.HTTPException) as e:
            breaks.append((time.time() - t0, i + 1, last[i], type(e).__name__))
            last[i] = "x"
            try: conns[i].close()
            except Exception: pass
            conns[i] = None
    now = time.time()
    if now >= next_print:
        print(time.strftime("%H:%M:%S", time.gmtime(now)) + "  " + " ".join(f"c{i + 1}:{last[i]}" for i in range(N)), flush=True)
        next_print += 1.0
    time.sleep(0.5)
print(f"{len(breaks)} broken connection(s)")
for t, i, s, e in breaks:
    print(f"  at {time.strftime('%H:%M:%S', time.gmtime(t0 + t))} UTC: c{i} (was on site {s}) {e}")
