#!/usr/bin/env bash
# TEMPORARY (startup crash hunt): on an AVX2-only host, does the CPU chat Backend start with the
# V2 model runner (default) and with VLLM_USE_V2_MODEL_RUNNER=0? Same image, env and args as overlays/cpu-kind.
set -u
img=vllm/vllm-openai-cpu:v0.31.0
for v2 in default 0; do
  extra=(); [ "$v2" = 0 ] && extra=(-e VLLM_USE_V2_MODEL_RUNNER=0)
  docker run -d --name "chat-$v2" -p 8000:8000 --shm-size=1g -v hf:/root/.cache/huggingface \
    -e VLLM_CPU_KVCACHE_SPACE=1 -e VLLM_CPU_OMP_THREADS_BIND=nobind -e OMP_NUM_THREADS=2 \
    -e VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=900 -e PYTHONFAULTHANDLER=1 "${extra[@]}" \
    "$img" Qwen/Qwen2.5-0.5B-Instruct --dtype=bfloat16 --max-model-len=2048 --max-num-seqs=4 >/dev/null
  result=timeout
  for _ in $(seq 60); do
    sleep 10
    if curl -sf localhost:8000/health >/dev/null; then
      curl -sf localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
        -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Say hi"}],"max_tokens":8}' \
        && result=served || result=healthy-but-request-failed
      break
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "chat-$v2")" = false ] && { result=exited; break; }
  done
  echo; echo "### VLLM_USE_V2_MODEL_RUNNER=$v2: $result"
  docker logs "chat-$v2" 2>&1 | grep -E 'Model Runner|Fatal Python|died unexpectedly|Illegal' | head -5
  docker rm -f "chat-$v2" >/dev/null
done
sudo dmesg -T | grep -E 'traps:|invalid opcode' | tail -5
