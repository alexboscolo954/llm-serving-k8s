#!/usr/bin/env bash
# TEMPORARY (startup crash hunt): on an AVX2-only host, does the CPU chat Backend start with the fix
# (V1 model runner, Triton-CPU removed)? Same image, command, env and args as overlays/cpu-kind.
set -u
docker run -d --name chat -p 8000:8000 --shm-size=1g -v hf:/root/.cache/huggingface \
  -e VLLM_CPU_KVCACHE_SPACE=1 -e VLLM_CPU_OMP_THREADS_BIND=nobind -e OMP_NUM_THREADS=2 \
  -e VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=900 -e PYTHONFAULTHANDLER=1 -e VLLM_USE_V2_MODEL_RUNNER=0 \
  --entrypoint sh vllm/vllm-openai-cpu:v0.31.0 \
  -c 'rm -r /opt/venv/lib/python3.12/site-packages/triton/backends/cpu && exec vllm serve "$@"' vllm \
  Qwen/Qwen2.5-0.5B-Instruct --dtype=bfloat16 --max-model-len=2048 --max-num-seqs=4 >/dev/null
result=timeout
for _ in $(seq 60); do
  sleep 10
  if curl -sf localhost:8000/health >/dev/null; then
    curl -sf localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Say hi"}],"max_tokens":8}' \
      && result=served || result=healthy-but-request-failed
    break
  fi
  [ "$(docker inspect -f '{{.State.Running}}' chat)" = false ] && { result=exited; break; }
done
echo; echo "### fix (V1 runner, no Triton-CPU): $result"
docker logs chat 2>&1 | grep -E 'Model Runner|Triton is installed|Fatal Python|died unexpectedly' | head -5
sudo dmesg -T | grep -E 'traps:|invalid opcode' | tail -5
[ "$result" = served ]
