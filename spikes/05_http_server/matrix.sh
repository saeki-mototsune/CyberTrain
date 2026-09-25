#!/bin/bash
# SPIKE (throwaway): server workers x conc x idle-conns matrix using the Spinel loadgen (loadgen pinned to 4 workers)
P=20000
for W in default 1 2 4; do
  if [ $W = default ]; then ./server $P 60 >/dev/null 2>&1 & else SPINEL_WORKERS=$W ./server $P 60 >/dev/null 2>&1 & fi
  pid=$!; sleep 0.4
  SPINEL_WORKERS=4 ./loadgen $P 100 100 >/dev/null
  for C in 10 100; do for I in 0 1 20; do
    printf "server_workers=%-7s " $W; SPINEL_WORKERS=4 ./loadgen $P $C $((50000 / C)) $I
  done; done
  echo "  server threads after: $(curl -s http://127.0.0.1:$P/stats)"
  kill $pid; wait $pid 2>/dev/null; P=$((P+1))
done
