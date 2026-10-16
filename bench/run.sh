#!/bin/sh
# Run the bench Job once and collect its results into <out-dir>:
#   bench/run.sh <out-dir> [ENV=value ...]   (overrides the Job's env defaults)
set -eu
out=$1; shift
job=bench-$(basename "$out" | tr -c 'a-z0-9\n' -)
kubectl -n llm delete job "$job" --ignore-not-found
kubectl set env --local -f bench/job.yaml "$@" -o yaml | sed "s/name: bench$/name: $job/" | kubectl -n llm apply -f -
until [ -n "$(kubectl -n llm get job "$job" -o jsonpath='{.status.succeeded}{.status.failed}')" ]; do sleep 10; done
mkdir -p "$out"
kubectl -n llm logs "job/$job" > "$out/bench.log"
[ "$(kubectl -n llm get job "$job" -o jsonpath='{.status.succeeded}')" = 1 ] || { tail -30 "$out/bench.log"; exit 1; }
sed -n 's/^RESULT //p' "$out/bench.log" > "$out/raw.jsonl"
python3 bench/report.py "$out/raw.jsonl" | tee "$out/results.md"
