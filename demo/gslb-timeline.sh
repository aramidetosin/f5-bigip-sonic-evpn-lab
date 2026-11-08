#!/bin/bash
# gslb-timeline.sh [log] [t0]: one timeline of a GSLB failover or failback (part 19), in seconds after t0 (the moment the failure or
# repair was made; default: the epoch in /tmp/gslb-t0, written by site-a.sh). Merges:
#   - what pc1 saw (gslb-watch.sh log): each change of the resolver's answer, of site B listener's answer, and of the fetch result;
#   - what the BIG-IPs logged: LTM monitor and virtual-address events on lb-f5a (/var/log/ltm) and BIG-IP DNS status changes on
#     lb-f5b (/var/log/gtm), whose clocks are not synchronised with the lab server: the offset is measured here and applied.
L=${1:-/tmp/gslb-watch.log}; T0=${2:-$(cat /tmp/gslb-t0)}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
off() { local a b x; a=$(date +%s.%N); x=$(ssh $O admin@clab-f5-clos-dc-$1 'date +%s.%N' 2>/dev/null); b=$(date +%s.%N)
        python3 -c "print(round(($a+$b)/2-$x,1))" 2>/dev/null || echo 0; }
OA=$(off lb-f5a); OB=$(off lb-f5b)
{ ssh $O admin@clab-f5-clos-dc-lb-f5a "grep -hE 'pool-rhi member|Address 10.20.5.10 general|Virtual /Common/vs-rhi' /var/log/ltm | tail -60" 2>/dev/null | sed 's/^/A /'
  ssh $O admin@clab-f5-clos-dc-lb-f5b "grep -hE 'state change|Monitor instance' /var/log/gtm | grep -E 'vs-rhi|pool-a|pool-b|Wide IP|10.20.5.10:|Server /Common/site-a .*state' | tail -80" 2>/dev/null | sed 's/^/B /'
} > /tmp/gslb-biglog
python3 - "$L" "$T0" "$OA" "$OB" <<'EOF'
import sys, re, time, calendar
log, t0, oa, ob = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
rows = [l.split() for l in open(log) if len(l.split()) == 5]
t_end = float(rows[-1][0]) if rows else t0
ev = []
site = lambda a: {"10.20.5.10": "site A", "10.20.5.140": "site B"}.get(a, a)
prev = [None, None]
fail = None; ok = None
for r in rows:
    t = float(r[0]) - t0
    for i, (k, v) in enumerate((("resolver", r[1]), ("site B listener", r[3]))):
        if v != prev[i]:
            ev.append((t, "pc1", f"{k} answers {site(v)}" + (f" (TTL {r[2]})" if k == "resolver" else "")))
        prev[i] = v
    v = r[4]
    if v == "FAIL":
        if fail is None: fail = [t, t, 0]
        fail[1] = t; fail[2] += 1; ok = None
    else:
        if fail is not None:
            ev.append((fail[0], "pc1", f"fetches FAIL from here ({fail[2]} failed, last at +{fail[1]:.1f} s)")); fail = None
        if ok is None: ev.append((t, "pc1", f"fetches answered ({v})")); ok = v
if fail is not None: ev.append((fail[0], "pc1", f"fetches FAIL from here ({fail[2]} failed, still failing at the end)"))
y = time.gmtime(t0).tm_year
for l in open("/tmp/gslb-biglog"):
    u, rest = l[0], l[2:]
    m = re.match(r"(\w{3})\s+(\d+) (\d\d:\d\d:\d\d) \S+ \S+ \S+ \S+ (.*)", rest)
    if not m: continue
    e = calendar.timegm(time.strptime(f"{y} {m.group(1)} {m.group(2)} {m.group(3)}", "%Y %b %d %H:%M:%S")) + (oa if u == "A" else ob)
    if not (t0 - 5 <= e <= t_end + 5): continue
    msg = re.sub(r"^SNMP_TRAP: ", "", m.group(4)); msg = re.sub(r"/Common/", "", msg)
    msg = re.sub(r"\(ip:port=[^)]*\) ", "", msg); msg = re.sub(r" \[ [^]]* \]", "", msg); msg = re.sub(r"\s+", " ", msg)
    ev.append((e - t0, "lb-f5a LTM" if u == "A" else "lb-f5b DNS", msg[:96]))
ev.sort(key=lambda x: x[0])
# answers that flip back and forth (several changes, each under 3 s apart) are folded into one line per column
out = []; i = 0
while i < len(ev):
    t, who, what = ev[i]
    m = re.match(r"(resolver|site B listener) answers", what)
    if m:
        k = m.group(1); j = [x for x in range(i, len(ev)) if ev[x][2].startswith(k + " answers")]
        run = [j[0]]
        for x in j[1:]:
            if ev[x][0] - ev[run[-1]][0] < 3: run.append(x)
            else: break
        if len(run) >= 4:
            ttls = sorted(set(re.findall(r"TTL (\d+)", " ".join(ev[x][2] for x in run))))
            out.append((t, who, f"{k} answers ALTERNATE site A / site B ({len(run)} changes up to +{ev[run[-1]][0]:.1f} s" + (f", TTL {'/'.join(ttls)})" if ttls else ")")))
            skip = set(run[1:]); ev = [e for n, e in enumerate(ev) if n not in skip]; i += 1; continue
    out.append((t, who, what)); i += 1
for t, who, what in out:
    print(f"{t:+7.1f} s  {who:<10} {what}")
print(f"(t0 = {time.strftime('%H:%M:%S', time.gmtime(t0))} UTC; BIG-IP clocks corrected by +{oa} s (lb-f5a), +{ob} s (lb-f5b))")
EOF
