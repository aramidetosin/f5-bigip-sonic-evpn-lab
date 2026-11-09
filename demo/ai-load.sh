#!/bin/bash
# demo/ai-load.sh <streams> [tokens] [spacing_ms] (part 24): an inference load from pc1. Opens <streams> streaming requests to
# http://ai.f5lab.test/cgi-bin/generate?tokens=<tokens> (default 40), one every <spacing_ms> (default 0 = all at once), and for each
# stream records: the pod that served it, time to first token (TTFT), total time, tokens received, and whether it reached [DONE].
# Prints one line per stream into /tmp/ai-load.txt on pc1, then a summary: streams per pod, TTFT and total (median / max) of the
# streams that completed, and how many did not complete ("-" = refused: no pod, no token).
# TOKENS can also be a list "a,b,c": stream i then asks for the i-th value, cycling (mixed long and short requests).
# Run on the lab server, in lab/demo.
N=${1:?streams}; T=${2:-40}; GAP=${3:-0}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
ssh $O admin@172.21.32.111 "N=$N T=$T GAP=$GAP bash -s" <<'PC'
one() {   # $1 = stream number, $2 = tokens
  local s=$(date +%s%3N) first="" pod="-" n=0 done=no l
  while IFS= read -r l; do
    case "$l" in
      data:\ \[DONE\]*) done=yes ;;
      data:*) n=$((n + 1)); [ -z "$first" ] && { first=$(( $(date +%s%3N) - s )); pod=$(echo "$l" | sed -n 's/.*"pod":"\([^"]*\)".*/\1/p'); } ;;
    esac
  done < <(curl -sN -m 300 "http://ai.f5lab.test/cgi-bin/generate?tokens=$2")
  echo "$1 ${pod##*-} ttft=${first:--} total=$(( $(date +%s%3N) - s )) tokens=$n/$2 done=$done"
}
IFS=, read -ra TL <<< "$T"; : > /tmp/ai-load.txt
for i in $(seq $N); do one $i ${TL[$(( (i - 1) % ${#TL[@]} ))]} >> /tmp/ai-load.txt & [ "$GAP" -gt 0 ] && sleep $(awk "BEGIN{print $GAP/1000}"); done; wait
sort -n /tmp/ai-load.txt > /tmp/ai-load.s; mv /tmp/ai-load.s /tmp/ai-load.txt
echo "streams per pod:   $(awk '{print $2}' /tmp/ai-load.txt | sort | uniq -c | awk '{printf "%s=%s  ", $2, $1}')"
med() { sort -n | awk '{a[NR]=$1} END{if(NR){printf "median %d ms, max %d ms", a[int((NR+1)/2)], a[NR]}}'; }
echo "time to 1st token: $(grep 'done=yes' /tmp/ai-load.txt | grep -o 'ttft=[0-9]*' | cut -d= -f2 | med)   (completed streams)"
echo "total time:        $(grep 'done=yes' /tmp/ai-load.txt | grep -o 'total=[0-9]*' | cut -d= -f2 | med)   (completed streams)"
echo "incomplete:        $(grep -c 'done=no' /tmp/ai-load.txt) of $N"
PC
