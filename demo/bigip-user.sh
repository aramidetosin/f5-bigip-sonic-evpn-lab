#!/bin/bash
# bigip-user.sh <login|setpw> <user> (part 22): a BIG-IP REST user tested the way CIS uses it, on lb-f5a (or F5U=lb-f5b).
#   The password comes on stdin (from the lab secrets folder) and is never printed or put in a command line.
#   login   POST /mgmt/shared/authn/login for a token (what CIS does), then GET AS3's /mgmt/shared/appsvcs/info with that token
#   setpw   as admin, PATCH /mgmt/shared/authz/users/<user> with the password (the REST framework's own user store)
U=${F5U:-lb-f5a}; N=${2:?user}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
case $1 in
  login) ssh $O admin@clab-f5-clos-dc-$U "read -r P; R=\$(jq -nc --arg u $N --arg p \"\$P\" '{username:\$u, password:\$p, loginProviderName:\"tmos\"}' |
           curl -sk -H Content-Type:application/json https://localhost/mgmt/shared/authn/login -d @-); T=\$(echo \"\$R\" | jq -r '.token.token // empty')
         [ -z \"\$T\" ] && { echo \"login as $N: \$(echo \"\$R\" | jq -r .message)\"; exit; }
         echo \"login as $N: token received\"
         curl -sk -o /dev/null -w \"AS3 /mgmt/shared/appsvcs/info with that token: HTTP %{http_code}\n\" -H X-F5-Auth-Token:\$T https://localhost/mgmt/shared/appsvcs/info" ;;
  setpw) ssh $O admin@clab-f5-clos-dc-$U "read -r P; jq -nc --arg p \"\$P\" '{password:\$p}' |
           curl -s -u admin: -o /dev/null -w \"PATCH /mgmt/shared/authz/users/$N: HTTP %{http_code}\n\" -X PATCH -H Content-Type:application/json http://localhost:8100/mgmt/shared/authz/users/$N -d @-" ;;
  *) echo "login <user> | setpw <user>  (password on stdin)"; exit 1;;
esac 2>&1 | grep -v api-status
