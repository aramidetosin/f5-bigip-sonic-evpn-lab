#!/bin/bash
# iquery-trust.sh: from the lab server, what `bigip_add` does between lb-f5a and lb-f5b, in the open (part 18): each unit's device
# certificate (/config/httpd/conf/ssl.crt/server.crt) is appended to the OTHER unit's
#   /config/gtm/server.crt   the servers its gtmd trusts when it connects to their big3d (iQuery, tcp 4353)
#   /config/big3d/client.crt the clients its big3d accepts
# A certificate already in a bundle is not added twice. Then big3d is restarted on both so it reloads its bundle.
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
S() { ssh $O admin@clab-f5-clos-dc-$1 "$2"; }
ADD='import sys
pem = sys.stdin.read().strip() + "\n"; path = sys.argv[1]
have = open(path).read() if __import__("os").path.exists(path) else ""
if pem.strip() in have: print("  %s: already there" % path)
else: open(path, "a").write(("" if have.endswith("\n") or not have else "\n") + pem); print("  %s: added" % path)'
for pair in "lb-f5a lb-f5b" "lb-f5b lb-f5a"; do
  set -- $pair
  echo "$1's certificate > $2"
  cert=$(S $1 "cat /config/httpd/conf/ssl.crt/server.crt")
  for f in /config/gtm/server.crt /config/big3d/client.crt; do
    printf '%s\n' "$cert" | S $2 "python3 -c '$ADD' $f"
  done
done
for u in lb-f5a lb-f5b; do S $u "bigstart restart big3d" >/dev/null; done
echo "big3d restarted on both"
