#!/bin/bash
# whoami-up.sh: nginx on http :80 and https :443 (lab CA certificate). "/" answers who served the request (its name, address and
# colour) and what it saw: client address, X-Forwarded-For, Host, cookies, TLS; "/health" answers OK for health monitors.
set -e
ADDR=${IP%/*}; H=$(hostname); CERT=$H; [ "$ROLE" = sorry ] && CERT=sorry
FIRST="$H $ADDR"; [ "$ROLE" = sorry ] && FIRST="maintenance: this application is temporarily unavailable ($H $ADDR)"
read -r COLOR CNAME < <(awk -v h="$H" '$1==h{print $2, $3}' /shared/whoami-colors.txt 2>/dev/null) || true
COLOR=${COLOR:-#495057}; CNAME=${CNAME:-gray}
mkdir -p /www/static
echo OK > /www/health
echo "static object served by $H" > /www/static/object.txt
TLS=""
if [ -r /run/f5lab/tls/$CERT.crt ] && [ -r /run/f5lab/tls/$CERT.key ]; then
  TLS="listen $ADDR:443 ssl; ssl_certificate /run/f5lab/tls/$CERT.crt; ssl_certificate_key /run/f5lab/tls/$CERT.key; ssl_protocols TLSv1.2 TLSv1.3;"
fi
LINES='server:           '$H' $server_addr:$server_port
scheme:           $scheme $ssl_protocol
client seen:      $remote_addr:$remote_port
x-forwarded-for:  $http_x_forwarded_for
host:             $host
request:          $request
cookie:           $http_cookie
request id:       $request_id'
cat > /etc/nginx/http.d/default.conf <<EOF
log_format whoami '\$remote_addr xff="\$http_x_forwarded_for" \$scheme \$ssl_protocol "\$request" \$status host="\$host" cookie="\$http_cookie"';
map \$http_accept \$whoami_html { ~text/html 1; default 0; }
server {
  listen $ADDR:80;
  $TLS
  root /www;
  add_header X-Server $H always;
  access_log /var/log/nginx/access.log whoami;
  location = /health { default_type text/plain; }
  location /static/ { default_type text/plain; }
  location = /__whoami.html {
    internal;
    default_type text/html;
    return 200 "<!doctype html><html><head><meta charset='utf-8'><title>$H</title></head>
<body style='margin:0;background:$COLOR;color:#fff;font-family:system-ui,sans-serif'>
<div style='padding:40px'><div style='font-size:64px;font-weight:700'>$H</div>
<div style='font-size:24px;margin:8px 0 24px'>$FIRST ($CNAME)</div>
<pre style='font-size:18px;background:rgba(0,0,0,.25);padding:20px;border-radius:8px'>$LINES
</pre></div></body></html>
";
  }
  location / {
    if (\$whoami_html) { rewrite ^ /__whoami.html last; }
    default_type text/plain;
    return 200 "$FIRST
$LINES
";
  }
}
EOF
nginx -t -q
pgrep -x nginx >/dev/null && nginx -s reload || nginx
