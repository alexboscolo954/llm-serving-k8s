#!/bin/sh
# shellcheck disable=SC2086 # $BENCH and $DIRECT are lists of ENV=value words, split on purpose
# GPU Benchmark session on the single-L4 RKE2 VM from bench/infra.
#   KUBECONFIG=~/k8s_clusters/llm-bench-l4.yaml bench/session.sh <out-dir> [step ...]
# Steps: platform e2e overhead shared (default, in that order). The first
# session's fp8, gateway, bf16 and the opt-in bf16-64 still run by name; BF16 at
# concurrency 64 did not finish in an hour on one L4.
# Results land on the laptop after every step, so a spot preemption only
# loses the step in progress.
set -eu
out=$1; shift
steps=${*:-platform e2e overhead shared}
vm=llm-bench-l4
trap 'kill $(jobs -p) 2>/dev/null' EXIT   # port-forwards

# Refuse to touch any cluster but the bench VM.
[ -n "${KUBECONFIG:-}" ] || { echo "set KUBECONFIG explicitly"; exit 1; }
node=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
case $node in "$vm"|"$vm".*) ;; *) echo "not the bench cluster: $node"; exit 1 ;; esac

# Fixed methodology: 1024 in / 256 out, 3 repeats, median reported.
BENCH="TOKENIZER=Qwen/Qwen3-8B INPUT_LEN=1024 OUTPUT_LEN=256 REPEATS=3 PROMPTS_PER_CONCURRENCY=16 WARMUPS=4"
DIRECT="BASE_URL=http://vllm-chat:8000 MODEL_NAME=Qwen/Qwen3-8B"
CHAT_ARGS='["Qwen/Qwen3-8B","--port=8000","--max-model-len=16384"'

chat() {  # chat <extra args json> <gpu profile>: recreate the chat Backend, wait until it serves
  kubectl -n llm patch sts vllm-chat --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$CHAT_ARGS,$1]},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector/nvidia.com~1device-plugin.config\",\"value\":\"$2\"}]"
  kubectl -n llm rollout status sts/vllm-chat --timeout=20m
  mkdir -p "$out"
  kubectl -n llm get sts vllm-chat -o jsonpath='{.spec.template.spec.containers[0].args}' > "$out/$step-chat-args.json"
}

wait_for() {  # wait_for <minutes> <what> <command...>: poll every 10 s, fail after <minutes>
  left=$(($1 * 6)); what=$2; shift 2
  until "$@"; do
    left=$((left - 1)); [ "$left" -gt 0 ] || { echo "timed out waiting for $what"; exit 1; }
    sleep 10
  done
}
gpu_count_is() { [ "$(kubectl get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')" = "$1" ]; }
gpus() { wait_for 20 "$1 GPUs on $node" gpu_count_is "$1"; }   # gpus <n>: n advertised nvidia.com/gpu

secret() { kubectl -n llm get secret "$1" -o jsonpath='{.data.key}' | base64 -d; }
prometheus() {  # port-forward Prometheus to localhost:19090 for prom
  kubectl -n monitoring port-forward svc/prometheus-operated 19090:9090 >/dev/null 2>&1 &
  sleep 3
}
prom() {  # prom <out-file> <query>: save a Prometheus instant query
  curl -sfG http://localhost:19090/api/v1/query --data-urlencode "query=$2" > "$1"
}

