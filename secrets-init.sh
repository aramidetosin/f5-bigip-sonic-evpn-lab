#!/bin/bash
# secrets-init.sh: create the lab's root-only secrets once (re-runs keep what exists). Nothing is printed.
#   $SECRETS/appliances.env   SONIC_USER SONIC_PW PA_USER PA_PW   (the images' default credentials)
#   $SECRETS/host.env         HOST_ADMIN_PW HOST_ROOT_PW           (Linux nodes)
#   $SECRETS/lb-f5a.env, lb-f5b.env   PASSWORD ROOT_PASSWORD F5_NEW_PASSWORD F5_HOSTNAME F5_DNS for the BIG-IP launcher (no licence key:
#                             you license the BIG-IPs yourself)
#   $SECRETS/pc.env           the PCs' web desktop login
#   $SECRETS/authorized_keys  this host's root public keys (ssh-keys.sh)
#   $SECRETS/tls/             a lab CA and one key / certificate per name in gen.py TLS_NAMES
set -e
cd "$(dirname "$0")"
SECRETS=${F5LAB_SECRETS:-/root/f5-clos-dc-secrets}
umask 077; mkdir -p "$SECRETS/tls"; chmod 700 "$SECRETS"
rnd() { openssl rand -hex 12; }
[ -s "$SECRETS/appliances.env" ] || printf 'SONIC_USER=admin\nSONIC_PW=admin\nPA_USER=admin\nPA_PW=Admin@123\n' > "$SECRETS/appliances.env"
[ -s "$SECRETS/host.env" ] || printf 'HOST_ADMIN_PW=%s\nHOST_ROOT_PW=%s\n' "$(rnd)" "$(rnd)" > "$SECRETS/host.env"
pw=$(sed -n 's/^PASSWORD=//p' "$SECRETS/lb-f5a.env" 2>/dev/null || true); [ -n "$pw" ] || pw=$(rnd)   # || true: set -e (first run, no file)
for u in lb-f5a lb-f5b; do
  [ -s "$SECRETS/$u.env" ] || printf 'PASSWORD=%s\nROOT_PASSWORD=default\nF5_NEW_PASSWORD=%s\nF5_HOSTNAME=%s.f5lab.test\nF5_DNS=1.1.1.1,8.8.8.8\n' \
    "$pw" "$pw" "$u" > "$SECRETS/$u.env"
done
[ -s "$SECRETS/pc.env" ] || printf 'CUSTOM_USER=admin\nPASSWORD=%s\n' "$(rnd)" > "$SECRETS/pc.env"
[ -s "$SECRETS/authorized_keys" ] || cat /root/.ssh/*.pub > "$SECRETS/authorized_keys" 2>/dev/null || true
for k in /root/.ssh/id_*.pub; do [ -s "$k" ] && { grep -qxF "$(cat "$k")" "$SECRETS/authorized_keys" || cat "$k" >> "$SECRETS/authorized_keys"; }; done
T="$SECRETS/tls"
if [ ! -s "$T/ca.crt" ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -days 825 -subj "/CN=f5lab test CA" -keyout "$T/ca.key" -out "$T/ca.crt" 2>/dev/null
fi
for name in $(python3 -B -c 'import gen; print(" ".join(gen.TLS_NAMES))'); do
  s=${name%%.*}
  [ -s "$T/$s.crt" ] && continue
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$name" -keyout "$T/$s.key" -out "$T/$s.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$name" > "$T/$s.ext"
  openssl x509 -req -in "$T/$s.csr" -CA "$T/ca.crt" -CAkey "$T/ca.key" -CAcreateserial -days 825 -extfile "$T/$s.ext" -out "$T/$s.crt" 2>/dev/null
  rm -f "$T/$s.csr" "$T/$s.ext"
done
chmod 644 "$T"/*.crt "$T"/*.key; chmod 600 "$T/ca.key"; chmod 711 "$T"
echo "secrets-init: $SECRETS ready ($(ls "$SECRETS" | tr '\n' ' '))"
