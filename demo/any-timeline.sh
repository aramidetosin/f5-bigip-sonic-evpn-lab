#!/bin/bash
# any-timeline.sh [log] [t0]: one timeline of an anycast failure or repair (part 20), in seconds after t0 (default: /tmp/gslb-t0,
# written by site-a.sh). Merges any-watch.sh's log (pc1's fetches by site, leaf1a's next hops to 10.20.5.200) with lb-f5a's LTM log
# (pool-rhi members, vs-any, the virtual address 10.20.5.200). lb-f5a and leaf1a are VMs whose clocks are not synchronised with the
# lab server: both offsets are measured here and applied.
L=${1:-/tmp/any-watch.log}; T0=${2:-$(cat /tmp/gslb-t0)}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
a=$(date +%s.%N); x=$(ssh $O admin@clab-f5-clos-dc-lb-f5a 'date +%s.%N' 2>/dev/null); b=$(date +%s.%N)
OA=$(python3 -c "print(round(($a+$b)/2-$x,1))")
a=$(date +%s.%N); x=$(ssh $O -n admin@172.21.32.21 'date +%s.%N' 2>/dev/null); b=$(date +%s.%N)
OL=$(python3 -c "print(round(($a+$b)/2-$x,1))")
ssh $O admin@clab-f5-clos-dc-lb-f5a "grep -hE 'pool-rhi member|Address 10.20.5.200 general|Virtual /Common/vs-any' /var/log/ltm | tail -40" 2>/dev/null > /tmp/any-biglog
python3 - "$L" "$T0" "$OA" "$OL" <<'EOF'
import sys, re, time, calendar
log, t0, oa, ol = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
F = []; R = []
for l in open(log):
    p = l.split()
    if len(p) >= 3 and p[1] == "F": F.append((float(p[0]) - t0, p[2].replace("_", " ")))
    if len(p) >= 3 and p[1] == "R": R.append((float(p[0]) + ol - t0, p[2]))
ev = []
prev = None
for t, r in R:
    if r != prev:
        ev.append((t, "leaf1a", "next hops to 10.20.5.200: " + {"A+B": "site A + site B", "A": "site A only", "B": "site B only"}.get(r, r)))
    prev = r
# fetches: per second-long window, how many went to each site and how many failed; print only when the mix changes
def mix(xs):
    a = sum(1 for _, s in xs if s == "site A"); b = sum(1 for _, s in xs if s == "site B"); f = sum(1 for _, s in xs if s == "FAIL")
    return a, b, f
if F:
    start = F[0][0]; w = []; last = None; first_fail = last_fail = None; nfail = 0
    for t, s in F:
        if s == "FAIL":
            nfail += 1; last_fail = t
            if first_fail is None: first_fail = t
    i = 0; t = start
    while i < len(F):
        win = [x for x in F if t <= x[0] < t + 2]
        a, b, f = mix(win)
        shape = ("A" if a else "") + ("B" if b else "") + ("F" if f else "")
        if shape != last and win:
            ev.append((t, "pc1", f"fetches in the next 2 s: site A {a}, site B {b}, failed {f}"))
            last = shape
        t += 2; i = len([x for x in F if x[0] < t])
    if nfail:
        ev.append((first_fail, "pc1", f"first failed fetch ({nfail} failed in all, the last at {last_fail:+.1f} s)"))
y = time.gmtime(t0).tm_year
t_end = F[-1][0] if F else 0
for l in open("/tmp/any-biglog"):
    m = re.match(r"(\w{3})\s+(\d+) (\d\d:\d\d:\d\d) \S+ \S+ \S+ \S+ (.*)", l)
    if not m: continue
    e = calendar.timegm(time.strptime(f"{y} {m.group(1)} {m.group(2)} {m.group(3)}", "%Y %b %d %H:%M:%S")) + oa - t0
    if not (-5 <= e <= t_end + 5): continue
    msg = re.sub(r"/Common/", "", m.group(4)); msg = re.sub(r" \[ [^]]* \]", "", msg); msg = re.sub(r"\s+", " ", msg)
    ev.append((e, "lb-f5a LTM", msg[:96]))
for t, who, what in sorted(ev, key=lambda x: x[0]):
    print(f"{t:+7.1f} s  {who:<10} {what}")
print(f"(t0 = {time.strftime('%H:%M:%S', time.gmtime(t0))} UTC; clocks corrected: lb-f5a +{oa} s, leaf1a +{ol} s)")
EOF
