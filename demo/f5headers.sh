#!/bin/bash
# f5headers.sh: reads `tcpdump -A` text from the BIG-IP on stdin and prints, per packet, "source > destination   <HTTP line>":
# the request line, the status line, Host and every X- header. Lets one capture show the headers on both sides of the full proxy.
grep -aoE '^[0-9:.]+ IP [0-9.]+ > [0-9.]+|(GET|HTTP/1\.1) [^ ]+( [A-Za-z0-9/.]+)?|^(X-[A-Za-z-]+|Host): .*' |
awk '/^[0-9:.]+ IP /{ip=$3" > "$5; sub(/:$/,"",ip); next}
     /^GET/ && ip ~ /\.80 > / {next}
     !seen[ip"|"$0]++ {printf "%-40s %s\n", ip, $0; fflush()}'
