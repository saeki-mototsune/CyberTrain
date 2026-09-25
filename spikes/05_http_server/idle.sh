#!/bin/bash
# SPIKE (throwaway): issue #4528 scenario -- ab -k -c100 with/without N silent connections held open.
P=${1:-19500}
stats() { sort -n | awk '{a[NR]=$1} END{printf "p50=%s p99=%s p99.9=%s max=%s n>100ms=", a[int(NR*.5)], a[int(NR*.99)], a[int(NR*.999)], a[NR]; c=0; for(i=1;i<=NR;i++) if(a[i]>100) c++; print c}'; }
run() { # workers idle_conns mode(silent|partial)
  local W=$1 I=$2 M=${3:-silent}
  if [ "$W" = default ]; then ./server $P 60 >/dev/null 2>&1 & else SPINEL_WORKERS=$W ./server $P 60 >/dev/null 2>&1 & fi
  local pid=$!; sleep 0.4
  ab -q -k -n 2000 -c 100 http://127.0.0.1:$P/ >/dev/null 2>&1
  ruby -rsocket -e 'ss=(1..ARGV[1].to_i).map{ s=TCPSocket.new("127.0.0.1",ARGV[0].to_i); s.write("GET / HTTP/1.1\r\nHo") if ARGV[2]=="partial"; s }; sleep 40' $P $I $M & local rp=$!
  sleep 0.5
  local g=/tmp/ab_$$.tsv
  out=$(timeout 60 ab -q -k -n 50000 -c 100 -g $g http://127.0.0.1:$P/ 2>&1)
  rps=$(echo "$out" | awk '/Requests per second/{print $4}'); done_=$(echo "$out" | awk '/Complete requests/{print $3}')
  st=$(tail -n +2 $g | cut -f5 | stats)
  printf "workers=%-7s idle=%-3s %-7s rps=%-9s complete=%-6s %s\n" $W $I $M "$rps" "$done_" "$st"
  kill $rp $pid 2>/dev/null; wait $pid 2>/dev/null; rm -f $g; P=$((P+1))
}
for W in default 1; do
  run $W 0
  run $W 1 silent
  run $W 1 partial
  run $W 20 silent
done
