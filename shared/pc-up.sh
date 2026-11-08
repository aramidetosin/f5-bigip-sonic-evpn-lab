#!/bin/bash
# pc-up.sh: pc1-3, users on the client LAN: eth1 = the lab address and gateway (the management address stays on eth0); Firefox
# trusts the lab CA, its home page and bookmarks point at the virtual servers; /etc/hosts names app.f5lab.test (10.20.30.100),
# sorry.f5lab.test and serverN.f5lab.test. The web desktop (KasmVNC on :3000 / :3001) is started by the image's /init.
set -e
ethtool -K eth1 tx off >/dev/null 2>&1 || true
ip link set eth1 mtu 9000; ip link set eth1 up; ip addr replace $IP dev eth1
ip route replace default via $GW dev eth1
# names for the course tests (docker owns /etc/hosts: rewrite it in place, without an older block of ours)
h=$(awk '/^# f5lab BEGIN/ {s=1} !s; /^# f5lab END/ {s=0}' /etc/hosts); printf '%s\n' "$h" > /etc/hosts
. /shared/api-values.sh; . /shared/anycast-values.sh
{ echo "# f5lab BEGIN"; echo "10.20.30.100 app.f5lab.test"; echo "10.20.30.30 sorry.f5lab.test"; echo "$API_VIP $API_NAME"; echo "$ANY_VIP $ANY_NAME"
  echo "10.20.0.11 server1.f5lab.test"; echo "10.20.0.12 server2.f5lab.test"; echo "10.20.0.13 server3.f5lab.test"; echo "# f5lab END"; } >> /etc/hosts
. /shared/gslb-values.sh; printf 'nameserver %s\noptions timeout:2 attempts:1\n' "$RESOLVER_IP" > /etc/resolv.conf
# the lab CA for the system (curl, wget) and for Firefox (enterprise policy)
if [ -s /run/f5lab/ca.crt ]; then cp /run/f5lab/ca.crt /usr/local/share/ca-certificates/f5lab-ca.crt; update-ca-certificates >/dev/null 2>&1 || true; fi
mkdir -p /etc/firefox/policies
cat > /etc/firefox/policies/policies.json <<'POL'
{ "policies": {
    "Certificates": { "ImportEnterpriseRoots": true, "Install": ["/run/f5lab/ca.crt"] },
    "Homepage": { "URL": "http://app.f5lab.test/", "StartPage": "homepage" },
    "DisableTelemetry": true, "DisableFirefoxStudies": true, "DontCheckDefaultBrowser": true, "OverrideFirstRunPage": "",
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "ManagedBookmarks": [ { "toplevel_name": "F5 lab" },
      { "name": "VIP http (app.f5lab.test)", "url": "http://app.f5lab.test/" },
      { "name": "VIP https (app.f5lab.test)", "url": "https://app.f5lab.test/" },
      { "name": "sorry-server", "url": "https://sorry.f5lab.test/" },
      { "name": "server1 direct (must fail)", "url": "http://10.20.0.11/" } ] } }
POL
# admin + ssh (as host-up.sh)
id admin >/dev/null 2>&1 || useradd -m -s /bin/bash admin
if [ -r /run/f5lab/host.env ]; then . /run/f5lab/host.env
  printf 'admin:%s\nroot:%s\n' "$HOST_ADMIN_PW" "$HOST_ROOT_PW" | chpasswd; unset HOST_ADMIN_PW HOST_ROOT_PW; fi
if [ -s /run/f5lab/authorized_keys ]; then
  mkdir -p /home/admin/.ssh && cp /run/f5lab/authorized_keys /home/admin/.ssh/authorized_keys && chmod 700 /home/admin/.ssh && chmod 600 /home/admin/.ssh/authorized_keys && chown -R admin:admin /home/admin/.ssh; fi
mkdir -p /run/sshd; ssh-keygen -A >/dev/null
sed -i -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
pgrep -x sshd >/dev/null || /usr/sbin/sshd
