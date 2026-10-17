#!/bin/sh
# Run the bench Job once and collect its results into <out-dir>:
#   bench/run.sh <out-dir> [ENV=value ...]   (overrides the Job's env defaults)
set -eu
out=$1; shift
job=bench-$(basename "$out" | tr -c 'a-z0-9\n' -)
kubectl -n llm delete job "$job" --ignore-not-found
if [ $# -gt 0 ]; then manifest=$(kubectl set env --local -f bench/job.yaml "$@" -o yaml); else manifest=$(cat bench/job.yaml); fi
echo "$manifest" | sed "s/name: bench$/name: $job/" | kubectl -n llm apply -f -
fails=0   # survive a dropped tunnel, but not a VM that is gone
while :; do
  if s=$(kubectl -n llm get job "$job" -o jsonpath='{.status.succeeded}{.status.failed}'); then
    fails=0; [ -n "$s" ] && break
  else
    fails=$((fails + 1)); [ "$fails" -lt 30 ] || { echo "cluster unreachable for 5 minutes"; exit 1; }
  fi
  sleep 10
done
mkdir -p "$out"
kubectl -n llm logs "job/$job" > "$out/bench.log"
[ "$(kubectl -n llm get job "$job" -o jsonpath='{.status.succeeded}')" = 1 ] || { tail -30 "$out/bench.log"; exit 1; }
sed -n 's/^RESULT //p' "$out/bench.log" > "$out/raw.jsonl"
python3 bench/report.py "$out/raw.jsonl" | tee "$out/results.md"