for step in $steps; do
  echo "=== $step"
  case $step in
  platform)
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
    kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
    kubectl create ns llm --dry-run=client -o yaml | kubectl apply -f -
    make observe   # Prometheus first: the GPU Operator's DCGM ServiceMonitor needs its CRDs
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null; helm repo update nvidia >/dev/null
    kubectl create ns gpu-operator --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f platform/time-slicing-config.yaml
    kubectl label node "$node" nvidia.com/device-plugin.config=dedicated --overwrite
    helm upgrade --install gpu-operator nvidia/gpu-operator --version v26.7.1 -n gpu-operator \
      -f platform/gpu-operator-values.yaml -f platform/gpu-operator-rke2-values.yaml
    gpus 1
    make platform   # CNPG, Istio, Gateway API + Inference Extension CRDs
    for k in litellm-master-key litellm-metrics-key; do
      kubectl -n llm create secret generic $k --from-literal=key="sk-$(openssl rand -hex 16)" \
        --dry-run=client -o yaml | kubectl apply -f -
    done
    kubectl apply -k overlays/gpu
    kubectl -n llm wait --for=condition=Ready cluster/litellm-db --timeout=10m
    kubectl -n llm wait --for=condition=Programmed gateway/inference-gateway --timeout=5m
    kubectl -n llm scale deploy/vllm-embed --replicas=0   # its shared profile only exists in the shared step
    kubectl -n llm rollout status sts/vllm-chat --timeout=20m
    mkdir -p "$out"
    {
      echo "# Setup, $(date -u +%FT%TZ)"
      echo; echo '```'
      gcloud compute instances list --filter=name=$vm --format='value(machineType.basename(),zone.basename(),scheduling.provisioningModel)'
      kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion} {.status.nodeInfo.containerRuntimeVersion} {.status.nodeInfo.osImage} {.status.nodeInfo.kernelVersion}{"\n"}'
      kubectl -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
      kubectl -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi | grep -o 'CUDA Version: [0-9.]*'
      echo "gpu-operator v26.7.1"
      kubectl -n llm get pod -l app=vllm-chat -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
      curl -s https://huggingface.co/api/models/Qwen/Qwen3-8B | python3 -c 'import json,sys; print("Qwen/Qwen3-8B", json.load(sys.stdin)["sha"])'
      echo '```'
      echo; echo "Bench client: vllm bench serve, random dataset, 1024 input / 256 output tokens (ignore_eos),"
      echo "16 prompts per unit of concurrency, 4 warmup requests, 3 repeats with distinct seeds, median reported."
    } > "$out/setup.md"
    cat "$out/setup.md"
    ;;
  e2e)  # CI's e2e tests on this cluster: Gateway, keys in Postgres, Tenants, NetworkPolicies under Canal
    kubectl -n llm port-forward svc/litellm 14000:4000 >/dev/null 2>&1 & pf=$!
    sleep 3
    mkdir -p "$out"
    # The embed Backend is scaled to 0 here, so its tests are left out.
    GATEWAY_URL=http://localhost:14000 GATEWAY_KEY=$(secret litellm-master-key) METRICS_KEY=$(secret litellm-metrics-key) \
      python3 -m pytest -v tests/test_gateway.py tests/test_tenancy.py -k 'not embed' > "$out/e2e.txt" 2>&1 \
      || echo "e2e tests failed"   # a result, not a reason to stop the session
    kill $pf
    tail -20 "$out/e2e.txt"
    prometheus
    prom "$out/dcgm-gpu-util.json" 'DCGM_FI_DEV_GPU_UTIL'   # the DCGM exporter is scraped
    ;;
  fp8)
    chat '"--quantization=fp8","--gpu-memory-utilization=0.90"' dedicated
    bench/run.sh "$out/fp8" $BENCH $DIRECT CONCURRENCY="1 4 16 64"
    ;;
  gateway)  # same as fp8 at c=16, but through LiteLLM: compare TTFT and E2E only
    bench/run.sh "$out/gateway" $BENCH MODEL_NAME=chat CONCURRENCY=16
    ;;
  overhead)  # gateway, back to back with its direct baseline: LiteLLM, the Istio gateway and the Endpoint Picker
    chat '"--quantization=fp8","--gpu-memory-utilization=0.90"' dedicated
    bench/run.sh "$out/overhead-direct" $BENCH $DIRECT CONCURRENCY=16
    bench/run.sh "$out/overhead-gateway" $BENCH MODEL_NAME=chat CONCURRENCY=16
    ;;
  bf16)
    kubectl -n llm scale deploy/vllm-embed --replicas=0   # frees its slice before going back to one whole GPU
    kubectl label node "$node" nvidia.com/device-plugin.config=dedicated --overwrite
    gpus 1
    chat '"--gpu-memory-utilization=0.90"' dedicated
    bench/run.sh "$out/bf16" $BENCH $DIRECT CONCURRENCY="1 4 16"
    ;;
  bf16-64)  # KV-starved and very slow, so one run; FP8 repeats differed by <0.1%
    bench/run.sh "$out/bf16-64" $BENCH $DIRECT CONCURRENCY=64 REPEATS=1
    ;;
  shared)  # time-slicing cost: chat alone vs chat next to a busy embed Backend, same caps
    kubectl label node "$node" nvidia.com/device-plugin.config=shared --overwrite
    gpus 4
    chat '"--quantization=fp8","--gpu-memory-utilization=0.70"' shared
    bench/run.sh "$out/shared-alone" $BENCH $DIRECT CONCURRENCY=16
    kubectl -n llm scale deploy/vllm-embed --replicas=1   # only after chat holds its memory
    kubectl -n llm rollout status deploy/vllm-embed --timeout=15m
    kubectl -n llm apply -f bench/embed-load.yaml
    bench/run.sh "$out/shared-busy" $BENCH $DIRECT CONCURRENCY=16
    kubectl -n llm delete -f bench/embed-load.yaml
    # the embed Backend's own throughput is the proof that the neighbour was actually busy
    kubectl -n llm logs deploy/vllm-embed | grep 'Engine 000' > "$out/shared-busy/vllm-embed-stats.log"
    ;;
  *) echo "unknown step: $step"; exit 1 ;;
  esac
done
