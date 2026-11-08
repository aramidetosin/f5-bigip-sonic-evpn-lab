# Part 8: SSL offload with a lab CA

| | |
|---|---|
| Video | [F5 SSL Offload and Re-encryption with a Lab CA (Part 8)](https://youtu.be/2R2OMieUsps) (public from 2026-11-24 04:00 UTC) |
| Written walkthrough | [levelupit.xyz](https://www.levelupit.xyz/learning-f5-big-ip-on-a-sonic-data-centre-fabric-ssl-offload/) (from 2026-11-24 04:00 UTC) |
| Previous / next | [Part 7](part07.md) / [Part 9](part09.md) |

## Goal

I give the application an HTTPS virtual server, `vs-web-https` on 10.20.30.100:443, with a certificate from the lab's own CA. First
as SSL offload (TLS ends on the BIG-IP, plain HTTP to the servers), then with TLS 1.3 switched on, then re-encrypted to the servers'
own HTTPS with real certificate validation. I break that validation on purpose, add cookie persistence over HTTPS and try the built-in
HTTP-to-HTTPS redirect.

## Starting state

- The lab is up and `./validate.sh` passes. `secrets-init.sh` (run by `up.sh`) created the lab CA and the certificates in
  `/root/f5-clos-dc-secrets/tls/` on the lab server: `ca.crt` (the CA, "f5lab test CA"), `app.crt` / `app.key` (CN and SAN
  `app.f5lab.test`), and one certificate per server. server1-3 already serve HTTPS on :443 with their `serverN.f5lab.test`
  certificates. The PCs have the CA at `/run/f5lab/ca.crt`, and Firefox on the PCs trusts it.
- lb-f5a only, in the end state of [Part 7](part07.md):
  - pool `pool-web`: server1:80, server2:80, server3:80, round robin, monitor `http-app`;
  - virtual server `vs-web` 10.20.30.100:80: `tcp`, `http-xff`, SNAT pool `snat-web` (10.20.0.201, .202), pool `pool-web`,
    persistence `persist-cookie`, fallback none;
  - profiles `persist-src` and `persist-cookie`; monitors `http-app` and `http-health`.
- To get there: the guides of parts 2-7, or restore the UCS saved at the end of part 7 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Values used in this part

| Object | Value |
|---|---|
| BIG-IP | lb-f5a, web UI `https://172.21.32.43` (user admin; password: `sudo sed -n 's/^PASSWORD=//p' /root/f5-clos-dc-secrets/lb-f5a.env`) |
| Key and certificate | both named `app.f5lab.test` on the BIG-IP (from `app.key` / `app.crt`) |
| CA certificate | `f5lab-ca` on the BIG-IP (from `ca.crt`) |
| Client SSL profile | `clientssl-app`, parent `clientssl`, cert-key-chain `app.f5lab.test` |
| HTTPS VIP | `vs-web-https` 10.20.30.100:443: `tcp`, `http-xff`, `clientssl-app`, SNAT pool `snat-web`, pool `pool-web` (then `pool-web-https`) |
| Server SSL profile | `serverssl-lab`, parent `serverssl`, ca-file `f5lab-ca`, peer-cert-mode require |
| HTTPS pool | `pool-web-https`: server1:443, server2:443, server3:443, monitor `https-app` |
| HTTPS monitor | `https-app`, parent https, send `GET / HTTP/1.1\r\nHost: app.f5lab.test\r\nConnection: close\r\n\r\n`, receive `200 OK` |
| TLS 1.3 | cipher-group `f5-default`, ciphers none, options `{ dont-insert-empty-fragments no-dtlsv1.2 }` |
| Client | pc1 (management 172.21.32.111); curl needs `--cacert /run/f5lab/ca.crt` |

## Steps

All commands run on the lab server (root, in the repo folder) unless a step says otherwise. Only public certificates are printed. The
private key is never displayed.

### 1. Before: the certificate, and port 443 with nothing on it

```bash
openssl x509 -in /root/f5-clos-dc-secrets/tls/app.crt -noout -subject -issuer -dates -ext subjectAltName
openssl x509 -in /root/f5-clos-dc-secrets/tls/ca.crt -noout -subject -issuer
ssh admin@172.21.32.111 'curl -sS --max-time 5 https://app.f5lab.test/ 2>&1 | head -2'
```

You should see subject and SAN `app.f5lab.test`, issuer `f5lab test CA` (the CA is self-signed: subject = issuer). In my run the
certificate was valid to 2029-02-07; yours is valid 825 days from the day `secrets-init.sh` created it. The curl fails with
`curl: (7)`: nothing listens on 10.20.30.100:443 yet (in my run it gave up in 4 ms).

### 2. Import the key and the certificate, in the web UI

The web UI uploads files from the machine your browser runs on. Copy `app.key` and `app.crt` from `/root/f5-clos-dc-secrets/tls/` on
the lab server to that machine (for example with `scp`), import them, then delete the local copies: `app.key` is a private key.

In the web UI of lb-f5a (https://172.21.32.43): System > Certificate Management > Traffic Certificate Management > SSL Certificate
List > Import...

1. Import Type **Key**; Key Name `app.f5lab.test`; upload the file `app.key`; Import.
2. Import... again: Import Type **Certificate**; Certificate Name `app.f5lab.test`; upload the file `app.crt`; Import.

The list then shows `app.f5lab.test` with its key.

The same in tmsh, from the lab server (how I installed them in a dry run; the files are deleted from the BIG-IP right after):

```bash
scp -q /root/f5-clos-dc-secrets/tls/app.key /root/f5-clos-dc-secrets/tls/app.crt admin@clab-f5-clos-dc-lb-f5a:/var/tmp/
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh install sys crypto key app.f5lab.test from-local-file /var/tmp/app.key; tmsh install sys crypto cert app.f5lab.test from-local-file /var/tmp/app.crt; rm /var/tmp/app.key /var/tmp/app.crt'
```

The objects are named `app.f5lab.test`, with no `.crt` / `.key` suffix.

### 3. Create `clientssl-app`, in the web UI

Local Traffic > Profiles > SSL > Client > Create...

- Name: `clientssl-app` (Parent Profile stays `clientssl`).
- Certificate Key Chain: tick the Custom box, then Add: Certificate `app.f5lab.test`, Key `app.f5lab.test` > Add.
- Finished.

### 4. Create `vs-web-https`, in the web UI

Local Traffic > Virtual Servers > Create...

- Name: `vs-web-https`
- Destination Address/Mask: `10.20.30.100`; Service Port: `443`
- HTTP Profile (Client): `http-xff`
- SSL Profile (Client): move `clientssl-app` from Available to Selected
- Source Address Translation: **SNAT**; SNAT Pool: `snat-web`
- Default Pool: `pool-web`
- Finished.

The protocol profile stays the default `tcp`. The pool is still `pool-web` on port 80: this is offload.

### 5. Offload, tested

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm virtual vs-web-https' | grep -v -E "creation-time|last-modified|vs-index|serverssl-use-sni|mask |ip-protocol|translate-|vlans-|source 0"
ssh admin@172.21.32.111 'curl -sS -o /dev/null https://app.f5lab.test/ 2>&1 | head -1'
ssh admin@172.21.32.111 'curl -sv -o /dev/null --cacert /run/f5lab/ca.crt https://app.f5lab.test/ 2>&1 | grep -E "SSL connection|subject:|issuer:"'
ssh admin@172.21.32.111 'curl -s --cacert /run/f5lab/ca.crt https://app.f5lab.test/ | grep -E "^(server|scheme|client seen|x-forwarded-for):"'
```

You should see:
- `vs-web-https` with destination 10.20.30.100:443, pool `pool-web`, profiles `clientssl-app` (clientside), `http-xff`, `tcp`, and
  SNAT pool `snat-web`.
- Without `--cacert`, curl refuses the certificate (OpenSSL verify error 20, unable to get local issuer certificate): pc1's curl does
  not know the lab CA unless told.
- With `--cacert`: `SSL connection using TLSv1.2 / ECDHE-RSA-AES128-GCM-SHA256`, subject `CN=app.f5lab.test`, issuer `CN=f5lab test CA`.
- The page: `server: server1 10.20.0.11:80`, `scheme: http`, `client seen: 10.20.0.202` (a SNAT pool address), `x-forwarded-for:
  10.10.0.11`. The server got plain HTTP; the BIG-IP decrypted, so it could insert X-Forwarded-For.

### 6. The browser's view (pc1 Firefox)

Open pc1's web desktop at `https://172.21.32.111:3001` (user and password: `sudo cat /root/f5-clos-dc-secrets/pc.env` on the lab
server). In Firefox, go to `https://app.f5lab.test/` and click the padlock > Connection secure. Firefox shows the connection verified by
`f5lab test CA`, and notes that this issuer is not one Mozilla knows: it was added by an administrator (the lab CA installed on the
PC). The page still says `scheme: http`: that is the server side.

### 7. TLS 1.3

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm profile client-ssl clientssl-app all-properties | grep -E "^ +(options|ciphers|cipher-group) "'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm profile client-ssl clientssl-app options { dont-insert-empty-fragments no-dtlsv1.2 }'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm cipher group one-line | cut -d" " -f1-4'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm profile client-ssl clientssl-app cipher-group f5-default ciphers none options { dont-insert-empty-fragments no-dtlsv1.2 }'
ssh admin@172.21.32.111 'curl -sv -o /dev/null --cacert /run/f5lab/ca.crt https://app.f5lab.test/ 2>&1 | grep -E "SSL connection"'
ssh admin@172.21.32.111 'curl -sv --tls-max 1.2 -o /dev/null --cacert /run/f5lab/ca.crt https://app.f5lab.test/ 2>&1 | grep -E "SSL connection"'
```

You should see:
- `ciphers DEFAULT`, `cipher-group none`, options `{ dont-insert-empty-fragments no-tlsv1.3 no-dtlsv1.2 }`, inherited from `clientssl`.
- Removing `no-tlsv1.3` alone is refused: `01b40001:3: A cipher group must be configured when TLS 1.3 is enabled`.
- The cipher groups: f5-aes, f5-cc-stip, f5-default, f5-ecc, f5-fips, f5-hw_keys, f5-quic, f5-secure.
- With `cipher-group f5-default ciphers none`: `TLSv1.3 / TLS_AES_128_GCM_SHA256` (x25519). With `--tls-max 1.2` the client still gets
  TLSv1.2.

### 8. Re-encryption to the servers, validated against the lab CA

Install the lab CA on the BIG-IP, then an HTTPS monitor, an HTTPS pool and a server SSL profile that requires a valid server
certificate.

```bash
scp -q /root/f5-clos-dc-secrets/tls/ca.crt admin@clab-f5-clos-dc-lb-f5a:/var/tmp/f5lab-ca.crt && ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh install sys crypto cert f5lab-ca from-local-file /var/tmp/f5lab-ca.crt; rm /var/tmp/f5lab-ca.crt'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh create ltm monitor https https-app defaults-from https send "GET / HTTP/1.1\r\nHost: app.f5lab.test\r\nConnection: close\r\n\r\n" recv "200 OK"'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh create ltm pool pool-web-https members add { server1:443 server2:443 server3:443 } monitor https-app'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh create ltm profile server-ssl serverssl-lab defaults-from serverssl ca-file f5lab-ca peer-cert-mode require'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web-https pool pool-web-https profiles add { serverssl-lab { context serverside } }'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm pool pool-web-https members field-fmt' | grep -E "^ +(addr|status.availability-state) "
ssh admin@172.21.32.111 'for i in 1 2 3; do curl -s --cacert /run/f5lab/ca.crt https://app.f5lab.test/ | grep -E "^(server|scheme):"; done'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm profile server-ssl serverssl-lab cipher-group f5-default ciphers none options { dont-insert-empty-fragments no-dtlsv1.2 }'
ssh admin@172.21.32.111 'curl -s --cacert /run/f5lab/ca.crt https://app.f5lab.test/ | grep -E "^(server|scheme|client seen|x-forwarded-for):"'
```

You should see the three members `available`, then `server: serverN 10.20.0.1N:443` and `scheme: https TLSv1.2` for each request.
After the cipher group on `serverssl-lab`: `scheme: https TLSv1.3`. The nodes are named, so the members are `server1:443` and so on.

### 9. Break the server-side validation

Point `serverssl-lab` at the wrong CA bundle and watch what users and the monitor see.

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm profile server-ssl serverssl-lab ca-file ca-bundle.crt'
ssh admin@172.21.32.111 'curl -sS -o /dev/null -w "HTTP %{http_code}\n" --cacert /run/f5lab/ca.crt https://app.f5lab.test/ 2>&1'
ssh admin@clab-f5-clos-dc-lb-f5a 'grep -h -E "01260006|01260013" /var/log/ltm | tail -2'
sleep 15
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm pool pool-web-https members field-fmt' | grep -E "^ +status.availability-state "
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm profile server-ssl serverssl-lab ca-file f5lab-ca'
ssh admin@172.21.32.111 'curl -s --cacert /run/f5lab/ca.crt https://app.f5lab.test/ | grep -E "^(server|scheme|client seen|x-forwarded-for):"'
```

In my run: curl `(56)` connection reset and `HTTP 000`. The log said `01260006:4: Peer cert verify error: unable to get local issuer
certificate (depth 0; cert /CN=server2.f5lab.test)` and `01260013:4: SSL Handshake failed for TCP 10.20.0.12:443 -> ...`. All 3
members stayed **available**: the `https-app` monitor does not use `serverssl-lab`. Back on `f5lab-ca`: `https TLSv1.3` again.

### 10. Cookie persistence over HTTPS

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web-https persist replace-all-with { persist-cookie { default yes } }'
ssh admin@172.21.32.111 'curl -s -D- -o /dev/null --cacert /run/f5lab/ca.crt https://app.f5lab.test/ | grep -i -E "^(x-server|set-cookie)"'
./demo/bigip-cookie.py $(ssh admin@172.21.32.111 'curl -s -D- -o /dev/null --cacert /run/f5lab/ca.crt https://app.f5lab.test/' | grep -i set-cookie | sed 's/.*BIGipServer[^=]*=//; s/;.*//')
ssh admin@172.21.32.111 'rm -f /tmp/j; for i in 1 2 3 4 5; do curl -s -b /tmp/j -c /tmp/j -o /dev/null -w "%header{x-server} " --cacert /run/f5lab/ca.crt https://app.f5lab.test/; done; echo'
```

You should see `Set-Cookie: BIGipServerpool-web-https=<address>.47873.0000; path=/; Httponly; Secure`. The name follows the pool,
`Secure` is now added (the client side is HTTPS), and 47873 = 0xBB01, byte-swapped 0x01BB = 443. In my run one value decoded to
10.20.0.11:443, and the cookie jar kept 5 of 5 requests on server2. The BIG-IP can read and insert the cookie only because it decrypts.

### 11. HTTP to HTTPS redirect (tried, then removed)

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh list ltm rule _sys_https_redirect' | grep -A2 "when HTTP_REQUEST"
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web rules { _sys_https_redirect }'
ssh admin@172.21.32.111 'curl -s -D- -o /dev/null "http://app.f5lab.test/some/page?x=1" | grep -i -E "^(HTTP|location)"'
ssh admin@172.21.32.111 'curl -s -L --cacert /run/f5lab/ca.crt http://app.f5lab.test/ | grep -E "^(server|scheme):"'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web rules none; tmsh save sys config' | tail -1
```

You should see `HTTP/1.0 302 Moved Temporarily` and `Location: https://app.f5lab.test/some/page?x=1` (path and query kept); `curl -L`
ends on `scheme: https TLSv1.3`. I remove the rule again: the next parts still test plain HTTP on `vs-web`.

## Verify

Read-only checks from both ends:

```bash
ssh admin@172.21.32.111 'echo | openssl s_client -connect app.f5lab.test:443 -servername app.f5lab.test -CAfile /run/f5lab/ca.crt 2>/dev/null | grep -E "^(subject|issuer)|Protocol|Cipher is|Verify return"'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh show ltm profile client-ssl clientssl-app' | grep -E "Secure Handshakes|TLS Protocol Version|Handshake Failures"
```

What I measured:
- openssl s_client: subject `app.f5lab.test`, issuer `f5lab test CA`, verify return code 0.
- `clientssl-app` counters after the steps above: 29 secure handshakes (5 TLS 1.2 + 24 TLS 1.3), 0 handshake failures.
- Offload: TLSv1.2 ECDHE-RSA-AES128-GCM-SHA256 to the client, `scheme: http` at the server, X-Forwarded-For 10.10.0.11.
- TLS 1.3 on the client side with `f5-default`: TLS_AES_128_GCM_SHA256; `--tls-max 1.2` still works.
- Re-encryption: `scheme: https TLSv1.2`, then `https TLSv1.3` with `f5-default` on `serverssl-lab`.
- Wrong CA: every request reset, log 01260006 / 01260013, monitor still green.

## Gotchas

- curl on the PCs does not trust the lab CA by default: use `--cacert /run/f5lab/ca.crt`, or you get a verify error. Firefox on the
  PCs trusts it.
- The built-in `clientssl` and `serverssl` parents carry `no-tlsv1.3`. Removing it alone is refused (`01b40001`): TLS 1.3 needs a
  cipher group, and `ciphers none` with it.
- Built-in `serverssl` has `peer-cert-mode ignore` and `ca-file none`: by default the BIG-IP accepts any server certificate. Validation
  only happens with a CA file and `peer-cert-mode require`.
- The `https` monitor does not use the virtual server's server SSL profile (its ssl-profile is none). With the wrong CA every user
  request failed while all three members stayed green. A green pool does not prove the data path works.
- The persistence cookie gets `Secure` only on an HTTPS virtual server; its name follows the pool (`BIGipServerpool-web-https`).
- `_sys_https_redirect` answers with HTTP/1.0 302 and keeps the path and query.
- Never print or commit the key. In tmsh, delete the uploaded files from `/var/tmp` right after `install sys crypto`.

## End state

- Key and certificate `app.f5lab.test`; CA certificate `f5lab-ca`.
- `clientssl-app`: parent clientssl, cert-key-chain `app.f5lab.test`, cipher-group `f5-default`, ciphers none, TLS 1.3 on.
- `serverssl-lab`: parent serverssl, ca-file `f5lab-ca`, peer-cert-mode require, cipher-group `f5-default`, ciphers none.
- Monitor `https-app`; pool `pool-web-https` (server1:443, server2:443, server3:443, monitor `https-app`).
- `vs-web-https` 10.20.30.100:443: `tcp`, `http-xff`, `clientssl-app` (client side), `serverssl-lab` (server side), SNAT pool
  `snat-web`, pool `pool-web-https`, persistence `persist-cookie`.
- `vs-web` unchanged: persistence `persist-cookie`, no iRule. Configuration saved.

```bash
./f5-save.sh lb-f5a
```

## Reset

Delete what this part created, in dependency order:

```bash
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh modify ltm virtual vs-web rules none'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh delete ltm virtual vs-web-https; tmsh delete ltm pool pool-web-https; tmsh delete ltm monitor https https-app'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh delete ltm profile client-ssl clientssl-app; tmsh delete ltm profile server-ssl serverssl-lab'
ssh admin@clab-f5-clos-dc-lb-f5a 'tmsh delete sys crypto cert app.f5lab.test; tmsh delete sys crypto key app.f5lab.test; tmsh delete sys crypto cert f5lab-ca; tmsh save sys config'
```

Or restore the UCS saved at the end of part 7 with `./f5-restore.sh lb-f5a <file.ucs>`.

## Files used

- `demo/bigip-cookie.py`: decodes the `BIGipServerpool-web-https` cookie value to the member's address and port (443).
