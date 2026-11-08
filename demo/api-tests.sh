#!/bin/bash
# api-tests.sh: from the lab server, pc1 sends part 17's API requests to http://api.f5lab.test (vs-api) and prints one line each:
#   what was sent > HTTP status, then who answered: a server (its X-Server header) or the BIG-IP (BLOCKED + support ID)
# The first five are what the OpenAPI file allows; the rest are not. Same requests every time, so before/after compare line by line.
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O -n admin@172.21.32.111 'U=http://api.f5lab.test/api/v1
t() { local label=$1; shift
  code=$(curl -s -m 3 -D /tmp/h -o /tmp/b -w "%{http_code}" "$@")
  who=$(grep -i "^x-server:" /tmp/h | tr -d "\r" | awk "{print \$2}")
  sid=$(grep -oE "[Ss]upport ?I[Dd][^0-9]*[0-9]{10,}" /tmp/b | grep -oE "[0-9]{10,}" | head -1)
  if [ -n "$sid" ]; then who="BLOCKED, support ID $sid"; elif [ "$code" = 403 ]; then who="BLOCKED (a HEAD reply has no body, so no support ID)"; elif [ -z "$who" ]; then who="(no X-Server header)"; fi
  printf "%-46s %s  %s\n" "$label" "$code" "$who"; }
{ printf "{\"name\":\""; head -c 200000 /dev/zero | tr "\0" "x"; printf "\",\"qty\":3}"; } > /tmp/big.json
t "GET  /items"                         $U/items
t "GET  /items/7"                       $U/items/7
t "POST /items {name, qty 3}"           -X POST -H "Content-Type: application/json" -d "{\"name\":\"spine\",\"qty\":3}" $U/items
t "GET  /health"                        $U/health
t "HEAD /items"                         -I $U/items
t "GET  /admin/users (not in the file)" $U/admin/users
t "DELETE /items/3 (method not in file)" -X DELETE $U/items/3
t "GET  /items/abc (id not an integer)" $U/items/abc
t "POST /items {qty 500} (max 100)"     -X POST -H "Content-Type: application/json" -d "{\"name\":\"spine\",\"qty\":500}" $U/items
t "POST /items {+ role:admin} (extra)"  -X POST -H "Content-Type: application/json" -d "{\"name\":\"spine\",\"qty\":3,\"role\":\"admin\"}" $U/items
t "POST /items (200 KB name)"           -X POST -H "Content-Type: application/json" --data-binary @/tmp/big.json $U/items
t "POST /items (not JSON)"              -X POST -H "Content-Type: application/json" -d "name=spine&qty=3" $U/items
t "GET  /items?q=1%27%20OR%20%271%27=%271" "$U/items?q=1%27%20OR%20%271%27=%271"
echo "13 requests sent"
'
