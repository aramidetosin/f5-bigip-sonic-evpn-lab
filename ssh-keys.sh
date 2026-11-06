#!/bin/bash
# ssh-keys.sh: passwordless SSH as "admin" to every node, with the public keys in $SECRETS/authorized_keys (this host's root keys).
#   Dell SONiC   ~admin/.ssh/authorized_keys over SSH (password from appliances.env)
#   Linux nodes  /home/admin/.ssh/authorized_keys by docker exec (host-up.sh also installs it at boot)
#   PA-VM        mgt-config admin <public-key>, commit
#   BIG-IP       /home/admin/.ssh/authorized_keys through the REST bash utility, and admin's shell set to bash (type `tmsh` for the
#                BIG-IP shell). Management access only: nothing in the BIG-IP's traffic configuration is touched.
cd "$(dirname "$0")"; . ./lib.sh
AK=$SECRETS/authorized_keys
[ -s $AK ] || { cat /root/.ssh/*.pub > $AK 2>/dev/null; chmod 600 $AK; }
for k in /root/.ssh/id_*.pub; do [ -s "$k" ] && { grep -qxF "$(cat "$k")" $AK || cat "$k" >> $AK; }; done
[ -s $AK ] || { say "no public key in /root/.ssh on $(hostname): ssh-keygen -t ed25519 first"; exit 1; }
KEYS=$(cat $AK); RC=0
install='mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && while read -r k; do grep -qxF "$k" ~/.ssh/authorized_keys || echo "$k" >> ~/.ssh/authorized_keys; done'
probe() { ssh $SSHO -o BatchMode=yes -o ConnectTimeout=8 admin@"$(mip $1)" true </dev/null 2>/dev/null && echo "$1: key login OK" || { echo "$1: key login FAILED"; RC=1; }; }
for n in $(awk '/kind: dell_sonic/{sub(":","",$1); print $1}' $TOPO); do
  printf '%s\n' "$KEYS" | SSHPASS="$SONIC_PW" sshpass -e ssh $SSHO -o ConnectTimeout=10 admin@"$(mip $n)" "$install" 2>/dev/null; probe $n; done
for n in $(awk '$3=="servers"||$3=="tools"||$3=="lan"{print $2}' mgmt-hosts.txt); do
  printf '%s\n' "$KEYS" | docker exec -i $C-$n sh -c "export HOME=/home/admin; $install; chown -R admin:admin /home/admin/.ssh"; probe $n; done
# PA-VM: one key per admin user in PAN-OS: this server's root key (the VS Code extension), else the first key in the file
K=$(pakey); B64=$({ cat /root/.ssh/id_ed25519.pub 2>/dev/null || head -1 $AK; } | head -1 | base64 -w0)
curl -sk "https://$PA/api/" --data-urlencode type=config --data-urlencode action=set --data-urlencode "key=$K" \
  --data-urlencode "xpath=/config/mgt-config/users/entry[@name='admin']" --data-urlencode "element=<public-key>$B64</public-key>" | grep -q 'status="success"' \
  && ./pa-load.sh --commit-only >/dev/null 2>&1; probe fw-pa
for u in $F5_UNITS; do
  f5rest $u PATCH /mgmt/tm/auth/user/admin -H 'Content-Type: application/json' -d '{"shell":"bash"}' >/dev/null
  cmd="mkdir -p /home/admin/.ssh && chmod 700 /home/admin/.ssh && printf '%s\n' '$(echo "$KEYS" | tr '\n' '|' | sed 's/|$//')' | tr '|' '\n' > /home/admin/.ssh/authorized_keys && chmod 600 /home/admin/.ssh/authorized_keys && chown -R admin /home/admin/.ssh"
  f5rest $u POST /mgmt/tm/util/bash -H 'Content-Type: application/json' -d "$(python3 -c 'import json,sys; print(json.dumps({"command":"run","utilCmdArgs":"-c \""+sys.argv[1].replace("\"","\\\"")+"\""}))' "$cmd")" >/dev/null
  ssh $SSHO -o BatchMode=yes -o ConnectTimeout=8 admin@"$(mip $u)" "tmsh show sys clock" </dev/null >/dev/null 2>&1 \
    && echo "$u: key login OK (bash)" || { echo "$u: key login FAILED"; RC=1; }; done
exit $RC
