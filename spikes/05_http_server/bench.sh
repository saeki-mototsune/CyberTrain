#!/bin/bash
# SPIKE (throwaway): ab matrix against ./server. usage: bench.sh PORT
P=${1:-19300}
run() { # workers conc ka n
  local W=$1 C=$2 K=$3 N=$4
  if [ "$W" = default ]; then ./server $P 60 >/dev/null 2>&1 & else SPINEL_WORKERS=$W ./server $P 60 >/dev/null 2>&1 & fi
  local pid=$!; sleep 0.4
  ab -q $K -n 2000 -c $C http://127.0.0.1:$P/ >/dev/null 2>&1   # warmup
  out=$(ab -q $K -n $N -c $C http://127.0.0.1:$P/ 2>&1)
  rps=$(echo "$out" | awk '/Requests per second/{print $4}')
  fail=$(echo "$out" | awk '/Failed requests/{print $3}')
  p50=$(echo "$out" | awk '$1=="50%"{print $2}'); p99=$(echo "$out" | awk '$1=="99%"{print $2}'); pmax=$(echo "$out" | awk '$1=="100%"{print $2}')
  rss=$(ps -o rss= -p $pid)
  printf "workers=%-7s c=%-3s ka=%-3s n=%-6s rps=%-9s p50=%sms p99=%sms max=%sms failed=%s rssKB=%s\n" $W $C "${K:+on}" $N "$rps" "$p50" "$p99" "$pmax" "$fail" "$rss"
  kill $pid; wait $pid 2>/dev/null; P=$((P+1))
}
for W in default 1; do for C in 10 100; do
  run $W $C -k 50000
  run $W $C "" 10000
done; done
