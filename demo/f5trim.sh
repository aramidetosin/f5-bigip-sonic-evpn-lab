#!/bin/bash
# f5trim.sh: shorten BIG-IP tcpdump lines for the screen (part 11). Reads tcpdump output on stdin and keeps:
#   time, addresses, TCP flags, length, and from the F5 Ethernet trailer (-i 0.0:nnn): direction, TMM, listener (virtual
#   server), port (interface), flowid and peerid. Drops TCP options, seq/ack/win and the other trailer fields.
# Nothing is hidden from the capture itself: the raw lines are what tcpdump prints; this only trims them.
sed -u -E \
  -e 's/, options \[[^]]*\]//' \
  -e 's/, (seq|ack|win) [^,]*//g' \
  -e 's/ trunk=[^ ]* flowtype=[^ ]* / /' \
  -e 's/ conflags=.*$//' \
  -e 's/ slot1\// /' \
  -e 's/^([0-9:]+)\.[0-9]+ IP /\1 /' \
  -e 's/, length 0//' \
  -e 's#lis=/Common/#lis=#'
