#!/bin/bash
# pa-load.sh [xml]: load bootstrap/fw-pa.xml into the running PA-VM: import, partial REPLACE of network and vsys (a merge would keep the
# factory virtual router), set the hostname, commit, wait for the job. --commit-only: just commit what is staged.
cd "$(dirname "$0")"; . ./lib.sh; # pa-load.sh --commit-only: just commit what is staged (ssh-keys.sh)
ONLY=0; [ "${1:-}" = --commit-only ] && { ONLY=1; shift; }
XML=${1:-bootstrap/fw-pa.xml}; F=$(basename "$XML")
FP=0
for i in $(seq 1 60); do K=$(pakey); [ -n "$K" ] && break
  if [ $FP = 0 ] && curl -sk --max-time 15 --data-urlencode user=admin --data-urlencode password=admin \
       "https://$PA/api/?type=keygen" | grep -q "change your password"; then
    say "fw-pa: still on the factory password (the launcher missed the change prompt): changing it over SSH"; python3 -B pa-firstpw.py "$PA"; FP=1
  fi
  sleep 20; done
[ -n "$K" ] || { say "fw-pa: no API key after 20 min (PA-VM not up, or PA_USER / PA_PW wrong)"; exit 1; }
op() { curl -sk "https://$PA/api/?type=op&key=$K" --data-urlencode "cmd=$1"; }
A() { curl -sk --max-time 60 -G "https://$PA/api/" --data-urlencode "key=$K" "$@"; echo; }
if [ $ONLY = 0 ]; then
for i in $(seq 1 90); do j=$(op "<show><jobs><all/></jobs></show>"); echo "$j" | grep -q -E "<status>(ACT|PEND)</status>" || break; sleep 10; done
echo "import: $(curl -sk "https://$PA/api/?type=import&category=configuration&key=$K" -F "file=@$XML;filename=$F" | grep -o 'status="[a-z]*"')"
DEV="/config/devices/entry[@name='localhost.localdomain']"
for p in network "vsys/entry[@name='vsys1']"; do
    r=$(op "<load><config><partial><mode>replace</mode><from-xpath>$DEV/$p</from-xpath><to-xpath>$DEV/$p</to-xpath><from>$F</from></partial></config></load>")
  echo "replace $p: $(echo "$r" | grep -o 'status="[a-z]*"')"; echo "$r" | grep -q 'status="success"' || { echo "$r" | sed 's/<[^>]*>/ /g' | tr -s ' ' | head -c 600; echo; exit 1; }
done
H=$(grep -o '<hostname>[^<]*</hostname>' "$XML" | head -1)
fi
for i in $(seq 1 90); do j=$(op "<show><jobs><all/></jobs></show>"); echo "$j" | grep -q -E "<status>(ACT|PEND)</status>" || break; sleep 10; done
[ $ONLY = 1 ] || echo "hostname: $(A --data-urlencode type=config --data-urlencode action=set --data-urlencode "xpath=$DEV/deviceconfig/system" --data-urlencode "element=$H" | grep -o 'status="[a-z]*"')"
j=$(curl -sk "https://$PA/api/?type=commit&key=$K" --data-urlencode "cmd=<commit></commit>" | sed -n 's:.*<job>\([0-9]*\)</job>.*:\1:p')
[ -n "$j" ] || { say "commit: no job id"; exit 1; }
for i in $(seq 1 90); do sleep 4; r=$(A --data-urlencode type=op --data-urlencode "cmd=<show><jobs><id>$j</id></jobs></show>")
  echo "$r" | grep -q "<status>FIN</status>" && { res=$(echo "$r" | sed -n 's:.*<result>\([A-Z]*\)</result>.*:\1:p' | head -1); echo "commit $j: $res"
    [ "$res" = OK ] && [ $FP = 1 ] && docker exec $C-fw-pa sh -c 'echo "0 running" > /health' && echo "fw-pa: marked healthy (/health)"
    [ "$res" = OK ]; exit $?; }; done
say "commit $j: no result after 6 min"; exit 1
