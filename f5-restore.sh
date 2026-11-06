#!/bin/bash
# f5-restore.sh <unit> <file.ucs>: upload a UCS saved by f5-save.sh to a (re)built BIG-IP and load it with no-license (the unit keeps
# the licence you activated on it). The upload is chunked and its size verified; the load restarts the BIG-IP's REST service (an
# HTTP 502 during the load is expected), so the script waits for "UCS installation success" in the BIG-IP's log and for Active.
cd "$(dirname "$0")"; . ./lib.sh
u=$1; f=$2; [ -n "$u" ] && [ -s "$f" ] || { echo "usage: $0 <lb-f5a|lb-f5b> <file.ucs>"; exit 2; }
n=$(basename "$f"); size=$(stat -c %s "$f"); start=0
chunk=$(mktemp); trap 'rm -f "$chunk"' EXIT
bigip_bash() { f5rest $u POST /mgmt/tm/util/bash -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"command":"run","utilCmdArgs":"-c \""+sys.argv[1]+"\""}))' "$1")" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("commandResult","").strip())'; }
while [ $start -lt $size ]; do end=$((start + 1048575)); [ $end -ge $size ] && end=$((size - 1))
  tail -c +$((start + 1)) "$f" | head -c $((end - start + 1)) > "$chunk"
  code=$(f5rest $u POST /mgmt/shared/file-transfer/uploads/$n -H 'Content-Type: application/octet-stream' \
           -H "Content-Range: $start-$end/$size" --data-binary @"$chunk" -o /dev/null -w '%{http_code}')
  [ "$code" = 200 ] || { say "$u: upload FAILED at bytes $start-$end (HTTP $code)"; exit 1; }
  start=$((end + 1)); done
got=$(bigip_bash "stat -c %s /var/config/rest/downloads/$n 2>/dev/null")
[ "$got" = "$size" ] || { say "$u: uploaded size on the BIG-IP is '${got:-none}', expected $size: not loading"; exit 1; }
say "$u: uploaded $n ($size bytes, verified on the BIG-IP); loading (no-license)"
n0=$(bigip_bash "grep -c install_ucs /var/log/ltm" 2>/dev/null); n0=${n0:-0}   # only a NEW log line counts (an older restore's line must not)
f5rest $u POST /mgmt/tm/sys/ucs -H 'Content-Type: application/json' --max-time 600 \
  -d "{\"command\":\"load\",\"name\":\"/var/config/rest/downloads/$n\",\"options\":[{\"no-license\":true}]}" >/dev/null 2>&1
say "$u: load sent; waiting for the BIG-IP to report the result (REST restarts during the load)"
for i in $(seq 1 60); do sleep 10
  r=$(bigip_bash "grep install_ucs /var/log/ltm | tail -n +$((n0 + 1)) | tail -1" 2>/dev/null)
  case "$r" in *"installation success"*) say "$u: UCS installation success"; break ;;
               *[Ff]ail*|*[Ee]rror*) say "$u: UCS load FAILED: $r"; exit 1 ;; esac
done
case "$r" in *"installation success"*) ;; *) say "$u: no result after 10 min; check /var/log/ltm on the BIG-IP"; exit 1 ;; esac
# after the install the unit stays "Failover offline" about 1 minute ("waiting ... for configuration load to complete"), then goes Active
for i in $(seq 1 30); do s=$(bigip_bash "tmsh show sys failover" 2>/dev/null); case "$s" in *[Aa]ctive*|*[Ss]tandby*) break ;; esac; sleep 10; done
say "$u: ${s:-failover state unknown}; web UI https://$(mip $u)"
